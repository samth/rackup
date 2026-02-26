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
PKG_SRC_ROOT="${TMPDIR}/rackup-e2e-pkgs"

mkdir -p "$HOME" "$PKG_SRC_ROOT"

fail() {
  echo "E2E failure: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assert_eq failed}"
  [[ "$expected" == "$actual" ]] || fail "$msg (expected='$expected' actual='$actual')"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-assert_contains failed}"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (needle='$needle' haystack='$haystack')"
}

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
  rm -rf "$RACKUP_HOME"
  mkdir -p "$RACKUP_HOME/bin" "$RACKUP_HOME/libexec"
  cp -R "$RUN_SRC/bin/." "$RACKUP_HOME/bin/"
  cp -R "$RUN_SRC/libexec/." "$RACKUP_HOME/libexec/"
  chmod +x "$RACKUP_HOME/bin/rackup"
  RACKUP_BIN="$RACKUP_HOME/bin/rackup"
fi

run_rackup() {
  RACKUP_HOME="$RACKUP_HOME" "$RACKUP_BIN" "$@"
}

shim_racket() {
  "$RACKUP_HOME/shims/racket" "$@"
}

shim_raco() {
  "$RACKUP_HOME/shims/raco" "$@"
}

shim_scribble() {
  "$RACKUP_HOME/shims/scribble" "$@"
}

current_toolchain_id() {
  run_rackup current | awk '{print $1}'
}

current_shim_version() {
  shim_racket -e '(display (version))'
}

version_prefix_for_spec() {
  local spec="$1"
  case "$spec" in
    stable|pre-release|snapshot|snapshot:*|current) echo "" ;;
    *) echo "$spec" ;;
  esac
}

create_local_test_package() {
  local pkg_dir="$PKG_SRC_ROOT/rackup-e2e-pkg"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"
  cat > "$pkg_dir/info.rkt" <<'EOF'
#lang info
(define collection "rackup-e2e-pkg")
(define deps '("base"))
EOF
  cat > "$pkg_dir/main.rkt" <<'EOF'
#lang racket/base
(provide marker)
(define marker "rackup-e2e-package-ok")
EOF
  echo "$pkg_dir"
}

shell_eval_snippet_test() {
  local shell_name="$1"
  local toolchain_id="$2"
  local expected_prefix="$3"
  local shell_bin
  case "$shell_name" in
    bash) shell_bin="bash" ;;
    zsh) shell_bin="zsh" ;;
    *) fail "unsupported shell for snippet test: $shell_name" ;;
  esac

  local cmd
  cmd=$(
    cat <<EOF
set -euo pipefail
eval "\$("$RACKUP_BIN" shell "$toolchain_id")"
test "\${RACKUP_TOOLCHAIN}" = "$toolchain_id"
test "\${PLTADDONDIR}" = "$RACKUP_HOME/addons/$toolchain_id"
v="\$(racket -e '(display (version))')"
case "\$v" in
  ${expected_prefix}*) ;;
  *) echo "unexpected version via $shell_name shell snippet: \$v" >&2; exit 1 ;;
esac
eval "\$("$RACKUP_BIN" shell --deactivate)"
test -z "\${RACKUP_TOOLCHAIN:-}"
test -z "\${PLTADDONDIR:-}"
EOF
  )
  env -i HOME="$HOME" RACKUP_HOME="$RACKUP_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    "$shell_bin" -lc "$cmd"
}

shell_helper_function_test() {
  local shell_name="$1"
  local toolchain_id="$2"
  local expected_prefix="$3"
  local shell_bin rc_file
  case "$shell_name" in
    bash)
      shell_bin="bash"
      rc_file="$HOME/.bashrc"
      ;;
    zsh)
      shell_bin="zsh"
      rc_file="$HOME/.zshrc"
      ;;
    *)
      fail "unsupported shell for helper test: $shell_name"
      ;;
  esac
  [[ -f "$rc_file" ]] || fail "missing rc file for $shell_name: $rc_file"

  local cmd
  cmd=$(
    cat <<EOF
set -euo pipefail
source "$rc_file"
type rackup >/dev/null
rackup shell "$toolchain_id"
test "\${RACKUP_TOOLCHAIN}" = "$toolchain_id"
v="\$(racket -e '(display (version))')"
case "\$v" in
  ${expected_prefix}*) ;;
  *) echo "unexpected version via $shell_name helper: \$v" >&2; exit 1 ;;
esac
rackup shell --deactivate
test -z "\${RACKUP_TOOLCHAIN:-}"
EOF
  )
  env -i HOME="$HOME" RACKUP_HOME="$RACKUP_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    "$shell_bin" -lc "$cmd"
}

echo
echo "== rackup smoke =="
run_rackup doctor

IFS=',' read -r -a SPECS <<< "$SPECS_CSV"
declare -a INSTALLED_IDS=()
declare -a INSTALLED_SPECS=()
declare -A SPEC_TO_ID=()
declare -A SPEC_TO_PREFIX=()

