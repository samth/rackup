#!/bin/sh
set -eu

# Build a prebuilt binary distribution of rackup using raco exe + raco distribute.
#
# Native build (on the target platform):
#   scripts/build-dist.sh --output dist/rackup-x86_64-linux.tar.gz
#
# Cross-compile (from any platform with raco cross installed):
#   scripts/build-dist.sh --cross i386-linux --output dist/rackup-i386-linux.tar.gz
#
# The output tarball contains:
#   rackup/
#     bin/rackup          (shell wrapper)
#     bin/rackup-core     (compiled binary from raco distribute)
#     lib/...             (shared libraries from raco distribute)
#     libexec/rackup-bootstrap.sh (shell helpers for prompt/arch detection)

CROSS_TARGET=""
OUTPUT=""
RACKET="${RACKET:-racket}"
RACO="${RACO:-raco}"

usage() {
  cat <<'USAGE'
Usage: build-dist.sh [--cross TARGET] --output FILE

Options:
  --cross TARGET   Cross-compile for TARGET using raco cross --target.
                   TARGET is a raco cross platform name, e.g. i386-linux, aarch64-linux.
  --output FILE    Output tarball path (e.g. dist/rackup-x86_64-linux.tar.gz).
  --racket EXE     Path to racket executable (default: racket).
  --raco EXE       Path to raco executable (default: raco).

Native build example:
  scripts/build-dist.sh --output dist/rackup-x86_64-linux.tar.gz

Cross-compile example:
  scripts/build-dist.sh --cross i386-linux --output dist/rackup-i386-linux.tar.gz
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cross)
      CROSS_TARGET="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --racket)
      RACKET="$2"
      shift 2
      ;;
    --raco)
      RACO="$2"
      shift 2
      ;;
    -h | --help)
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

if [ -z "$OUTPUT" ]; then
  echo "Error: --output is required" >&2
  usage >&2
  exit 2
fi

# shellcheck disable=SC1007
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/rackup-build-dist.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

BUILD_DIR="$TMPDIR_BUILD/build"
DIST_DIR="$TMPDIR_BUILD/dist"
STAGE_DIR="$TMPDIR_BUILD/rackup"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$STAGE_DIR"

echo "Building rackup binary distribution..."

# Step 1: Compile with raco exe
if [ -n "$CROSS_TARGET" ]; then
  echo "Cross-compiling for target: $CROSS_TARGET"
  "$RACO" cross --target "$CROSS_TARGET" exe \
    -o "$BUILD_DIR/rackup-core" \
    "$ROOT_DIR/libexec/rackup-core.rkt"
else
  echo "Native compilation..."
  "$RACO" exe -o "$BUILD_DIR/rackup-core" \
    "$ROOT_DIR/libexec/rackup-core.rkt"
fi

# Step 2: Create distributable with raco distribute
if [ -n "$CROSS_TARGET" ]; then
  "$RACO" cross --target "$CROSS_TARGET" distribute \
    "$DIST_DIR" \
    "$BUILD_DIR/rackup-core"
else
  "$RACO" distribute "$DIST_DIR" "$BUILD_DIR/rackup-core"
fi

# Step 3: Assemble the final distribution layout
#   rackup/
#     bin/rackup          (shell wrapper)
#     bin/rackup-core     (compiled binary)
#     lib/...             (shared libraries)
#     libexec/rackup-bootstrap.sh

mkdir -p "$STAGE_DIR/bin" "$STAGE_DIR/libexec"

# Copy compiled binary and libs from raco distribute output
cp "$DIST_DIR/bin/rackup-core" "$STAGE_DIR/bin/rackup-core"
chmod +x "$STAGE_DIR/bin/rackup-core"

if [ -d "$DIST_DIR/lib" ]; then
  cp -R "$DIST_DIR/lib" "$STAGE_DIR/lib"
fi

# Copy shell wrapper and bootstrap helpers
cp "$ROOT_DIR/bin/rackup" "$STAGE_DIR/bin/rackup"
chmod +x "$STAGE_DIR/bin/rackup"

cp "$ROOT_DIR/libexec/rackup-bootstrap.sh" "$STAGE_DIR/libexec/rackup-bootstrap.sh"
chmod +x "$STAGE_DIR/libexec/rackup-bootstrap.sh"

# Step 4: Create tarball
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT_NAME="$(basename "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"

tar -C "$TMPDIR_BUILD" -czf "$OUTPUT_DIR/$OUTPUT_NAME" rackup

echo "Built: $OUTPUT_DIR/$OUTPUT_NAME"
