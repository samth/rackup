#!/bin/sh
set -eu

OUT_DIR="${1:-_site}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC_PAGE_DIR="$ROOT_DIR/pages"

mkdir -p "$OUT_DIR"

cp "$SRC_PAGE_DIR/index.html" "$OUT_DIR/index.html"
cp "$ROOT_DIR/scripts/install.sh" "$OUT_DIR/install.sh"
cp "$ROOT_DIR/scripts/install.sh" "$OUT_DIR/install"
chmod 0755 "$OUT_DIR/install.sh" "$OUT_DIR/install"
: > "$OUT_DIR/.nojekyll"

echo "Built GitHub Pages site in $OUT_DIR"
