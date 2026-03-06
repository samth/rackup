#!/bin/sh
set -eu

# Benchmark rackup startup time across three modes:
#   1. Current: source .rkt with per-module machine-dependent .zo
#   2. Demodularized machine-dependent .zo
#   3. Demodularized machine-independent .zo (no recompilation)
#
# Usage: bench-startup.sh [ITERATIONS]
#   Run from the rackup repo root.  A Racket installation must be on PATH.

ITERATIONS="${1:-10}"
LIBEXEC_DIR="$(cd "$(dirname "$0")/../libexec" && pwd)"
CORE_RKT="$LIBEXEC_DIR/rackup-core.rkt"
MERGED_ZO="$LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo"
MI_BACKUP="$LIBEXEC_DIR/compiled/rackup-core_rkt_merged_mi.zo"

if ! command -v racket >/dev/null 2>&1; then
  echo "bench-startup.sh: racket not found on PATH" >&2
  exit 1
fi

bench() {
  label="$1"; shift
  echo ""
  echo "=== $label ==="
  # Warm-up run (discard)
  "$@" version >/dev/null 2>&1 || true
  total=0
  i=0
  while [ "$i" -lt "$ITERATIONS" ]; do
    start=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    "$@" version >/dev/null 2>&1 || true
    end=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1e9))')
    elapsed_ms=$(( (end - start) / 1000000 ))
    printf "  run %2d: %d ms\n" "$((i+1))" "$elapsed_ms"
    total=$((total + elapsed_ms))
    i=$((i+1))
  done
  avg=$((total / ITERATIONS))
  echo "  avg: ${avg} ms (${ITERATIONS} iterations)"
}

# --- Mode 1: Current (source .rkt with per-module compiled .zo) ---
# First, ensure per-module .zo files exist via managed-compile-zo
echo "Preparing Mode 1: compiling per-module .zo from source..."
racket -l- compiler/cm -e \
  '(managed-compile-zo (path->complete-path (string->path (vector-ref (current-command-line-arguments) 0))))' \
  -- "$CORE_RKT"
bench "Mode 1: Source .rkt (per-module machine-dependent .zo)" \
  racket -U "$CORE_RKT"

# --- Mode 2 & 3: Demodularized ---
if [ ! -f "$MERGED_ZO" ]; then
  echo ""
  echo "Building demodularized .zo..."
  "$(dirname "$0")/build-demod.sh" "$LIBEXEC_DIR"
fi

# Save machine-independent version for Mode 3
cp "$MERGED_ZO" "$MI_BACKUP"

# --- Mode 3: machine-independent .zo (before recompilation) ---
bench "Mode 3: Demodularized machine-independent .zo" \
  racket -U "$MERGED_ZO"

# --- Mode 2: Recompile to machine-dependent ---
echo ""
echo "Recompiling demod .zo to machine-dependent..."
raco demod -r "$MERGED_ZO"

bench "Mode 2: Demodularized machine-dependent .zo" \
  racket -U "$MERGED_ZO"

# Restore MI backup for future runs
cp "$MI_BACKUP" "$MERGED_ZO"
rm -f "$MI_BACKUP"

echo ""
echo "Done."
