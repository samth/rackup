#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: build-demod.sh LIBEXEC_DIR

Compiles rackup-core.rkt into a demodularized .zo file via raco demod.
The output is placed at LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo.

Flags used:
  -s  preserve syntax (required for define-runtime-path)
  -M  machine-independent output (recompiled to machine-dependent on install)
  -g  prune unused definitions
  -o  explicit output path into compiled/ directory
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

MERGED="$LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo"
mkdir -p "$(dirname "$MERGED")"

raco demod -s -M -g -o "$MERGED" "$CORE"

if [ ! -f "$MERGED" ]; then
  echo "build-demod.sh: expected output not found at $MERGED" >&2
  exit 1
fi

echo "build-demod.sh: created $MERGED"
