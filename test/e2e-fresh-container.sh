#!/usr/bin/env bash
set -euo pipefail

MODE="${RACKUP_E2E_MODE:-direct}"
SPECS_CSV="${RACKUP_E2E_SPECS:-stable}"
SNAPSHOT_SITE="${RACKUP_E2E_SNAPSHOT_SITE:-auto}"
UNIT_TESTS="${RACKUP_E2E_UNIT_TESTS:-0}"
SKIP_PACKAGE_TESTS="${RACKUP_E2E_SKIP_PACKAGE_TESTS:-0}"
LOCAL_LINK_MODE="${RACKUP_E2E_LOCAL_LINK_MODE:-fake}"
SOURCE_BUILD_REPO="${RACKUP_E2E_SOURCE_BUILD_REPO:-https://github.com/racket/racket.git}"
SOURCE_BUILD_REF="${RACKUP_E2E_SOURCE_BUILD_REF:-v8.18}"
SOURCE_BUILD_COMMIT="${RACKUP_E2E_SOURCE_BUILD_COMMIT:-}"
SOURCE_BUILD_TARGET="${RACKUP_E2E_SOURCE_BUILD_TARGET:-base}"
SOURCE_BUILD_JOBS="${RACKUP_E2E_SOURCE_BUILD_JOBS:-2}"
PREBUILT_LOCAL_SOURCE_DIR="${RACKUP_E2E_PREBUILT_LOCAL_SOURCE_DIR:-}"
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

link_external_download_cache() {
  local target_home="$1"
  local external_cache="${RACKUP_E2E_DOWNLOAD_CACHE_DIR:-}"
  [[ -n "$external_cache" ]] || return 0
  mkdir -p "$target_home/cache"
  rm -rf "$target_home/cache/downloads"
  ln -s "$external_cache" "$target_home/cache/downloads"
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
echo "skip_package_tests=$SKIP_PACKAGE_TESTS"
echo "host_racket_mode=$HOST_RACKET"
if [[ "$LOCAL_LINK_MODE" == "build" ]]; then
  echo "source_build_repo=$SOURCE_BUILD_REPO"
  echo "source_build_ref=$SOURCE_BUILD_REF"
  echo "source_build_commit=${SOURCE_BUILD_COMMIT:-}"
  echo "source_build_target=$SOURCE_BUILD_TARGET"
  echo "source_build_jobs=$SOURCE_BUILD_JOBS"
  echo "prebuilt_local_source_dir=${PREBUILT_LOCAL_SOURCE_DIR:-}"
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
  link_external_download_cache "$RACKUP_HOME"
  bash "$RUN_SRC/scripts/install.sh" -y --from-local "$RUN_SRC"
  RACKUP_BIN="$RACKUP_HOME/bin/rackup"
elif [[ "$MODE" == "bootstrap-curl" ]]; then
  echo
  echo "== Installing rackup via curl | sh (local Pages server) =="
  export RACKUP_HOME="$HOME/.rackup-bootstrap-curl"
  rm -rf "$RACKUP_HOME"
  link_external_download_cache "$RACKUP_HOME"
  if [[ -n "${RACKUP_E2E_PREBUILT_PAGES_DIR:-}" ]]; then
    PAGES_DIR="$RACKUP_E2E_PREBUILT_PAGES_DIR"
  else
    PAGES_DIR="$TMPDIR/rackup-pages-site"
    rm -rf "$PAGES_DIR"
    racket -y "$RUN_SRC/pages/build-pages-site.rkt" "$PAGES_DIR"
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
  link_external_download_cache "$RACKUP_HOME"
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
    stable | pre-release | snapshot | snapshot:* | current) echo "" ;;
    *) echo "$spec" ;;
  esac
}

