#!/usr/bin/env bash
set -euo pipefail

ENTRY="${RACKUP_QEMU_I386_BINFMT_ENTRY:-}"
REGISTER="${RACKUP_BINFMT_REGISTER:-/proc/sys/fs/binfmt_misc/register}"
BINFMT_DIR="${RACKUP_BINFMT_MISC_DIR:-/proc/sys/fs/binfmt_misc}"

usage() {
  cat <<'EOF'
Run a command with qemu-i386 binfmt_misc temporarily disabled, then restore it.

Usage:
  scripts/with-qemu-i386-binfmt-disabled.sh <command> [args...]
EOF
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

find_qemu_i386_entry() {
  local candidate
  if [[ -n "$ENTRY" ]]; then
    [[ -r "$ENTRY" ]] && printf '%s\n' "$ENTRY"
    return 0
  fi
  if [[ ! -d "$BINFMT_DIR" ]]; then
    return 0
  fi
  for candidate in "$BINFMT_DIR"/*; do
    [[ -r "$candidate" ]] || continue
    [[ -f "$candidate" ]] || continue
    if grep -Fq "interpreter /usr/bin/qemu-i386" "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 0
}

ENTRY="$(find_qemu_i386_entry)"
if [[ -z "$ENTRY" ]]; then
  printf 'qemu-i386 binfmt entry not present; running command directly.\n' >&2
  exec "$@"
fi

name="$(basename "$ENTRY")"
interpreter="$(awk '/^interpreter / { print $2 }' "$ENTRY")"
flags="$(awk '/^flags: / { print $2 }' "$ENTRY")"
offset="$(awk '/^offset / { print $2 }' "$ENTRY")"
magic_hex="$(awk '/^magic / { print $2 }' "$ENTRY")"
mask_hex="$(awk '/^mask / { print $2 }' "$ENTRY")"

if [[ -z "$interpreter" || -z "$flags" || -z "$offset" || -z "$magic_hex" || -z "$mask_hex" ]]; then
  printf 'Could not parse qemu-i386 binfmt entry: %s\n' "$ENTRY" >&2
  exit 2
fi

magic_esc="$(printf '%s' "$magic_hex" | sed 's/../\\x&/g')"
mask_esc="$(printf '%s' "$mask_hex" | sed 's/../\\x&/g')"
did_disable=0

restore_binfmt() {
  if [[ "$did_disable" -ne 1 ]]; then
    return 0
  fi
  sudo /bin/sh -eu -c '
    entry="$1"
    register="$2"
    payload="$3"
    if [ -e "$entry" ]; then
      printf "%s" -1 > "$entry" || true
    fi
    printf "%b" "$payload" > "$register"
  ' sh "$ENTRY" "$REGISTER" ":${name}:M:${offset}:${magic_esc}:${mask_esc}:${interpreter}:${flags}"
}

trap restore_binfmt EXIT

sudo /bin/sh -eu -c 'printf "%s" -1 > "$1"' sh "$ENTRY"
did_disable=1
"$@"
