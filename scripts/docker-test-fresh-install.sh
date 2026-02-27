#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${RACKUP_DOCKER_IMAGE:-}"
BASE_IMAGE="${RACKUP_DOCKER_BASE_IMAGE:-ubuntu:24.04}"
DOCKER_PLATFORM="${RACKUP_DOCKER_PLATFORM:-}"
BUILD=1
UNIT_TESTS=0
SKIP_PACKAGE_TESTS=0
MODE="direct"
SPECS=("stable")
CUSTOM_SPECS=0
SNAPSHOT_SITE="${RACKUP_E2E_SNAPSHOT_SITE:-auto}"
LOCAL_LINK_MODE="${RACKUP_E2E_LOCAL_LINK_MODE:-fake}"
SOURCE_BUILD_REPO="${RACKUP_E2E_SOURCE_BUILD_REPO:-https://github.com/racket/racket.git}"
SOURCE_BUILD_REF="${RACKUP_E2E_SOURCE_BUILD_REF:-v8.18}"
SOURCE_BUILD_TARGET="${RACKUP_E2E_SOURCE_BUILD_TARGET:-base}"
SOURCE_BUILD_JOBS="${RACKUP_E2E_SOURCE_BUILD_JOBS:-2}"
HOST_RACKET="${RACKUP_E2E_HOST_RACKET:-present}"
PREBUILT_PAGES_DIR=""

usage() {
  cat <<'USAGE'
Run a fresh-container end-to-end test of `rackup install ...`.

This builds (or reuses) a Docker image and validates that `rackup` installs
Racket toolchains into an empty `RACKUP_HOME`. By default the image includes a
system Racket for direct-mode tests, but host-Racket-less bootstrap mode can
also be tested with `--host-racket absent`.

Usage:
  scripts/docker-test-fresh-install.sh [options]

Options:
  --image TAG             Docker image tag (default: rackup-e2e:<host-racket>-<base-image>)
  --base-image IMAGE      Docker base image (default: ubuntu:24.04)
  --platform PLATFORM     Docker platform/arch (example: linux/arm64, linux/riscv64)
  --no-build              Skip docker build and reuse existing image
  --mode direct|bootstrap|bootstrap-curl
                        Test repo directly, via local scripts/install.sh, or via curl|sh from a local Pages server (default: direct)
  --spec SPEC             Toolchain spec to install (repeatable; default: stable)
  --snapshot-site SITE    auto|utah|northwestern (only used for snapshot specs)
  --local-link-mode MODE  fake|build (default: fake)
  --source-build-repo URL Racket source repo to clone for local-link build mode
  --source-build-ref REF  Git ref/tag for source-build local-link mode (default: v8.18)
  --source-build-target T make target for source-build local-link mode (default: base)
  --source-build-jobs N   Parallel jobs for source-build local-link mode (default: 2)
  --host-racket MODE      present|absent system Racket in test image (default: present)
  --skip-package-tests    Skip package-manager/isolation checks inside the container
  --unit-tests            Also run repo unit tests in container before install smoke test
  -h, --help              Show help

Examples:
  scripts/docker-test-fresh-install.sh
  scripts/docker-test-fresh-install.sh --mode bootstrap --spec stable
  scripts/docker-test-fresh-install.sh --mode bootstrap-curl --host-racket absent --spec stable
  scripts/docker-test-fresh-install.sh --spec stable --spec pre-release
  scripts/docker-test-fresh-install.sh --spec stable --local-link-mode build --source-build-ref v8.18
  scripts/docker-test-fresh-install.sh --mode bootstrap --host-racket absent --spec stable
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --base-image)
      BASE_IMAGE="$2"
      shift 2
      ;;
    --platform)
      DOCKER_PLATFORM="$2"
      shift 2
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --spec)
      if [[ "$CUSTOM_SPECS" -eq 0 ]]; then
        SPECS=()
        CUSTOM_SPECS=1
      fi
      SPECS+=("$2")
      shift 2
      ;;
    --snapshot-site)
      SNAPSHOT_SITE="$2"
      shift 2
      ;;
    --local-link-mode)
      LOCAL_LINK_MODE="$2"
      shift 2
      ;;
    --source-build-repo)
      SOURCE_BUILD_REPO="$2"
      shift 2
      ;;
    --source-build-ref)
      SOURCE_BUILD_REF="$2"
      shift 2
      ;;
    --source-build-target)
      SOURCE_BUILD_TARGET="$2"
      shift 2
      ;;
    --source-build-jobs)
      SOURCE_BUILD_JOBS="$2"
      shift 2
      ;;
    --host-racket)
      HOST_RACKET="$2"
      shift 2
      ;;
    --unit-tests)
      UNIT_TESTS=1
      shift
      ;;
    --skip-package-tests)
      SKIP_PACKAGE_TESTS=1
      shift
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

case "$MODE" in
  direct|bootstrap|bootstrap-curl) ;;
  *)
    echo "Invalid mode: $MODE (expected direct|bootstrap|bootstrap-curl)" >&2
    exit 2
    ;;
esac

