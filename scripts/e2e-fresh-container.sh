#!/usr/bin/env bash
set -euo pipefail

MODE="${RACKUP_E2E_MODE:-direct}"
SPECS_CSV="${RACKUP_E2E_SPECS:-stable}"
SNAPSHOT_SITE="${RACKUP_E2E_SNAPSHOT_SITE:-auto}"
UNIT_TESTS="${RACKUP_E2E_UNIT_TESTS:-0}"
LOCAL_LINK_MODE="${RACKUP_E2E_LOCAL_LINK_MODE:-fake}"
SOURCE_BUILD_REPO="${RACKUP_E2E_SOURCE_BUILD_REPO:-https://github.com/racket/racket.git}"
SOURCE_BUILD_REF="${RACKUP_E2E_SOURCE_BUILD_REF:-v8.18}"
SOURCE_BUILD_TARGET="${RACKUP_E2E_SOURCE_BUILD_TARGET:-base}"
SOURCE_BUILD_JOBS="${RACKUP_E2E_SOURCE_BUILD_JOBS:-2}"
HOST_RACKET="${RACKUP_E2E_HOST_RACKET:-present}"

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

assert_nonempty() {
  local value="$1"
  local msg="${2:-assert_nonempty failed}"
  [[ -n "$value" ]] || fail "$msg"
}

echo "== Container environment =="
echo "mode=$MODE"
echo "specs=$SPECS_CSV"
echo "snapshot_site=$SNAPSHOT_SITE"
echo "local_link_mode=$LOCAL_LINK_MODE"
echo "host_racket_mode=$HOST_RACKET"
if [[ "$LOCAL_LINK_MODE" == "build" ]]; then
  echo "source_build_repo=$SOURCE_BUILD_REPO"
  echo "source_build_ref=$SOURCE_BUILD_REF"
  echo "source_build_target=$SOURCE_BUILD_TARGET"
  echo "source_build_jobs=$SOURCE_BUILD_JOBS"
fi
echo "HOME=$HOME"
echo "PWD=$(pwd)"
host_racket_path="$(command -v racket || true)"
echo "host-racket=${host_racket_path:-<missing>}"
if [[ -n "$host_racket_path" ]]; then
  racket -v || true
fi

if [[ "$MODE" == "direct" && "$HOST_RACKET" == "absent" ]]; then
  fail "direct mode requires a host racket; use --mode bootstrap for host-racket absent"
fi

echo
echo "== Preparing fresh source copy (excluding compiled artifacts) =="
rm -rf "$RUN_SRC"
mkdir -p "$RUN_SRC"
"$WORKDIR/scripts/copy-filtered-tree.sh" "$WORKDIR" "$RUN_SRC"
echo "RUN_SRC=$RUN_SRC"

if [[ "$UNIT_TESTS" == "1" ]]; then
  [[ -n "$host_racket_path" ]] || fail "unit tests require host racket in the container"
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
elif [[ "$MODE" == "bootstrap-curl" ]]; then
  echo
  echo "== Installing rackup via curl | sh (local Pages server) =="
  export RACKUP_HOME="$HOME/.rackup-bootstrap-curl"
  rm -rf "$RACKUP_HOME"
  if [[ -n "${RACKUP_E2E_PREBUILT_PAGES_DIR:-}" ]]; then
    PAGES_DIR="$RACKUP_E2E_PREBUILT_PAGES_DIR"
  else
    PAGES_DIR="$TMPDIR/rackup-pages-site"
    rm -rf "$PAGES_DIR"
    sh "$RUN_SRC/scripts/build-pages-site.sh" "$PAGES_DIR"
  fi
  PAGES_PORT="${RACKUP_E2E_PAGES_PORT:-18765}"
  python3 -m http.server --bind 127.0.0.1 "$PAGES_PORT" --directory "$PAGES_DIR" >/tmp/rackup-e2e-pages.log 2>&1 &
  PAGES_SERVER_PID=$!
  cleanup_pages_server() {
    if [[ -n "${PAGES_SERVER_PID:-}" ]]; then
      kill "$PAGES_SERVER_PID" >/dev/null 2>&1 || true
      wait "$PAGES_SERVER_PID" 2>/dev/null || true
    fi
  }
  trap cleanup_pages_server EXIT
  BOOT_URL="http://127.0.0.1:${PAGES_PORT}/install.sh"
  ARCHIVE_URL="http://127.0.0.1:${PAGES_PORT}/rackup-src.tar.gz"
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${PAGES_PORT}/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  if ! curl -fsSL "$BOOT_URL" | sh -s -- -y --archive-url "$ARCHIVE_URL"; then
    echo "Local Pages server log:" >&2
    sed -n '1,200p' /tmp/rackup-e2e-pages.log >&2 || true
    fail "curl | sh bootstrap failed"
  fi
  RACKUP_BIN="$RACKUP_HOME/bin/rackup"
