#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${RACKUP_DOCKER_IMAGE:-rackup-e2e:local}"
BUILD=1
UNIT_TESTS=0
MODE="direct"
SPECS=("stable")
SNAPSHOT_SITE="${RACKUP_E2E_SNAPSHOT_SITE:-auto}"

usage() {
  cat <<'USAGE'
Run a fresh-container end-to-end test of `rackup install ...`.

This builds (or reuses) a Docker image with a system Racket installed only to
run `rackup` itself, then validates that `rackup` installs another Racket
toolchain into an empty `RACKUP_HOME`.

Usage:
  scripts/docker-test-fresh-install.sh [options]

Options:
  --image TAG             Docker image tag (default: rackup-e2e:local)
  --no-build              Skip docker build and reuse existing image
  --mode direct|bootstrap Test repo directly or via scripts/install.sh (default: direct)
  --spec SPEC             Toolchain spec to install (repeatable; default: stable)
  --snapshot-site SITE    auto|utah|northwestern (only used for snapshot specs)
  --unit-tests            Also run repo unit tests in container before install smoke test
  -h, --help              Show help

Examples:
  scripts/docker-test-fresh-install.sh
  scripts/docker-test-fresh-install.sh --mode bootstrap --spec stable
  scripts/docker-test-fresh-install.sh --spec stable --spec pre-release
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
      if [[ ${#SPECS[@]} -eq 1 && "${SPECS[0]}" == "stable" ]]; then
        SPECS=()
      fi
      SPECS+=("$2")
      shift 2
      ;;
    --snapshot-site)
      SNAPSHOT_SITE="$2"
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

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building Docker image ${IMAGE_TAG}..."
  docker build -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/Dockerfile.e2e" "$ROOT_DIR"
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
  -e RACKUP_E2E_UNIT_TESTS="$UNIT_TESTS" \
  -v "$ROOT_DIR:/work" \
  -w /work \
  "$IMAGE_TAG" \
  bash /work/scripts/e2e-fresh-container.sh