for spec in "${SPECS[@]}"; do
  [[ -n "$spec" ]] || continue
  echo
  echo "== Installing spec: $spec =="
  install_args=(install "$spec" --set-default)
  if [[ "$spec" == snapshot || "$spec" == snapshot:* || "$spec" == current ]]; then
    install_args+=(--snapshot-site "$SNAPSHOT_SITE")
  fi

  if ! run_rackup "${install_args[@]}"; then
    echo "First install attempt failed for $spec, retrying once..."
    sleep 2
    run_rackup "${install_args[@]}"
  fi

  id="$(current_toolchain_id)"
  INSTALLED_IDS+=("$id")
  INSTALLED_SPECS+=("$spec")
  SPEC_TO_ID["$spec"]="$id"
  SPEC_TO_PREFIX["$spec"]="$(version_prefix_for_spec "$spec")"

  echo
  echo "== Verifying installed toolchain for $spec =="
  run_rackup list
  run_rackup current
  run_rackup which racket
  run_rackup which raco
  run_rackup which scribble
  run_rackup which slideshow

  shim_racket --version
  version_out="$(current_shim_version)"
  if [[ -n "${SPEC_TO_PREFIX[$spec]}" ]]; then
    assert_contains "${SPEC_TO_PREFIX[$spec]}" "$version_out" "shim version should match installed spec $spec"
  fi
  shim_raco help >/dev/null
  shim_scribble --help >/dev/null
  "$RACKUP_HOME/shims/slideshow" --help >/dev/null || true
done

echo
echo "== Toolchain switching and rackup run tests =="
if [[ ${#INSTALLED_IDS[@]} -ge 2 ]]; then
  first_id="${INSTALLED_IDS[0]}"
  first_spec="${INSTALLED_SPECS[0]}"
  last_index=$((${#INSTALLED_IDS[@]} - 1))
  last_id="${INSTALLED_IDS[$last_index]}"
  last_spec="${INSTALLED_SPECS[$last_index]}"

  run_rackup default "$first_id"
  v1="$(current_shim_version)"
  [[ -n "${SPEC_TO_PREFIX[$first_spec]}" ]] && assert_contains "${SPEC_TO_PREFIX[$first_spec]}" "$v1" "default switch to first toolchain failed"

  run_rackup default "$last_id"
  v2="$(current_shim_version)"
  [[ -n "${SPEC_TO_PREFIX[$last_spec]}" ]] && assert_contains "${SPEC_TO_PREFIX[$last_spec]}" "$v2" "default switch to last toolchain failed"

  run_out_first="$(run_rackup run "$first_id" -- racket -e '(display (version))')"
  [[ -n "${SPEC_TO_PREFIX[$first_spec]}" ]] && assert_contains "${SPEC_TO_PREFIX[$first_spec]}" "$run_out_first" "rackup run should execute first toolchain"

  run_out_last="$(run_rackup run "$last_id" -- racket -e '(display (version))')"
  [[ -n "${SPEC_TO_PREFIX[$last_spec]}" ]] && assert_contains "${SPEC_TO_PREFIX[$last_spec]}" "$run_out_last" "rackup run should execute last toolchain"
else
  echo "Only one toolchain installed; skipping multi-toolchain switching checks"
fi

echo
echo "== Package install / isolation tests =="
pkg_dir="$(create_local_test_package)"
primary_id="${INSTALLED_IDS[0]}"
run_rackup default "$primary_id"
shim_raco pkg install --auto --batch --no-setup "$pkg_dir"
shim_raco pkg show rackup-e2e-pkg >/dev/null
pkg_result="$(shim_racket -e '(require rackup-e2e-pkg) (display marker)')"
assert_eq "rackup-e2e-package-ok" "$pkg_result" "local package should load in primary toolchain"

if [[ ${#INSTALLED_IDS[@]} -ge 2 ]]; then
  secondary_id="${INSTALLED_IDS[$((${#INSTALLED_IDS[@]} - 1))]}"
  run_rackup default "$secondary_id"
  if shim_racket -e '(require rackup-e2e-pkg) (display marker)' >/tmp/rackup-e2e-no-pkg.out 2>/tmp/rackup-e2e-no-pkg.err; then
    fail "package installed in $primary_id unexpectedly visible in $secondary_id"
  else
    echo "Confirmed package isolation between $primary_id and $secondary_id"
  fi
  run_pkg="$(run_rackup run "$primary_id" -- racket -e '(require rackup-e2e-pkg) (display marker)')"
  assert_eq "rackup-e2e-package-ok" "$run_pkg" "rackup run should preserve package visibility for primary toolchain"
  run_rackup default "$secondary_id"
fi

echo
echo "== Shell init and activation smoke (bash + zsh) =="
run_rackup init --shell bash
run_rackup init --shell zsh
test -f "$HOME/.bashrc"
test -f "$HOME/.zshrc"
grep -q "rackup initialize" "$HOME/.bashrc"
grep -q "rackup initialize" "$HOME/.zshrc"

shell_test_id="${INSTALLED_IDS[0]}"
shell_test_spec="${INSTALLED_SPECS[0]}"
shell_test_prefix="${SPEC_TO_PREFIX[$shell_test_spec]}"
if [[ -z "$shell_test_prefix" ]]; then
  shell_test_prefix="$(run_rackup run "$shell_test_id" -- racket -e '(display (version))')"
fi

shell_eval_snippet_test bash "$shell_test_id" "$shell_test_prefix"
shell_eval_snippet_test zsh "$shell_test_id" "$shell_test_prefix"
shell_helper_function_test bash "$shell_test_id" "$shell_test_prefix"
shell_helper_function_test zsh "$shell_test_id" "$shell_test_prefix"

echo
echo "Fresh-container install test PASSED"