else
  echo
  echo "== Using repo rackup directly =="
  export RACKUP_HOME="$HOME/.rackup-direct"
  rm -rf "$RACKUP_HOME"
  mkdir -p "$RACKUP_HOME/bin" "$RACKUP_HOME/libexec"
  "$RUN_SRC/scripts/copy-filtered-tree.sh" "$RUN_SRC" "$RACKUP_HOME" bin libexec
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
  run_rackup current id
}

current_shim_version() {
  shim_racket -e '(display (version))'
}

assert_rackup_self_compiled() {
  local core_zo="$RACKUP_HOME/libexec/compiled/rackup-core_rkt.zo"
  local main_zo="$RACKUP_HOME/libexec/rackup/compiled/main_rkt.zo"
  [[ -f "$core_zo" ]] || fail "expected rackup core bytecode at $core_zo"
  [[ -f "$main_zo" ]] || fail "expected rackup main bytecode at $main_zo"
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

create_fake_local_source_tree() {
  local root="${TMPDIR}/rackup-e2e-local-src"
  local plthome="$root/racket"
  local bin_dir="$plthome/bin"
  local chez_bin_dir="$root/racket/src/build/cs/c/ChezScheme/pb/bin/pb"
  rm -rf "$root"
  mkdir -p "$bin_dir" "$plthome/collects" "$root/pkgs" "$chez_bin_dir"
  cat > "$bin_dir/racket" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
  case "$2" in
    *"(version)"*) printf '9.99-local'; exit 0 ;;
    *"system-type 'vm"*) printf 'cs'; exit 0 ;;
    *'getenv "PLTHOME"'*) printf '%s' "${PLTHOME:-}"; exit 0 ;;
    *'getenv "PLTCOLLECTS"'*) printf '%s' "${PLTCOLLECTS:-}"; exit 0 ;;
    *'getenv "PLTADDONDIR"'*) printf '%s' "${PLTADDONDIR:-}"; exit 0 ;;
  esac
fi
printf 'PLTHOME=%s\n' "${PLTHOME:-}"
printf 'PLTCOLLECTS=%s\n' "${PLTCOLLECTS:-}"
printf 'PLTADDONDIR=%s\n' "${PLTADDONDIR:-}"
printf 'ARGS=%s\n' "$*"
EOF
  cat > "$bin_dir/raco" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE-RACO %s\n' "$*"
EOF
  cat > "$chez_bin_dir/scheme" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE-SCHEME %s\n' "$*"
EOF
  cat > "$chez_bin_dir/petite" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE-PETITE %s\n' "$*"
EOF
  chmod +x "$bin_dir/racket" "$bin_dir/raco" "$chez_bin_dir/scheme" "$chez_bin_dir/petite"
  echo "$root"
}