create_local_test_package() {
  local pkg_dir="$PKG_SRC_ROOT/rackup-e2e-pkg"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"
  cat >"$pkg_dir/info.rkt" <<'EOF'
#lang info
(define collection "rackup-e2e-pkg")
(define deps '("base"))
EOF
  cat >"$pkg_dir/main.rkt" <<'EOF'
#lang racket/base
(provide marker)
(define marker "rackup-e2e-package-ok")
EOF
  echo "$pkg_dir"
}

require_local_test_package() {
  shim_racket -e '(display (dynamic-require (quote rackup-e2e-pkg) (quote marker)))'
}

probe_local_test_package() {
  local err_file="$1"
  require_local_test_package 2>"$err_file" || true
}

create_fake_local_source_tree() {
  local root="${TMPDIR}/rackup-e2e-local-src"
  local plthome="$root/racket"
  local bin_dir="$plthome/bin"
  local chez_bin_dir="$root/racket/src/build/cs/c/ChezScheme/ta6le/bin/ta6le"
  local addon_dir="$root/add-on/development"
  rm -rf "$root"
  mkdir -p "$bin_dir" "$plthome/collects" "$root/pkgs" "$chez_bin_dir" "$addon_dir"
  cat >"$bin_dir/racket" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
default_addon_dir="$(cd "$(dirname "$0")/../.." && pwd)/add-on/development"
if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
  case "$2" in
    *"(version)"*) printf '9.99-local'; exit 0 ;;
    *"system-type 'vm"*) printf 'cs'; exit 0 ;;
    *"find-system-path"*addon-dir*) printf '%s' "${PLTADDONDIR:-$default_addon_dir}"; exit 0 ;;
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
  cat >"$bin_dir/raco" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE-RACO %s\n' "$*"
EOF
  cat >"$chez_bin_dir/scheme" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'FAKE-SCHEME %s\n' "$*"
EOF
  cat >"$chez_bin_dir/petite" <<'EOF'
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
  if [[ -n "$PREBUILT_LOCAL_SOURCE_DIR" && -d "$PREBUILT_LOCAL_SOURCE_DIR" ]]; then
    echo "Reusing prebuilt local source tree from image: $PREBUILT_LOCAL_SOURCE_DIR" >&2
    if [[ -f "$PREBUILT_LOCAL_SOURCE_DIR/.rackup-source-build-ref" ]]; then
      local recorded_ref
      recorded_ref="$(tr -d '\n' <"$PREBUILT_LOCAL_SOURCE_DIR/.rackup-source-build-ref")"
      [[ "$recorded_ref" == "$SOURCE_BUILD_REF" ]] || fail "prebuilt local source ref mismatch: expected '$SOURCE_BUILD_REF' got '$recorded_ref'"
    fi
    if [[ -n "$SOURCE_BUILD_COMMIT" && -f "$PREBUILT_LOCAL_SOURCE_DIR/.rackup-source-build-commit" ]]; then
      local recorded_commit
      recorded_commit="$(tr -d '\n' <"$PREBUILT_LOCAL_SOURCE_DIR/.rackup-source-build-commit")"
      [[ "$recorded_commit" == "$SOURCE_BUILD_COMMIT" ]] || fail "prebuilt local source commit mismatch: expected '$SOURCE_BUILD_COMMIT' got '$recorded_commit'"
    fi
    mkdir -p "$root"
    cp -a "$PREBUILT_LOCAL_SOURCE_DIR"/. "$root"/
    [[ -x "$root/racket/bin/racket" ]] || fail "expected prebuilt racket at $root/racket/bin/racket"
    echo "$root"
    return 0
  fi
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