case "$SNAPSHOT_SITE" in
  auto|utah|northwestern) ;;
  *)
    echo "Invalid snapshot site: $SNAPSHOT_SITE" >&2
    exit 2
    ;;
esac

case "$LOCAL_LINK_MODE" in
  fake|build) ;;
  *)
    echo "Invalid local-link mode: $LOCAL_LINK_MODE (expected fake|build)" >&2
    exit 2
    ;;
esac

case "$HOST_RACKET" in
  present|absent) ;;
  *)
    echo "Invalid host-racket mode: $HOST_RACKET (expected present|absent)" >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  if [[ -n "$PREBUILT_PAGES_DIR" ]]; then
    rm -rf "$PREBUILT_PAGES_DIR"
  fi
}
trap cleanup EXIT

if [[ -z "$IMAGE_TAG" ]]; then
  base_tag="${BASE_IMAGE//\//-}"
  base_tag="${base_tag//:/-}"
  platform_tag="${DOCKER_PLATFORM:-native}"
  platform_tag="${platform_tag//\//-}"
  platform_tag="${platform_tag//:/-}"
  IMAGE_TAG="rackup-e2e:${HOST_RACKET}-${base_tag}-${platform_tag}"
fi

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building Docker image ${IMAGE_TAG} (base=${BASE_IMAGE}, platform=${DOCKER_PLATFORM:-native})..."
  build_cmd=(docker build)
  if [[ -n "$DOCKER_PLATFORM" ]]; then
    if docker buildx version >/dev/null 2>&1; then
      build_cmd=(docker buildx build --load)
    fi
    build_cmd+=(--platform "$DOCKER_PLATFORM")
  fi
  if [[ "$HOST_RACKET" == "present" ]]; then
    "${build_cmd[@]}" \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      --build-arg INCLUDE_SYSTEM_RACKET=1 \
      -t "$IMAGE_TAG" \
      -f "$ROOT_DIR/docker/Dockerfile.e2e" \
      "$ROOT_DIR"
  else
    "${build_cmd[@]}" \
      --build-arg BASE_IMAGE="$BASE_IMAGE" \
      --build-arg INCLUDE_SYSTEM_RACKET=0 \
      -t "$IMAGE_TAG" \
      -f "$ROOT_DIR/docker/Dockerfile.e2e" \
      "$ROOT_DIR"
  fi
else
  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "Docker image not found: $IMAGE_TAG" >&2
    echo "Either remove --no-build or pass --image with an existing image tag." >&2
    exit 2
  fi
fi

speclist=""
for spec in "${SPECS[@]}"; do
  if [[ -z "$speclist" ]]; then
    speclist="$spec"
  else
    speclist="$speclist,$spec"
  fi
done

UID_GID="$(id -u):$(id -g)"
echo "Running fresh-container install test with specs: ${speclist}"

run_cmd=(docker run --rm)
if [[ -n "$DOCKER_PLATFORM" ]]; then
  run_cmd+=(--platform "$DOCKER_PLATFORM")
fi

if [[ "$MODE" == "bootstrap-curl" ]]; then
  if [[ -n "${RACKUP_E2E_PREBUILT_PAGES_DIR:-}" ]]; then
    PREBUILT_PAGES_DIR="$RACKUP_E2E_PREBUILT_PAGES_DIR"
  else
    PREBUILT_PAGES_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rackup-pages-prebuilt.XXXXXX")"
    sh "$ROOT_DIR/scripts/build-pages-site.sh" "$PREBUILT_PAGES_DIR"
  fi
  run_cmd+=(-v "$PREBUILT_PAGES_DIR:/prebuilt-pages:ro")
fi

"${run_cmd[@]}" \
  --user "$UID_GID" \
  -e HOME=/tmp/rackup-e2e-home \
  -e RACKUP_E2E_MODE="$MODE" \
  -e RACKUP_E2E_SPECS="$speclist" \
  -e RACKUP_E2E_SNAPSHOT_SITE="$SNAPSHOT_SITE" \
  -e RACKUP_E2E_LOCAL_LINK_MODE="$LOCAL_LINK_MODE" \
  -e RACKUP_E2E_SOURCE_BUILD_REPO="$SOURCE_BUILD_REPO" \
  -e RACKUP_E2E_SOURCE_BUILD_REF="$SOURCE_BUILD_REF" \
  -e RACKUP_E2E_SOURCE_BUILD_TARGET="$SOURCE_BUILD_TARGET" \
  -e RACKUP_E2E_SOURCE_BUILD_JOBS="$SOURCE_BUILD_JOBS" \
  -e RACKUP_E2E_HOST_RACKET="$HOST_RACKET" \
  -e RACKUP_E2E_UNIT_TESTS="$UNIT_TESTS" \
  -e RACKUP_E2E_SKIP_PACKAGE_TESTS="$SKIP_PACKAGE_TESTS" \
  -e RACKUP_E2E_PREBUILT_PAGES_DIR="${PREBUILT_PAGES_DIR:+/prebuilt-pages}" \
  -v "$ROOT_DIR:/work" \
  -w /work \
  "$IMAGE_TAG" \
  bash /work/scripts/e2e-fresh-container.sh