create_real_local_source_tree() {
  local root="${TMPDIR}/rackup-e2e-real-local-src"
  local archive version srcdist_root
  local -a build_args=()
  rm -rf "$root"
  if [[ "$SOURCE_BUILD_REPO" == "https://github.com/racket/racket.git" && "$SOURCE_BUILD_REF" =~ ^v?([0-9][0-9A-Za-z._-]*)$ ]]; then
    version="${BASH_REMATCH[1]}"
    archive="https://download.racket-lang.org/installers/${version}/racket-minimal-${version}-src-builtpkgs.tgz"
    echo "Downloading Racket source+builtpkgs archive: version=$version" >&2
    mkdir -p "$root"
    curl -fsSL "$archive" -o "$root/racket-src-builtpkgs.tgz" >&2
    tar -xzf "$root/racket-src-builtpkgs.tgz" -C "$root"
    srcdist_root="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'racket-*' | head -n 1)"
    [[ -n "$srcdist_root" ]] || fail "expected extracted Racket source distribution under $root"
    mkdir -p "$srcdist_root/src/build"
    if [[ "$SOURCE_BUILD_TARGET" == "base" ]]; then
      echo "Building installed local source tree from source+builtpkgs: target=default jobs=$SOURCE_BUILD_JOBS" >&2
    else
      build_args=("$SOURCE_BUILD_TARGET")
      echo "Building installed local source tree from source+builtpkgs: target=$SOURCE_BUILD_TARGET jobs=$SOURCE_BUILD_JOBS" >&2
    fi
    (
      cd "$srcdist_root/src/build"
      ../configure --prefix="$root/racket" >&2
      make -j"$SOURCE_BUILD_JOBS" "${build_args[@]}" >&2
      make install >&2
    ) >&2
  else
    echo "Cloning Racket source: repo=$SOURCE_BUILD_REPO ref=$SOURCE_BUILD_REF" >&2
    git clone --depth 1 --branch "$SOURCE_BUILD_REF" "$SOURCE_BUILD_REPO" "$root" >&2
    echo "Building Racket from source in-place: target=$SOURCE_BUILD_TARGET jobs=$SOURCE_BUILD_JOBS" >&2
    (
      cd "$root"
      make -j"$SOURCE_BUILD_JOBS" "$SOURCE_BUILD_TARGET" >&2
    ) >&2
  fi
  [[ -x "$root/racket/bin/racket" ]] || fail "expected built racket at $root/racket/bin/racket"
  echo "$root"
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
eval "\$("$RACKUP_BIN" switch "$toolchain_id")"
test "\${RACKUP_TOOLCHAIN}" = "$toolchain_id"
test "\${PLTADDONDIR}" = "$RACKUP_HOME/addons/$toolchain_id"
v="\$(racket -e '(display (version))')"
case "\$v" in
  ${expected_prefix}*) ;;
  *) echo "unexpected version via $shell_name shell snippet: \$v" >&2; exit 1 ;;
esac
eval "\$("$RACKUP_BIN" switch --unset)"
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
rackup switch "$toolchain_id"
test "\${RACKUP_TOOLCHAIN}" = "$toolchain_id"
v="\$(racket -e '(display (version))')"
case "\$v" in
  ${expected_prefix}*) ;;
  *) echo "unexpected version via $shell_name helper: \$v" >&2; exit 1 ;;
esac
rackup switch --unset
test -z "\${RACKUP_TOOLCHAIN:-}"
EOF
  )
  env -i HOME="$HOME" RACKUP_HOME="$RACKUP_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    "$shell_bin" -lc "$cmd"
}

echo
echo "== rackup smoke =="
run_rackup doctor
runtime_status="$(run_rackup runtime status)"
echo "$runtime_status"
if [[ "$MODE" == "bootstrap" || "$MODE" == "bootstrap-curl" ]]; then
  assert_contains "present: yes" "$runtime_status" "bootstrap should install hidden runtime"
  echo
  echo "== rackup self-precompile check =="
  assert_rackup_self_compiled
else
  assert_contains "present: " "$runtime_status" "runtime status output missing"
fi

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
  # `slideshow` is shimmed, but starting it in minimal headless images depends on
  # optional system graphics libraries that are outside rackup's control.
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
echo "== Local in-place source build link smoke =="
case "$LOCAL_LINK_MODE" in
  fake)
    local_src_root="$(create_fake_local_source_tree)"
    ;;
  build)
    local_src_root="$(create_real_local_source_tree)"
    ;;
  *)
    fail "unsupported local link mode: $LOCAL_LINK_MODE"
    ;;
esac
if [[ -d "${local_src_root}/racket/share/racket/collects" ]]; then
  local_collects_dir="${local_src_root}/racket/share/racket/collects"
else
  local_collects_dir="${local_src_root}/racket/collects"
fi
linked_id="$(run_rackup link localsrc "$local_src_root" --set-default | tail -n 1)"
assert_eq "local-localsrc" "$linked_id" "unexpected linked toolchain id"
run_rackup which racket --toolchain localsrc
run_rackup which raco --toolchain localsrc
run_rackup which scheme --toolchain localsrc
run_rackup which petite --toolchain localsrc
linked_version="$(shim_racket -e '(display (version))')"
if [[ "$LOCAL_LINK_MODE" == "fake" ]]; then
  assert_contains "9.99-local" "$linked_version" "linked fake source tree should report fake version"
