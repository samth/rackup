#!/usr/bin/env bash
set -euo pipefail

MODE="${RACKUP_E2E_MODE:-direct}"
SPECS_CSV="${RACKUP_E2E_SPECS:-stable}"
SNAPSHOT_SITE="${RACKUP_E2E_SNAPSHOT_SITE:-auto}"
UNIT_TESTS="${RACKUP_E2E_UNIT_TESTS:-0}"

WORKDIR="${WORKDIR:-/work}"
TEST_HOME="${HOME:-/tmp/rackup-e2e-home}"
export HOME="$TEST_HOME"
export TMPDIR="${TMPDIR:-/tmp}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
RUN_SRC="${TMPDIR}/rackup-src"

mkdir -p "$HOME"

echo "== Container environment =="
echo "mode=$MODE"
echo "specs=$SPECS_CSV"
echo "snapshot_site=$SNAPSHOT_SITE"
echo "HOME=$HOME"
echo "PWD=$(pwd)"
echo "host-racket=$(command -v racket)"
racket -v || true

echo
echo "== Preparing fresh source copy (excluding compiled artifacts) =="
rm -rf "$RUN_SRC"
mkdir -p "$RUN_SRC"
tar -C "$WORKDIR" \
  --exclude='.git' \
  --exclude='libexec/compiled' \
  --exclude='libexec/rackup/compiled' \
  --exclude='test/compiled' \
  -cf - . | tar -C "$RUN_SRC" -xf -
echo "RUN_SRC=$RUN_SRC"

if [[ "$UNIT_TESTS" == "1" ]]; then
  echo
  echo "== Running unit tests =="
  (
    cd "$RUN_SRC"
    TMPDIR=/tmp raco test test/versioning.rkt test/remote.rkt test/state-shims.rkt
  )
fi

if [[ "$MODE" == "bootstrap" ]]; then
  echo
  echo "== Installing rackup via bootstrap script =="
  export RACKUP_HOME="$HOME/.rackup-bootstrap"
  rm -rf "$RACKUP_HOME"
  bash "$RUN_SRC/scripts/install.sh" -y --from-local "$RUN_SRC"
  RACKUP_BIN="$RACKUP_HOME/bin/rackup"
else
  echo
  echo "== Using repo rackup directly =="
  export RACKUP_HOME="$HOME/.rackup-direct"
  RACKUP_BIN="$RUN_SRC/bin/rackup"
  chmod +x "$RACKUP_BIN"
  rm -rf "$RACKUP_HOME"
  mkdir -p "$RACKUP_HOME"
fi

echo
echo "== rackup smoke =="
RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" doctor

IFS=',' read -r -a SPECS <<< "$SPECS_CSV"
for spec in "${SPECS[@]}"; do
  [[ -n "$spec" ]] || continue
  echo
  echo "== Installing spec: $spec =="
  install_args=(install "$spec" --set-default)
  if [[ "$spec" == snapshot || "$spec" == snapshot:* || "$spec" == current ]]; then
    install_args+=(--snapshot-site "$SNAPSHOT_SITE")
  fi

  # Network endpoints can be flaky; retry once to reduce false negatives.
  if ! RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" "${install_args[@]}"; then
    echo "First install attempt failed for $spec, retrying once..."
    sleep 2
    RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" "${install_args[@]}"
  fi

  echo
  echo "== Verifying installed toolchain for $spec =="
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" list
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" current
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" which racket
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" which raco
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" which scribble

  "$RACKUP_HOME/shims/racket" --version
  "$RACKUP_HOME/shims/racket" -e '(displayln (version))'
  "$RACKUP_HOME/shims/raco" help >/dev/null
  "$RACKUP_HOME/shims/scribble" --help >/dev/null
done

echo
echo "== Shell init smoke =="
RACKUP_HOME="$RACKUP_HOME" HOME="$HOME" "$RACKUP_BIN" init --shell bash
test -f "$HOME/.bashrc"
grep -q "rackup initialize" "$HOME/.bashrc"

echo
echo "Fresh-container install test PASSED"
