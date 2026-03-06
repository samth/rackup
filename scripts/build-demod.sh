#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: build-demod.sh LIBEXEC_DIR

Compiles rackup-core.rkt into a demodularized machine-independent .zo file.
The output is placed at LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo.

This script must be run with a Racket installation that includes the
compiler/demodularizer package.
EOF
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

LIBEXEC_DIR="$1"
CORE="$LIBEXEC_DIR/rackup-core.rkt"

if [ ! -f "$CORE" ]; then
  echo "build-demod.sh: rackup-core.rkt not found at $CORE" >&2
  exit 1
fi

# Step 1: Compile all sources to machine-independent .zo via compiler/cm.
# The -M flag sets (current-compile-target-machine #f) for MI output.
racket -M -l- compiler/cm -e \
  '(managed-compile-zo (path->complete-path (string->path (vector-ref (current-command-line-arguments) 0))))' \
  -- "$CORE"

# Step 2: Demodularize into a single merged machine-independent .zo.
raco demod -M "$CORE"

# Step 3: Verify output.
MERGED="$LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo"
if [ ! -f "$MERGED" ]; then
  echo "build-demod.sh: expected output not found at $MERGED" >&2
  exit 1
fi

echo "build-demod.sh: created $MERGED"
