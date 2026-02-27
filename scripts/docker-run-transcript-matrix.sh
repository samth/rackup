#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST_RACKET="${RACKUP_E2E_HOST_RACKET:-absent}"
BUILD=1
TRACE="${RACKUP_TRANSCRIPT_TRACE:-0}"
IMAGE_TAG="${RACKUP_DOCKER_IMAGE:-}"
TRANSCRIPT_PATH="${RACKUP_TRANSCRIPT_PATH:-}"

usage() {
  cat <<'USAGE'
Run the expanded transcript matrix in Docker and capture output to a file.

Usage:
  scripts/docker-run-transcript-matrix.sh [options]

Options:
  --host-racket present|absent   Include system racket in image (default: absent)
  --image TAG                    Docker image tag (default: rackup-e2e:<host-mode>)
  --no-build                     Reuse an existing image
  --trace 0|1                    Enable set -x in container script (default: 0)
  --transcript PATH              Output transcript path
  -h, --help                     Show help

Examples:
  scripts/docker-run-transcript-matrix.sh
  scripts/docker-run-transcript-matrix.sh --host-racket present
  scripts/docker-run-transcript-matrix.sh --no-build --image rackup-e2e:absent
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-racket)
      HOST_RACKET="$2"
      shift 2
      ;;
    --image)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --no-build)
      BUILD=0
      shift
      ;;
    --trace)
      TRACE="$2"
      shift 2
      ;;
    --transcript)
      TRANSCRIPT_PATH="$2"
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

case "$HOST_RACKET" in
  present|absent) ;;
  *)
    echo "Invalid --host-racket value: $HOST_RACKET (expected present|absent)" >&2
    exit 2
    ;;
esac

case "$TRACE" in
  0|1) ;;
  *)
    echo "Invalid --trace value: $TRACE (expected 0 or 1)" >&2
    exit 2
    ;;
esac

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="rackup-e2e:${HOST_RACKET}"
fi

if [[ -z "$TRANSCRIPT_PATH" ]]; then
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  TRANSCRIPT_PATH="$ROOT_DIR/artifacts/transcripts/docker-transcript-matrix-${stamp}.txt"
fi
mkdir -p "$(dirname "$TRANSCRIPT_PATH")"

if [[ "$BUILD" -eq 1 ]]; then
  echo "Building Docker image $IMAGE_TAG (host-racket=$HOST_RACKET)..."
  if [[ "$HOST_RACKET" == "present" ]]; then
    docker build --build-arg INCLUDE_SYSTEM_RACKET=1 -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/Dockerfile.e2e" "$ROOT_DIR"
  else
    docker build --build-arg INCLUDE_SYSTEM_RACKET=0 -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/Dockerfile.e2e" "$ROOT_DIR"
  fi
fi

{
  echo "rackup expanded docker transcript"
  echo "commit: $(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "image: $IMAGE_TAG"
  echo "host_racket: $HOST_RACKET"
  echo "trace: $TRACE"
  echo
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp/rackup-transcript-home \
    -e RACKUP_TRANSCRIPT_TRACE="$TRACE" \
    -v "$ROOT_DIR:/work" \
    -w /work \
    "$IMAGE_TAG" \
    bash /work/scripts/e2e-transcript-matrix-container.sh
} 2>&1 | tee "$TRANSCRIPT_PATH"

echo "Transcript written to $TRANSCRIPT_PATH"