# Self-upgrade test: only in bootstrap modes where the hidden runtime is already
# installed, so the test stays hermetic (no network download of a runtime).
if [[ "$MODE" == "bootstrap" || "$MODE" == "bootstrap-curl" ]]; then
  echo
  echo "== Self-upgrade smoke test =="
  # Self-upgrade using the local install.sh and local source tree so the test
  # is hermetic (no network fetch for the source tarball / binary).
  # RACKUP_SELF_UPGRADE_INSTALL_SH  → use the repo's install.sh directly
  # RACKUP_FROM_LOCAL               → install.sh installs from the local tree
  RACKUP_SELF_UPGRADE_INSTALL_SH="$RUN_SRC/scripts/install.sh" \
    RACKUP_FROM_LOCAL="$RUN_SRC" \
    run_rackup self-upgrade
  # After self-upgrade, basic commands should still work.
  run_rackup version
  run_rackup doctor
  post_upgrade_runtime="$(run_rackup runtime status)"
  echo "$post_upgrade_runtime"
  if [[ -x "$RACKUP_HOME/bin/rackup-core" ]]; then
    echo "Exe mode detected after self-upgrade."
    # In exe mode the hidden runtime directory should not exist.
    if [[ -d "$RACKUP_HOME/runtime/current" ]]; then
      fail "hidden runtime directory should not exist in exe mode after self-upgrade"
    fi
    assert_contains "embedded-exe" "$post_upgrade_runtime" "exe self-upgrade should report embedded-exe mode"
  else
    echo "Source mode detected after self-upgrade."
    assert_contains "present: yes" "$post_upgrade_runtime" "source self-upgrade should preserve hidden runtime"
  fi
fi

IFS=',' read -r -a SPECS <<<"$SPECS_CSV"
declare -a INSTALLED_IDS=()
declare -a INSTALLED_SPECS=()
# shellcheck disable=SC2034  # populated for debug/future use
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
  # shellcheck disable=SC2034
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
  if [[ "$spec" == "6.0" ]]; then
    echo "Skipping scribble execution smoke for 6.0 (upstream OpenSSL incompatibility on modern distros)"
  else
    shim_scribble --help >/dev/null
  fi
  # `slideshow` is shimmed, but starting it in minimal headless images depends on
  # optional system graphics libraries that are outside rackup's control.
done

primary_id="${INSTALLED_IDS[0]}"

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
if [[ "$SKIP_PACKAGE_TESTS" == "1" ]]; then
  echo "Skipping package tests for this scenario"
