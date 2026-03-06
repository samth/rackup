#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: copy-filtered-tree.sh SRC_DIR DEST_DIR [PATH ...]

Copies files from SRC_DIR into DEST_DIR while excluding:
  - .git directories
  - .dep files
  - .zo files (except rackup-core_rkt_merged.zo)

If PATH arguments are provided, they are interpreted relative to SRC_DIR.
EOF
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

SRC_DIR="$1"
DEST_DIR="$2"
shift 2

if [ ! -d "$SRC_DIR" ]; then
  echo "copy-filtered-tree.sh: source directory not found: $SRC_DIR" >&2
  exit 1
fi

if [ "$#" -eq 0 ]; then
  set -- .
fi

mkdir -p "$DEST_DIR"

(
  cd "$SRC_DIR"
  find "$@" \
    \( -type d -name .git -prune \) -o \
    \( -type f \( -name '*.zo' -o -name '*.dep' \) ! -name 'rackup-core_rkt_merged.zo' -prune \) -o \
    \( -type f -o -type l \) -print0
) | tar -C "$SRC_DIR" --null -T - -cf - | tar -C "$DEST_DIR" -xf -
