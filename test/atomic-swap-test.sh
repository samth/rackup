#!/usr/bin/env bash
# Unit tests for the shared atomic-swap helpers in
# libexec/rackup-bootstrap.sh (rackup_atomic_replace_dir,
# rackup_atomic_replace_file, rackup_tolerant_rmrf).  These back both the
# hidden-runtime install and the prebuilt-exe self-upgrade swap.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/../libexec/rackup-bootstrap.sh"
# The bootstrap sets `set -eu`; run the harness without -e so we can assert
# on non-zero return codes (e.g. the rollback path).
set +e

failures=0
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s (expected [%s], got [%s])\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}

work="$(mktemp -d "${TMPDIR:-/tmp}/rackup-atomic-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. Replace an existing, populated directory.
mkdir -p "$work/dst" "$work/staged"
printf old >"$work/dst/marker"
printf new >"$work/staged/marker"
rackup_atomic_replace_dir "$work/dst" "$work/staged"
check "replace_dir installs new content" "new" "$(cat "$work/dst/marker" 2>/dev/null)"
check "replace_dir consumes the staged dir" "gone" "$([ -e "$work/staged" ] && echo present || echo gone)"
check "replace_dir leaves no .old backup" "" "$(find "$work" -maxdepth 1 -name 'dst.old.*' | head -1)"

# 2. Replace when the destination does not exist yet (fresh install).
mkdir -p "$work/staged2"
printf hi >"$work/staged2/f"
rackup_atomic_replace_dir "$work/dst2" "$work/staged2"
check "replace_dir into absent dst" "hi" "$(cat "$work/dst2/f" 2>/dev/null)"

# 3. Rollback: staged source missing -> swap fails, original restored.
mkdir -p "$work/dst3"
printf keep >"$work/dst3/f"
rackup_atomic_replace_dir "$work/dst3" "$work/no-such-staged" 2>/dev/null
rc=$?
check "replace_dir returns nonzero when staged missing" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
check "replace_dir rolls back original content" "keep" "$(cat "$work/dst3/f" 2>/dev/null)"
check "replace_dir cleans backup on rollback" "" "$(find "$work" -maxdepth 1 -name 'dst3.old.*' | head -1)"

# 4. Atomic file replace.
printf oldfile >"$work/target"
printf newfile >"$work/target.staged"
rackup_atomic_replace_file "$work/target" "$work/target.staged"
check "replace_file installs new content" "newfile" "$(cat "$work/target" 2>/dev/null)"
check "replace_file consumes the staged file" "gone" "$([ -e "$work/target.staged" ] && echo present || echo gone)"

# 5. tolerant_rmrf removes a normal dir and never fails on a missing path.
mkdir -p "$work/killme"
rackup_tolerant_rmrf "$work/killme"
check "tolerant_rmrf removes a directory" "gone" "$([ -e "$work/killme" ] && echo present || echo gone)"
rackup_tolerant_rmrf "$work/does-not-exist"
check "tolerant_rmrf tolerates a missing path" "0" "$?"

if [ "$failures" -eq 0 ]; then
  echo "All atomic-swap helper tests passed."
  exit 0
fi
echo "$failures atomic-swap helper test(s) failed." >&2
exit 1