else
  pkg_dir="$(create_local_test_package)"
  run_rackup default "$primary_id"
  shim_raco pkg install --auto --batch --no-setup "$pkg_dir"
  shim_raco pkg show rackup-e2e-pkg >/dev/null
  pkg_err="$(mktemp)"
  pkg_result="$(probe_local_test_package "$pkg_err")"
  if [[ -s "$pkg_err" ]]; then
    cat "$pkg_err" >&2
    rm -f "$pkg_err"
    fail "local package probe emitted unexpected stderr in primary toolchain"
  fi
  rm -f "$pkg_err"
  assert_eq "rackup-e2e-package-ok" "$pkg_result" "local package should load in primary toolchain"

  if [[ ${#INSTALLED_IDS[@]} -ge 2 ]]; then
    secondary_id="${INSTALLED_IDS[$((${#INSTALLED_IDS[@]} - 1))]}"
    run_rackup default "$secondary_id"
    secondary_result="$(probe_local_test_package /tmp/rackup-e2e-no-pkg.err)"
    printf '%s' "$secondary_result" >/tmp/rackup-e2e-no-pkg.out
    if [[ "$secondary_result" == "rackup-e2e-package-ok" ]] && [[ ! -s /tmp/rackup-e2e-no-pkg.err ]]; then
      fail "package installed in $primary_id unexpectedly visible in $secondary_id"
    else
      echo "Confirmed package isolation between $primary_id and $secondary_id"
    fi
    run_pkg_err="$(mktemp)"
    run_pkg="$(run_rackup run "$primary_id" -- racket -e '(display (dynamic-require (quote rackup-e2e-pkg) (quote marker)))' 2>"$run_pkg_err" || true)"
    if [[ -s "$run_pkg_err" ]]; then
      cat "$run_pkg_err" >&2
      rm -f "$run_pkg_err"
      fail "rackup run package probe emitted unexpected stderr in primary toolchain"
    fi
    rm -f "$run_pkg_err"
    assert_eq "rackup-e2e-package-ok" "$run_pkg" "rackup run should preserve package visibility for primary toolchain"
    run_rackup default "$secondary_id"
  fi
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
echo "== Missing toolchain switch fails fast without a tty =="
missing_switch_err="$(
  # shellcheck disable=SC2016  # single quotes intentional: code runs in subshell
  env -i HOME="$HOME" RACKUP_HOME="$RACKUP_HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
    bash -lc '
      set -euo pipefail
      source "$RACKUP_HOME/shell/rackup.bash"
      if rackup switch 9.0 >/tmp/rackup-missing-switch.out 2>/tmp/rackup-missing-switch.err; then
        echo "unexpected success" >&2
        exit 1
      fi
      cat /tmp/rackup-missing-switch.err
    '
)"
assert_contains "no matching installed toolchain: 9.0" "$missing_switch_err" "missing switch should fail immediately without a tty"
assert_contains "Hint: run \`rackup install 9.0\` first" "$missing_switch_err" "missing switch should include install hint"

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
echo "linked_id=$linked_id"
run_rackup which racket --toolchain localsrc
run_rackup which raco --toolchain localsrc
run_rackup which scheme --toolchain localsrc
run_rackup which petite --toolchain localsrc
echo "linked executables resolved"
linked_version="$(shim_racket -e '(display (version))')"
if [[ "$LOCAL_LINK_MODE" == "fake" ]]; then
  assert_contains "9.99-local" "$linked_version" "linked fake source tree should report fake version"
else
  assert_nonempty "$linked_version" "linked source-built racket should report a version"
fi
echo "linked racket version=$linked_version"
linked_plthome="$(shim_racket -e '(display (or (getenv "PLTHOME") ""))')"
assert_eq "${local_src_root}" "$linked_plthome" "linked shim should export PLTHOME"
linked_collects="$(shim_racket -e '(display (or (getenv "PLTCOLLECTS") ""))')"
assert_contains "${local_collects_dir}" "$linked_collects" "linked shim should export PLTCOLLECTS"
linked_addon="$(shim_racket -e '(display (or (getenv "PLTADDONDIR") ""))')"
assert_nonempty "$linked_addon" "linked shim should export PLTADDONDIR"
linked_addon_path="$(shim_racket -e '(display (find-system-path (quote addon-dir)))')"
assert_eq "$linked_addon_path" "$linked_addon" "linked shim PLTADDONDIR should match the linked installation addon dir"
echo "linked shim environment verified"
link_run_plthome="$(run_rackup run localsrc -- racket -e '(display (or (getenv "PLTHOME") ""))')"
assert_eq "${local_src_root}" "$link_run_plthome" "rackup run should apply linked toolchain env"
echo "rackup run environment verified"
if [[ "$LOCAL_LINK_MODE" == "build" ]]; then
  run_rackup run localsrc -- raco help >/dev/null
  echo "linked raco ok"
  run_rackup run localsrc -- racket -e '(display "ok")' >/dev/null
  echo "linked racket ok"
  printf '(exit)\n' | run_rackup run localsrc -- scheme >/dev/null
  echo "linked scheme ok"
  printf '(exit)\n' | run_rackup run localsrc -- petite >/dev/null
  echo "linked petite ok"
else
  fake_scheme_out="$(run_rackup run localsrc -- scheme --version)"
  fake_petite_out="$(run_rackup run localsrc -- petite --version)"
  assert_contains "FAKE-SCHEME --version" "$fake_scheme_out" "linked fake source tree should expose scheme"
  assert_contains "FAKE-PETITE --version" "$fake_petite_out" "linked fake source tree should expose petite"
fi
run_rackup default "$primary_id"

echo
echo "== Upgrade path: install 9.0, then upgrade to stable (9.1) =="
# Only run if the first spec was NOT 9.0 already (avoid duplicate install)
# shellcheck disable=SC2034
upgrade_test_ran=0
first_spec_is_90=0
if [[ "${INSTALLED_SPECS[0]:-}" == "9.0" ]]; then
  first_spec_is_90=1
fi
if [[ "$first_spec_is_90" -eq 0 ]]; then
  # Install 9.0 to simulate an older installation
  if run_rackup install 9.0 --set-default; then
    # shellcheck disable=SC2034
    upgrade_test_ran=1
    old_id="$(current_toolchain_id)"
    assert_contains "release-9.0" "$old_id" "9.0 toolchain should be installed"
    old_version="$(current_shim_version)"
    assert_contains "9.0" "$old_version" "shim should report 9.0"

    # Now install stable (which resolves to 9.1) alongside it
    if ! run_rackup install stable --set-default; then
      echo "stable install attempt failed after 9.0, retrying..."
      sleep 2
      run_rackup install stable --set-default
    fi
    new_id="$(current_toolchain_id)"
    new_version="$(current_shim_version)"

    # Verify the upgrade resulted in a different (newer) version
    if [[ "$old_id" != "$new_id" ]]; then
      echo "Upgrade path verified: $old_id -> $new_id"
      echo "Version changed: $old_version -> $new_version"

      # Verify both toolchains are listed
      list_out="$(run_rackup list)"
      assert_contains "release-9.0" "$list_out" "9.0 should still be in list after upgrade"

      # Verify we can switch back to 9.0
      run_rackup default "$old_id"
      switchback_version="$(current_shim_version)"
      assert_contains "9.0" "$switchback_version" "switching back to 9.0 should work"

      # Switch back to the new version
      run_rackup default "$new_id"
      switch_new_version="$(current_shim_version)"
      echo "Switch back to new version: $switch_new_version"
    else
      echo "stable resolved to 9.0 (same as existing); upgrade path test skipped (already latest)"
    fi

    # Restore primary toolchain as default
    run_rackup default "$primary_id"
  else
    echo "9.0 install failed (may not be available); skipping upgrade path test"
  fi
else
  echo "First spec is already 9.0; upgrade path covered by multi-spec install"
fi

echo
echo "== Snapshot site tests: Utah and Northwestern =="
SNAPSHOT_TEST_SITES=()
if [[ "$SNAPSHOT_SITE" == "auto" || "$SNAPSHOT_SITE" == "utah" ]]; then
  SNAPSHOT_TEST_SITES+=("utah")
fi
if [[ "$SNAPSHOT_SITE" == "auto" || "$SNAPSHOT_SITE" == "northwestern" ]]; then
  SNAPSHOT_TEST_SITES+=("northwestern")
fi
for site in "${SNAPSHOT_TEST_SITES[@]}"; do
  echo
  echo "== Installing snapshot from site: $site =="
  if run_rackup install "snapshot:$site" --set-default; then
    snap_id="$(current_toolchain_id)"
    assert_contains "snapshot-${site}" "$snap_id" "snapshot ID should contain site name $site"
    snap_version="$(current_shim_version)"
    assert_nonempty "$snap_version" "snapshot from $site should report a version"
    echo "Snapshot $site installed: $snap_id (version=$snap_version)"

    # Verify metadata via list
    snap_list="$(run_rackup list)"
    assert_contains "snapshot-${site}" "$snap_list" "$site snapshot should appear in list"

    # Restore primary default
    run_rackup default "$primary_id"
  else
    echo "Snapshot install from $site failed on first attempt, retrying..."
    sleep 2
    if run_rackup install "snapshot:$site" --set-default; then
      snap_id="$(current_toolchain_id)"
      assert_contains "snapshot-${site}" "$snap_id" "snapshot ID should contain site name $site (retry)"
      echo "Snapshot $site installed on retry: $snap_id"
      run_rackup default "$primary_id"
    else
      echo "WARNING: Snapshot install from $site failed (site may be unavailable); skipping"
    fi
  fi
done

# If both Utah and Northwestern snapshots were installed, verify they coexist
if [[ ${#SNAPSHOT_TEST_SITES[@]} -ge 2 ]]; then
  snap_list="$(run_rackup list)"
  if [[ "$snap_list" == *"snapshot-utah"* ]] && [[ "$snap_list" == *"snapshot-northwestern"* ]]; then
    echo "Both Utah and Northwestern snapshots coexist successfully"
  else
    echo "Note: not all snapshot sites were successfully installed (this is OK if sites are unavailable)"
  fi
fi

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
  keep_file="$HOME/keep-me.txt"
  sibling_keep_dir="$HOME/rackup-e2e-keep-dir"
  sibling_keep_file="$sibling_keep_dir/keep.txt"
  local_src_keep_file="$local_src_root/keep-local.txt"
  printf 'keep\n' >"$keep_file"
  mkdir -p "$sibling_keep_dir"
  printf 'keep\n' >"$sibling_keep_file"
  printf 'keep\n' >"$local_src_keep_file"
  test -d "$RACKUP_HOME"
  [[ -f "$HOME/.bashrc" ]] || fail "expected ~/.bashrc before uninstall"
  [[ -f "$HOME/.zshrc" ]] || fail "expected ~/.zshrc before uninstall"
  grep -q "rackup initialize" "$HOME/.bashrc" || fail "expected rackup init block in ~/.bashrc before uninstall"
  grep -q "rackup initialize" "$HOME/.zshrc" || fail "expected rackup init block in ~/.zshrc before uninstall"
  if home_uninstall_out="$(env RACKUP_HOME="$HOME" "$RACKUP_BIN" uninstall --yes 2>&1)"; then
    printf '%s\n' "$home_uninstall_out" >&2
    fail "rackup uninstall should refuse HOME as RACKUP_HOME"
  fi
  assert_contains "unsafe rackup home target equal to your home directory" \
    "$home_uninstall_out" \
    "uninstall should refuse HOME as RACKUP_HOME"
  if root_uninstall_out="$(env RACKUP_HOME=/ "$RACKUP_BIN" uninstall --yes 2>&1)"; then
    printf '%s\n' "$root_uninstall_out" >&2
    fail "rackup uninstall should refuse / as RACKUP_HOME"
  fi
  assert_contains "unsafe rackup home target: /" \
    "$root_uninstall_out" \
    "uninstall should refuse / as RACKUP_HOME"
  old_home="$RACKUP_HOME"
  old_rackup_bin="$RACKUP_BIN"
  old_racket_shim="$RACKUP_HOME/shims/racket"
  old_raco_shim="$RACKUP_HOME/shims/raco"
  if ! uninstall_out="$(run_rackup uninstall --yes 2>&1)"; then
    printf '%s\n' "$uninstall_out" >&2
    fail "rackup uninstall --yes failed"
  fi
  assert_contains "WARNING:" "$uninstall_out" "uninstall should print warnings"
  assert_contains "rackup uninstalled." "$uninstall_out" "uninstall should confirm success"
  assert_contains "completed synchronously" "$uninstall_out" "uninstall should report synchronous deletion"
  if [[ "$uninstall_out" == *"Final file deletion may complete shortly"* ]]; then
    fail "uninstall should not report deferred deletion anymore"
  fi
  [[ ! -e "$old_home" ]] || fail "RACKUP_HOME should be removed by uninstall before returning"
  [[ ! -e "$old_rackup_bin" ]] || fail "rackup binary should be removed by uninstall"
  [[ ! -e "$old_racket_shim" ]] || fail "racket shim should be removed by uninstall"
  [[ ! -e "$old_raco_shim" ]] || fail "raco shim should be removed by uninstall"
  if grep -q "rackup initialize" "$HOME/.bashrc"; then
    fail "rackup uninstall should remove ~/.bashrc managed block"
  fi
  if grep -q "rackup initialize" "$HOME/.zshrc"; then
    fail "rackup uninstall should remove ~/.zshrc managed block"
  fi
  [[ -f "$keep_file" ]] || fail "uninstall should not delete unrelated files in HOME"
  [[ -f "$sibling_keep_file" ]] || fail "uninstall should not delete unrelated sibling directories"
  [[ -d "$local_src_root" ]] || fail "local linked source tree should not be deleted by uninstall"
  [[ -f "$local_src_keep_file" ]] || fail "uninstall should not delete files in linked local source tree"
else
  echo
  echo "== rackup uninstall smoke =="
  echo "Skipping uninstall in host-racket-absent mode (this scenario intentionally destroys the hidden runtime for recovery testing)."
fi

echo
echo "Fresh-container install test PASSED"
