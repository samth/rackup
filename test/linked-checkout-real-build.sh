#!/usr/bin/env bash
# End-to-end test of a linked Racket source checkout, against a real
# in-place build of Racket.
#
# A linked toolchain must use plain `compiled/`, exactly like the
# checkout's own `make`, its own bin/racket, and direct `raco`.  This
# script checks that with real builds, which the unit tests (fake
# checkouts) cannot:
#
#   - The shim, `rackup run`, and the checkout's own binary see the same
#     environment: no PLTCOMPILEDROOTS, roots (same), the same addon dir.
#   - Packages and project files compiled through the shim land in plain
#     `compiled/`, and a no-op `make` afterwards recompiles nothing.
#   - Edits compiled by `make`, by the checkout's own binary, by the shim,
#     and by `rackup rebuild` are seen by every one of them (no shadowing).
#   - `rackup rebuild` deletes no compiled dirs.
#   - After a version bump and `make`, every path runs the new version and
#     no compiled root from rackup holds old `.zo`.
#   - A PLTCOMPILEDROOTS that an enclosing rackup launch exported does not
#     leak into the linked toolchain.
#   - With --old-rackup, the upgrade from that rackup: its config.rktd entry
#     is removed, nothing is deleted, and packages it stranded in the
#     managed addon dir are reported with a working fix.
#
# Usage:
#   test/linked-checkout-real-build.sh --work DIR [--tree DIR]
#       [--racket-ref REF] [--jobs N] [--old-rackup DIR] [--build-only]
#
# --tree defaults to DIR/plt.  When it holds no built racket, the script
# clones racket/racket at --racket-ref (default v9.0) and builds it with
# `make PKGS=""`.  A built tree embeds its own path, so a cached tree must
# be restored to the same path.  The tree is modified (packages, a version
# bump), so pass a scratch copy, not a checkout you use.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=""
TREE=""
RACKET_REF="v9.0"
JOBS="$(nproc 2>/dev/null || echo 2)"
OLD_RACKUP=""
BUILD_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work)
      WORK="$2"
      shift 2
      ;;
    --tree)
      TREE="$2"
      shift 2
      ;;
    --racket-ref)
      RACKET_REF="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --old-rackup)
      OLD_RACKUP="$2"
      shift 2
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    -h | --help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
[[ -n "$WORK" ]] || {
  echo "--work DIR is required" >&2
  exit 2
}
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
TREE="${TREE:-$WORK/plt}"

step() { printf '\n== %s\n' "$*"; }
ok() { printf 'ok: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3 (expected '$1', got '$2')"
  ok "$3"
}
assert_contains() {
  [[ "$2" == *"$1"* ]] || fail "$3 (no '$1' in: $2)"
  ok "$3"
}
assert_lacks() {
  [[ "$2" != *"$1"* ]] || fail "$3 (unexpected '$1' in: $2)"
  ok "$3"
}

make_tree() {
  (cd "$TREE" && make -j"$JOBS" CPUS="$JOBS" PKGS="")
}

# ---------------------------------------------------------------------------
# Build (or reuse) the checkout

if [[ ! -x "$TREE/racket/bin/racket" ]]; then
  step "Build Racket $RACKET_REF in place at $TREE"
  rm -rf "$TREE"
  git clone -q --depth 1 --branch "$RACKET_REF" https://github.com/racket/racket.git "$TREE"
  make_tree
