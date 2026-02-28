#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_TAG="${RACKUP_LEGACY_DOCKER_IMAGE:-rackup-e2e:present-ubuntu-24.04-native}"
ARTIFACTS_DIR="${RACKUP_LEGACY_ARTIFACTS_DIR:-/tmp/rackup-legacy-artifacts}"
HOME_ROOT="${RACKUP_LEGACY_HOME_ROOT:-/tmp/rackup-legacy-home}"
SRC_COPY=""
KEEP_SRC_COPY=0
VERSIONS=("202" "209" "352")

usage() {
  cat <<'EOF'
Run historical PLT/Racket installers inside a Docker image using locally cached artifacts.

This is a wrapper around the long `docker run ... bash -lc ...` command used to
debug legacy i386 Linux installers. It:
  1. Creates a filtered source copy of the current repo
  2. Mounts that copy and the cached installer artifacts into Docker
  3. Installs each requested historical version with `rackup`
  4. Tries to run `mzscheme -v` and prints whether install/run succeeded

Usage:
  scripts/docker-check-legacy-artifacts.sh [options]

Options:
  --image TAG            Docker image to use
  --artifacts-dir DIR    Directory containing downloaded legacy installers
  --home-root DIR        Container-side root for RACKUP_HOME values
  --src-copy DIR         Reuse/create this filtered source copy instead of a temp dir
  --keep-src-copy        Keep the temporary filtered source copy
  --version VER          Legacy version to check (repeatable; default: 202, 209, 352)
  -h, --help             Show this help

Expected artifact filenames:
  202 -> plt-202-bin-i386-linux.tgz
  209 -> plt-209-bin-i386-linux.sh
  352 -> plt-352-bin-i386-linux.sh
  other versions default to .sh unless overridden in the script

Examples:
  scripts/docker-check-legacy-artifacts.sh
  scripts/docker-check-legacy-artifacts.sh --version 103 --version 202
  scripts/docker-check-legacy-artifacts.sh --image rackup-e2e:present-debian-12-native
EOF
}

artifact_ext_for_version() {
  case "$1" in
    053|102|103|103p1|200|201|202|205)
      printf 'tgz\n'
      ;;
    *)
      printf 'sh\n'
      ;;
  esac
}

cleanup() {
  if [[ -n "$SRC_COPY" && "$KEEP_SRC_COPY" -eq 0 ]]; then
    rm -rf "$SRC_COPY"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --artifacts-dir)
      ARTIFACTS_DIR="$2"
      shift 2
      ;;
    --home-root)
      HOME_ROOT="$2"
      shift 2
      ;;
    --src-copy)
      SRC_COPY="$2"
      KEEP_SRC_COPY=1
      shift 2
      ;;
    --keep-src-copy)
      KEEP_SRC_COPY=1
      shift
      ;;
    --version)
      if [[ "${#VERSIONS[@]}" -eq 3 && "${VERSIONS[*]}" == "202 209 352" ]]; then
        VERSIONS=()
      fi
      VERSIONS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$ARTIFACTS_DIR" ]]; then
  echo "Artifacts directory not found: $ARTIFACTS_DIR" >&2
  exit 2
fi

if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "Docker image not found: $IMAGE_TAG" >&2
  exit 2
fi

if [[ -z "$SRC_COPY" ]]; then
  SRC_COPY="$(mktemp -d "${TMPDIR:-/tmp}/rackup-legacy-src.XXXXXX")"
fi

mkdir -p "$SRC_COPY"
"$ROOT_DIR/scripts/copy-filtered-tree.sh" "$ROOT_DIR" "$SRC_COPY"

versions_csv=""
for version in "${VERSIONS[@]}"; do
  if [[ -z "$versions_csv" ]]; then
    versions_csv="$version"
  else
    versions_csv="$versions_csv,$version"
  fi
  ext="$(artifact_ext_for_version "$version")"
  artifact="$ARTIFACTS_DIR/plt-$version-bin-i386-linux.$ext"
  if [[ ! -f "$artifact" ]]; then
    echo "Missing artifact for $version: $artifact" >&2
    exit 2
  fi
done

echo "Using Docker image: $IMAGE_TAG"
echo "Using artifacts dir: $ARTIFACTS_DIR"
echo "Using filtered source copy: $SRC_COPY"
echo "Versions: $versions_csv"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME="$HOME_ROOT" \
  -e RACKUP_LEGACY_VERSIONS="$versions_csv" \
  -v "$SRC_COPY:/work" \
  -v "$ARTIFACTS_DIR:/artifacts:ro" \
  "$IMAGE_TAG" \
  bash -lc '
    set -euo pipefail

    artifact_ext_for_version() {
      case "$1" in
        053|102|103|103p1|200|201|202|205)
          printf "tgz\n"
          ;;
        *)
          printf "sh\n"
          ;;
      esac
    }

    loader_present() {
      for p in /lib/ld-linux.so.2 \
               /lib32/ld-linux.so.2 \
               /lib/i386-linux-gnu/ld-linux.so.2 \
               /lib/i686-linux-gnu/ld-linux.so.2 \
               /usr/i386-linux-gnu/lib/ld-linux.so.2; do
        if [[ -e "$p" ]]; then
          printf "yes\n"
          return 0
        fi
      done
      printf "no\n"
    }

    mkdir -p "$HOME"
    printf "loader_present=%s\n" "$(loader_present)"

    IFS="," read -r -a versions <<< "$RACKUP_LEGACY_VERSIONS"
    for ver in "${versions[@]}"; do
      [[ -n "$ver" ]] || continue
      ext="$(artifact_ext_for_version "$ver")"
      artifact="/artifacts/plt-$ver-bin-i386-linux.$ext"
      export RACKUP_HOME="$HOME/$ver"
      rm -rf "$RACKUP_HOME"
      mkdir -p "$RACKUP_HOME/cache/downloads"
      cp "$artifact" "$RACKUP_HOME/cache/downloads/"

      printf "== install %s ==\n" "$ver"
      if racket /work/libexec/rackup-core.rkt install --arch i386 "$ver" >/tmp/install-"$ver".out 2>/tmp/install-"$ver".err; then
        printf "install_status=ok\n"
        cat /tmp/install-"$ver".out
      else
        printf "install_status=fail\n"
        cat /tmp/install-"$ver".err
      fi

      printf "== run %s ==\n" "$ver"
      if "$RACKUP_HOME/shims/mzscheme" -v >/tmp/run-"$ver".out 2>/tmp/run-"$ver".err; then
        printf "run_status=ok\n"
        cat /tmp/run-"$ver".out
      else
        printf "run_status=fail\n"
        cat /tmp/run-"$ver".err
      fi
    done
  '
