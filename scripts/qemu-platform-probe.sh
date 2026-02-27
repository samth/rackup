#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLATFORM=""
EXPECTED_ARCH=""
BASE_IMAGE="${RACKUP_QEMU_BASE_IMAGE:-debian:12}"
MODE="detect"

usage() {
  cat <<'USAGE'
Run architecture/platform detection checks in an emulated Docker container.

Usage:
  scripts/qemu-platform-probe.sh --platform P --expected-arch A [options]

Options:
  --platform P         Docker platform (example: linux/riscv64, linux/arm/v7, linux/386)
  --expected-arch A    Expected normalized rackup arch token (x86_64, aarch64, i386, arm, riscv64, ppc)
  --base-image IMAGE   Base image for emulated container (default: debian:12)
  --mode M             detect|download|runtime-install (default: detect)
  -h, --help           Show help

Modes:
  detect          Verify architecture detection only (no network, no install).
  download        Verify detection + hidden-runtime installer selection + artifact download/extractability.
  runtime-install Additionally install hidden runtime and run Racket-side arch detection.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    --expected-arch)
      EXPECTED_ARCH="$2"
      shift 2
      ;;
    --base-image)
      BASE_IMAGE="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
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

if [[ -z "$PLATFORM" || -z "$EXPECTED_ARCH" ]]; then
  usage >&2
  exit 2
fi

case "$MODE" in
  detect|download|runtime-install) ;;
  *)
    echo "Invalid --mode: $MODE (expected detect|download|runtime-install)" >&2
    exit 2
    ;;
esac

echo "QEMU probe: platform=$PLATFORM expected_arch=$EXPECTED_ARCH mode=$MODE base_image=$BASE_IMAGE"

docker run --rm \
  --platform "$PLATFORM" \
  -e EXPECTED_ARCH="$EXPECTED_ARCH" \
  -e QEMU_PROBE_MODE="$MODE" \
  -e DEBIAN_FRONTEND=noninteractive \
  -v "$ROOT_DIR:/work" \
  -w /work \
  "$BASE_IMAGE" \
  /bin/sh -c '
set -eu

. /work/libexec/rackup-bootstrap.sh

detected_arch="$(rackup_normalized_arch)"
if [ "$detected_arch" != "$EXPECTED_ARCH" ]; then
  echo "arch mismatch: expected=$EXPECTED_ARCH detected=$detected_arch" >&2
  exit 1
fi

if [ "$QEMU_PROBE_MODE" = "detect" ]; then
  echo "QEMU probe passed: arch=$detected_arch mode=$QEMU_PROBE_MODE"
  exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends bash ca-certificates coreutils curl grep sed tar xz-utils >/dev/null
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache bash ca-certificates coreutils curl grep sed tar xz >/dev/null
else
  echo "unsupported package manager in base image for mode=$QEMU_PROBE_MODE" >&2
  exit 1
fi

stable_ver="$(rackup_lookup_stable_version_shell)"
filename="$(rackup_select_hidden_runtime_filename "$stable_ver" "$detected_arch")"
installer_url="https://download.racket-lang.org/installers/$stable_ver/$filename"
tmp_installer="$(mktemp "${TMPDIR:-/tmp}/rackup-qemu-installer.XXXXXX")"
rackup_download_to "$installer_url" "$tmp_installer"
[ -s "$tmp_installer" ] || { echo "downloaded installer is empty: $installer_url" >&2; exit 1; }

case "$filename" in
  *.sh)
    head -n 1 "$tmp_installer" | grep -Eq "^#!" || true
    ;;
  *.tgz)
    tar -tzf "$tmp_installer" >/dev/null
    ;;
  *)
    echo "unexpected installer extension: $filename" >&2
    exit 1
    ;;
esac
rm -f "$tmp_installer"

if [ "$QEMU_PROBE_MODE" = "runtime-install" ]; then
  export HOME=/tmp/rackup-qemu-home
  export RACKUP_HOME="$HOME/.rackup"
  mkdir -p "$HOME"
  rackup_hidden_runtime_install_if_missing
  runtime_racket="$(rackup_runtime_current_racket)"
  [ -x "$runtime_racket" ] || { echo "runtime racket missing: $runtime_racket" >&2; exit 1; }
  probe_src=/tmp/rackup-probe-src
  rm -rf "$probe_src"
  mkdir -p "$probe_src"
  /work/scripts/copy-filtered-tree.sh /work "$probe_src" libexec
  "$runtime_racket" -e "(display (version))" >/tmp/rackup-qemu-runtime-version.txt
  "$runtime_racket" -e "(require (file \"$probe_src/libexec/rackup/versioning.rkt\")) (display (normalized-host-arch))" >/tmp/rackup-qemu-runtime-arch.txt
  runtime_arch="$(cat /tmp/rackup-qemu-runtime-arch.txt)"
  if [ "$runtime_arch" != "$EXPECTED_ARCH" ]; then
    echo "runtime detection mismatch: expected=$EXPECTED_ARCH runtime=$runtime_arch" >&2
    exit 1
  fi
fi

echo "QEMU probe passed: arch=$detected_arch stable=$stable_ver installer=$filename mode=$QEMU_PROBE_MODE"
'