fi
[[ -x "$TREE/racket/bin/racket" ]] || fail "no racket built at $TREE"
if [[ "$BUILD_ONLY" == 1 ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# A private home, rackup, and the three ways to run the checkout

export HOME="$WORK/home"
rm -rf "$HOME"
mkdir -p "$HOME"
export RACKUP_HOME="$HOME/.rackup"
unset RACKUP_TOOLCHAIN PLTCOMPILEDROOTS PLTADDONDIR PLTUSERHOME PLTCOLLECTS \
  _RACKUP_MANAGED_PLTCOMPILEDROOTS
export PATH="$RACKUP_HOME/shims:$RACKUP_HOME/bin:$PATH"
TC=lab
TID="local-$TC"
NATIVE_ADDON="$HOME/.local/share/racket"
PKGS_SRC="$WORK/pkgs"
PROJ="$WORK/project"

# The checkout's own binaries, as someone not using rackup runs them.
direct() {
  local exe="$1"
  shift
  env -u PLTCOMPILEDROOTS -u PLTADDONDIR -u _RACKUP_MANAGED_PLTCOMPILEDROOTS \
    "$TREE/racket/bin/$exe" "$@"
}
shim() {
  local exe="$1"
  shift
  "$RACKUP_HOME/shims/$exe" "$@"
}
viarun() { "$RACKUP_HOME/bin/rackup" run "$TC" -- "$@"; }
ACTORS=(direct shim viarun)

install_rackup() {
  local src="$1"
  shift
  env "$@" sh "$src/scripts/install.sh" --from-local "$src" --source --no-init -y
}

# Every .zo with its mtime, under the places a build or the shim writes.
ZO_ROOTS=("$TREE/racket/collects" "$TREE/racket/share" "$TREE/pkgs" "$PKGS_SRC" "$PROJ" "$HOME/.local")
zo_snapshot() {
  local d
  for d in "${ZO_ROOTS[@]}"; do
    if [[ -d "$d" ]]; then
      find "$d" -name '*.zo' -type f -printf '%p %T@\n'
    fi
  done | LC_ALL=C sort
}
# Every directory directly inside a `compiled/` dir (keyed roots live there).
keyed_dirs() {
  local d
  for d in "${ZO_ROOTS[@]}"; do
    if [[ -d "$d" ]]; then
      find "$d" -type d -path '*/compiled/*' -prune -print
    fi
  done | LC_ALL=C sort
}
zo_version() {
  local f="$1" n
  n="$(od -An -tu1 -j2 -N1 "$f" | tr -d ' ')"
  dd if="$f" bs=1 skip=3 count="$n" 2>/dev/null
}
# Every .zo directly in $1 names version $2.
assert_zo_versions() {
  local dir="$1" want="$2" f count=0
  while IFS= read -r f; do
    [[ "$(zo_version "$f")" == "$want" ]] || fail "$f is not version $want"
    count=$((count + 1))
  done < <(find "$dir" -maxdepth 1 -name '*.zo' -type f)
  [[ "$count" -gt 0 ]] || fail "no .zo under $dir"
  ok "all $count .zo under $dir are version $want"
}
# Compile a module the way `raco make` does (base has no `raco make`).
cm_compile() {
  local actor="$1" file="$2"
  "$actor" racket -l racket/base -l compiler/cm \
    -e "(managed-compile-zo (string->path \"$file\"))"
}

write_pkg() {
  local name="$1" k="$2"
  mkdir -p "$PKGS_SRC/$name"
  cat >"$PKGS_SRC/$name/info.rkt" <<EOF
#lang info
(define collection "$name")
(define deps '("base"))
EOF
  cat >"$PKGS_SRC/$name/main.rkt" <<EOF
#lang racket/base
(require "dep.rkt")
(provide v)
(define v (list '$name k))
EOF
  set_k "$name" "$k"
}
set_k() {
  # compiler/cm trusts a .zo whose timestamp is not older than its source,
  # with one-second resolution.  An edit in the same second as the last
  # compile would look up to date, so let the clock move on first.
  sleep 1
  printf '#lang racket/base\n(provide k)\n(define k %s)\n' "$2" >"$PKGS_SRC/$1/dep.rkt"
}
# Every actor prints `want` for (dynamic-require '<pkg>/main 'v).
check_value() {
  local pkg="$1" want="$2" what="$3" a out
  for a in "${ACTORS[@]}"; do
    out="$("$a" racket -l racket/base -e "(write (dynamic-require '$pkg/main 'v))" 2>&1)" ||
      fail "$what: $a failed: $out"
    assert_eq "$want" "$out" "$what: $a sees $want"
  done
}
# main_rkt.zo and dep_rkt.zo of a package are current: newer than their
# sources, so every actor loads them instead of compiling in memory.
check_zo_current() {
  local dir="$1" what="$2" m
  for m in main dep; do
    [[ -f "$dir/compiled/${m}_rkt.zo" ]] || fail "$what: no $dir/compiled/${m}_rkt.zo"
    [[ "$dir/compiled/${m}_rkt.zo" -nt "$dir/$m.rkt" ]] ||
      fail "$what: $dir/compiled/${m}_rkt.zo is older than its source"
  done
  ok "$what: $dir has current .zo in plain compiled/"
}

# ---------------------------------------------------------------------------
# Install rackup (optionally an older one first) and link the checkout

KEYED_BEFORE="$WORK/keyed-before"
: >"$KEYED_BEFORE"
rm -rf "$PKGS_SRC" "$PROJ"
mkdir -p "$PROJ"
printf '#lang racket/base\n(require "b.rkt")\n(displayln (list (quote project) b))\n' >"$PROJ/a.rkt"
printf '#lang racket/base\n(provide b)\n(define b 42)\n' >"$PROJ/b.rkt"
write_pkg ilib 1
write_pkg ulib 1
write_pkg slib 1

if [[ -n "$OLD_RACKUP" ]]; then
  step "Install the older rackup from $OLD_RACKUP and use it"
  install_rackup "$OLD_RACKUP" >/dev/null
  rackup link "$TC" "$TREE" --set-default >/dev/null
  # Older rackup ran `rackup run` with its managed addon dir, so this user
  # package lands in ~/.rackup/addons/local-lab.
  viarun raco pkg install -u --batch --no-docs --link "$PKGS_SRC/slib" >/dev/null
  [[ -f "$RACKUP_HOME/addons/$TID/development/pkgs/pkgs.rktd" ]] ||
    fail "older rackup did not put slib in its managed addon dir"
  (cd "$PROJ" && cm_compile shim a.rkt)
  keyed_dirs >"$KEYED_BEFORE"
  ok "older rackup set up: $(wc -l <"$KEYED_BEFORE") keyed compiled dir(s), slib in the managed addon dir"

  step "Upgrade to this rackup the way self-update does (install.sh, then reshim)"
  upgrade_err="$(install_rackup "$REPO" RACKUP_BOOTSTRAP_MODE=self-upgrade 2>&1 >/dev/null)"
  reshim_err="$(rackup reshim 2>&1 >/dev/null)"
  assert_contains "user packages are still in" "$reshim_err" "reshim reports stranded packages"
  assert_contains "slib" "$reshim_err" "reshim names slib"
  assert_contains "user packages are still in" "$upgrade_err" "the upgrade itself reports them"
  assert_eq "$(cat "$KEYED_BEFORE")" "$(keyed_dirs)" "the upgrade deleted no compiled dir"
else
  step "Install this rackup"
  install_rackup "$REPO" >/dev/null
  rackup link "$TC" "$TREE" --set-default >/dev/null
fi

step "Linked toolchain state"
env_sh="$(cat "$RACKUP_HOME/toolchains/$TID/env.sh" 2>/dev/null || true)"
assert_lacks "PLTCOMPILEDROOTS" "$env_sh" "env.sh sets no PLTCOMPILEDROOTS"
assert_contains "$NATIVE_ADDON" "$env_sh" "env.sh sets the checkout's own addon dir"
config="$(cat "$TREE/racket/etc/config.rktd" 2>/dev/null || true)"
assert_lacks "compiled-file-roots" "$config" "the checkout's config.rktd has no compiled-file-roots"

step "Every path sees the same environment"
ENVQ='(for-each (lambda (x) (printf "~s\n" x)) (list (getenv "PLTCOMPILEDROOTS") (path->string (find-system-path (quote addon-dir))) (current-compiled-file-roots)))'
want_env="$(printf '#f\n"%s/"\n(same)' "$NATIVE_ADDON")"
for a in "${ACTORS[@]}"; do
  assert_eq "$want_env" "$("$a" racket -l racket/base -e "$ENVQ")" "$a: no roots, (same), native addon dir"
done
nested="$(PLTCOMPILEDROOTS=compiled/9.0-cs:. _RACKUP_MANAGED_PLTCOMPILEDROOTS=compiled/9.0-cs:. \
  shim racket -l racket/base -e '(write (current-compiled-file-roots))')"
assert_eq "(same)" "$nested" "shim drops roots an enclosing rackup launch exported"
user_set="$(PLTCOMPILEDROOTS=compiled/mine:. shim racket -l racket/base -e '(write (getenv "PLTCOMPILEDROOTS"))')"
assert_eq '"compiled/mine:."' "$user_set" "shim keeps a PLTCOMPILEDROOTS the user set"

if [[ -n "$OLD_RACKUP" ]]; then
  step "Follow the stranded-package advice"
  viarun raco pkg install -u --batch --no-docs --link "$PKGS_SRC/slib" >/dev/null
  rm -rf "${RACKUP_HOME:?}/addons/$TID"
  assert_lacks "user packages are still in" "$(rackup reshim 2>&1 >/dev/null)" "warning gone after the fix"
  check_value slib "(slib 1)" "slib after reinstalling"
  out="$(cd "$PROJ" && shim racket a.rkt)"
  assert_eq "(project 42)" "$out" "project compiled by the older rackup still runs"
fi

V1="$(direct racket -e '(display (version))')"
for a in "${ACTORS[@]}"; do
  assert_eq "$V1" "$("$a" racket -e '(display (version))')" "$a runs version $V1"
done

step "Install packages and compile a project through the shim"
shim raco pkg install -i --batch --no-docs --link "$PKGS_SRC/ilib" >/dev/null
shim raco pkg install -u --batch --no-docs --link "$PKGS_SRC/ulib" >/dev/null
(cd "$PROJ" && cm_compile shim a.rkt)
check_zo_current "$PKGS_SRC/ilib" "ilib (installation scope)"
check_zo_current "$PKGS_SRC/ulib" "ulib (user scope)"
[[ -f "$PROJ/compiled/a_rkt.zo" ]] || fail "project not compiled into plain compiled/"
ok "project compiled into plain compiled/"
assert_eq "$(cat "$KEYED_BEFORE")" "$(keyed_dirs)" "no keyed compiled dir created"
check_value ilib "(ilib 1)" "ilib"
check_value ulib "(ulib 1)" "ulib"

step "A no-op make recompiles nothing"
before="$(zo_snapshot)"
make_tree >/dev/null
assert_eq "$before" "$(zo_snapshot)" "no .zo added or rewritten by make"
for a in "${ACTORS[@]}"; do
  "$a" racket -l racket/base -l ilib/main -l ulib/main -e '(void)'
  (cd "$PROJ" && "$a" racket a.rkt >/dev/null)
done
assert_eq "$before" "$(zo_snapshot)" "no .zo written by running every path afterwards"

step "Edits compiled by each path are seen by all (no shadowing)"
set_k ilib 2
make_tree >/dev/null
check_zo_current "$PKGS_SRC/ilib" "after make"
check_value ilib "(ilib 2)" "after make"
set_k ilib 3
cm_compile direct "$PKGS_SRC/ilib/main.rkt"
check_value ilib "(ilib 3)" "after the checkout's own binary compiled it"
set_k ilib 4
cm_compile shim "$PKGS_SRC/ilib/main.rkt"
check_value ilib "(ilib 4)" "after the shim compiled it"
set_k ilib 5
rebuild_out="$(rackup rebuild "$TC" -j "$JOBS" -- PKGS= 2>&1)" || fail "rackup rebuild failed: $rebuild_out"
assert_contains "Rebuilt $TID" "$rebuild_out" "rackup rebuild succeeds"
assert_lacks "Removed" "$rebuild_out" "rackup rebuild removes nothing"
check_value ilib "(ilib 5)" "after rackup rebuild"
assert_eq "$(cat "$KEYED_BEFORE")" "$(keyed_dirs)" "no keyed compiled dir created or deleted"

step "Version bump, then make"
hdr="$TREE/racket/src/version/racket_version.h"
w="$(sed -n 's/^#define MZSCHEME_VERSION_W \([0-9]*\)$/\1/p' "$hdr")"
sed -i "s/^#define MZSCHEME_VERSION_W $w\$/#define MZSCHEME_VERSION_W $((w + 1))/" "$hdr"
V2="$(sed -n 's/^#define MZSCHEME_VERSION_\([XYZW]\) \([0-9]*\)$/\2/p' "$hdr" | paste -sd.)"
sed -i "s/(define version \"$V1\")/(define version \"$V2\")/" "$TREE/pkgs/base/info.rkt"
grep -q "(define version \"$V2\")" "$TREE/pkgs/base/info.rkt" || fail "could not bump pkgs/base/info.rkt"
make_tree >/dev/null
for a in "${ACTORS[@]}"; do
  assert_eq "$V2" "$("$a" racket -e '(display (version))')" "$a runs version $V2"
done
assert_zo_versions "$TREE/racket/collects/racket/compiled" "$V2"
assert_zo_versions "$PKGS_SRC/ilib/compiled" "$V2"
check_value ilib "(ilib 5)" "ilib after the bump"
assert_eq "$(cat "$KEYED_BEFORE")" "$(keyed_dirs)" "no keyed compiled dir after the bump"
# The project's .zo are still from $V1.  That is Racket's stock behavior, as
# in a checkout rackup never saw: every path reports the mismatch.
for a in "${ACTORS[@]}"; do
  if out="$(cd "$PROJ" && "$a" racket a.rkt 2>&1)"; then
    fail "$a ran the project with $V1 .zo: $out"
  fi
  assert_contains "version mismatch" "$out" "$a: project .zo from $V1 is a version mismatch (stock limit)"
done
(cd "$PROJ" && cm_compile shim a.rkt)
for a in "${ACTORS[@]}"; do
  assert_eq "(project 42)" "$(cd "$PROJ" && "$a" racket a.rkt)" "$a runs the project after one recompile"
done
# ulib is user scope; whether the in-place make recompiles it decides
# whether it needs `raco setup` after a bump.  Either way every path must
# agree once it has been set up through the shim.
shim raco setup --no-docs --pkgs ulib >/dev/null
assert_zo_versions "$PKGS_SRC/ulib/compiled" "$V2"
check_value ulib "(ulib 1)" "ulib after the bump"

step "All checks passed"
