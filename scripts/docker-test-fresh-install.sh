#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${RACKUP_DOCKER_IMAGE:-rackup-e2e:local}"
BUILD=1
UNIT_TESTS=0
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
  --image TAG             Docker image tag (default: rackup-e2e:local)
  --no-build              Skip docker build and reuse existing image
  --mode direct|bootstrap Test repo directly or via scripts/install.sh (default: direct)
  --spec SPEC             Toolchain spec to install (repeatable; default: stable)
  --snapshot-site SITE    auto|utah|northwestern (only used for snapshot specs)
  --local-link-mode MODE  fake|build (default: fake)
  --source-build-repo URL Racket source repo to clone for local-link build mode
  --source-build-ref REF  Git ref/tag for source-build local-link mode (default: v8.18)
  --source-build-target T make target for source-build local-link mode (default: base)
  --source-build-jobs N   Parallel jobs for source-build local-link mode (default: 2)
  --host-racket MODE      present|absent system Racket in test image (default: present)
  --unit-tests            Also run repo unit tests in container before install smoke test
  -h, --help              Show help

Examples:
  scripts/docker-test-fresh-install.sh
  scripts/docker-test-fresh-install.sh --mode bootstrap --spec stable
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
  direct|bootstrap) ;;
  *)
    echo "Invalid mode: $MODE (expected direct|bootstrap)" >&2
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

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building Docker image ${IMAGE_TAG}..."
  if [[ "$HOST_RACKET" == "present" ]]; then
    docker build --build-arg INCLUDE_SYSTEM_RACKET=1 -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/Dockerfile.e2e" "$ROOT_DIR"
  else
    docker build --build-arg INCLUDE_SYSTEM_RACKET=0 -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/Dockerfile.e2e" "$ROOT_DIR"
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

docker run --rm \
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
  -v "$ROOT_DIR:/work" \
  -w /work \
  "$IMAGE_TAG" \
  bash /work/scripts/e2e-fresh-container.sh
