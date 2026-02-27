#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST_RACKET="${RACKUP_E2E_HOST_RACKET:-absent}"
TRACE="${RACKUP_TRANSCRIPT_TRACE:-0}"
TRANSCRIPT_PATH="${RACKUP_TRANSCRIPT_PATH:-$ROOT_DIR/artifacts/transcripts/docker-transcript-matrix-test.txt}"

mkdir -p "$(dirname "$TRANSCRIPT_PATH")"

echo "Running transcript matrix test..."
echo "host_racket=$HOST_RACKET"
echo "trace=$TRACE"
echo "transcript=$TRANSCRIPT_PATH"

"$ROOT_DIR/scripts/docker-run-transcript-matrix.sh" \
  --host-racket "$HOST_RACKET" \
  --trace "$TRACE" \
  --transcript "$TRANSCRIPT_PATH"

echo "Asserting transcript content..."

require_pattern() {
  local pattern="$1"
  local label="$2"
  if ! rg -q -- "$pattern" "$TRANSCRIPT_PATH"; then
    echo "FAIL: missing expected transcript marker: $label ($pattern)" >&2
    exit 1
  fi
}

reject_pattern() {
  local pattern="$1"
  local label="$2"
  if rg -q -- "$pattern" "$TRANSCRIPT_PATH"; then
    echo "FAIL: found error marker in transcript: $label ($pattern)" >&2
    rg -n -- "$pattern" "$TRANSCRIPT_PATH" >&2 || true
    exit 1
  fi
}

require_pattern "== Done ==" "matrix completion"
require_pattern "Installed release-5.2-bc-x86_64-linux-minimal" "legacy minimal install"
require_pattern "Installed release-9.1-cs-x86_64-linux-full" "stable full install"
require_pattern "package isolation confirmed" "package isolation check"
require_pattern "rackup uninstalled." "final uninstall"
require_pattern "release-5.2-bc-x86_64-linux-minimal[[:space:]]+\\(default\\)" "legacy default switch"

reject_pattern "E2E failure:" "script failure sentinel"
reject_pattern "^rackup: no matching installed toolchain:" "toolchain resolution errors"
reject_pattern "unknown install flag:" "flag parser failures"
reject_pattern "timed out" "timeout failures"
reject_pattern "unexpected shared package visibility" "package leakage"
reject_pattern "cannot open shared object file" "missing runtime deps surfaced in session"

echo "Transcript matrix test PASSED"