else
  assert_nonempty "$linked_version" "linked source-built racket should report a version"
fi
linked_plthome="$(shim_racket -e '(display (or (getenv "PLTHOME") ""))')"
assert_eq "${local_src_root}/racket" "$linked_plthome" "linked shim should export PLTHOME"
linked_collects="$(shim_racket -e '(display (or (getenv "PLTCOLLECTS") ""))')"
assert_contains "${local_collects_dir}" "$linked_collects" "linked shim should export PLTCOLLECTS"
linked_addon="$(shim_racket -e '(display (or (getenv "PLTADDONDIR") ""))')"
assert_eq "${RACKUP_HOME}/addons/${linked_id}" "$linked_addon" "linked shim should export PLTADDONDIR"
link_run_plthome="$(run_rackup run localsrc -- racket -e '(display (or (getenv "PLTHOME") ""))')"
assert_eq "${local_src_root}/racket" "$link_run_plthome" "rackup run should apply linked toolchain env"
if [[ "$LOCAL_LINK_MODE" == "build" ]]; then
  run_rackup run localsrc -- raco help >/dev/null
  run_rackup run localsrc -- racket -e '(display "ok")' >/dev/null
  run_rackup run localsrc -- scheme --version >/dev/null
  run_rackup run localsrc -- petite --version >/dev/null
else
  fake_scheme_out="$(run_rackup run localsrc -- scheme --version)"
  fake_petite_out="$(run_rackup run localsrc -- petite --version)"
  assert_contains "FAKE-SCHEME --version" "$fake_scheme_out" "linked fake source tree should expose scheme"
  assert_contains "FAKE-PETITE --version" "$fake_petite_out" "linked fake source tree should expose petite"
fi
run_rackup default "$primary_id"

if [[ "$HOST_RACKET" == "absent" ]]; then
  echo
  echo "== Hidden runtime recovery failure-mode check =="
  rm -rf "$RACKUP_HOME/runtime"
  if run_rackup list >/tmp/rackup-e2e-missing-runtime.out 2>/tmp/rackup-e2e-missing-runtime.err; then
    fail "expected rackup to fail when hidden runtime is removed and no host racket is present"
  fi
  missing_err="$(cat /tmp/rackup-e2e-missing-runtime.err)"
  assert_contains "no Racket runtime available" "$missing_err" "missing-runtime error should mention runtime"
  assert_contains "install.sh" "$missing_err" "missing-runtime error should include recovery instructions"
fi

if [[ "$HOST_RACKET" != "absent" ]]; then
  echo
  echo "== rackup uninstall smoke =="
  test -d "$RACKUP_HOME"
  [[ -f "$HOME/.bashrc" ]] || fail "expected ~/.bashrc before uninstall"
  [[ -f "$HOME/.zshrc" ]] || fail "expected ~/.zshrc before uninstall"
  grep -q "rackup initialize" "$HOME/.bashrc" || fail "expected rackup init block in ~/.bashrc before uninstall"
  grep -q "rackup initialize" "$HOME/.zshrc" || fail "expected rackup init block in ~/.zshrc before uninstall"
  if ! uninstall_out="$(run_rackup uninstall --yes 2>&1)"; then
    printf '%s\n' "$uninstall_out" >&2
    fail "rackup uninstall --yes failed"
  fi
  assert_contains "WARNING:" "$uninstall_out" "uninstall should print warnings"
  assert_contains "rackup uninstalled." "$uninstall_out" "uninstall should confirm success"
  for _ in $(seq 1 20); do
    [[ ! -e "$RACKUP_HOME" ]] && break
    sleep 0.2
  done
  [[ ! -e "$RACKUP_HOME" ]] || fail "RACKUP_HOME should be removed by uninstall (after background cleanup)"
  if grep -q "rackup initialize" "$HOME/.bashrc"; then
    fail "rackup uninstall should remove ~/.bashrc managed block"
  fi
  if grep -q "rackup initialize" "$HOME/.zshrc"; then
    fail "rackup uninstall should remove ~/.zshrc managed block"
  fi
  [[ -d "$local_src_root" ]] || fail "local linked source tree should not be deleted by uninstall"
else
  echo
  echo "== rackup uninstall smoke =="
  echo "Skipping uninstall in host-racket-absent mode (this scenario intentionally destroys the hidden runtime for recovery testing)."
fi

echo
echo "Fresh-container install test PASSED"
