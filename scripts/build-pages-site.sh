#!/bin/sh
set -eu

OUT_DIR="${1:-_site}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC_PAGE_DIR="$ROOT_DIR/pages"
TMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rackup-pages.XXXXXX")"

cleanup() {
  rm -rf "$TMP_STAGE"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

cp "$SRC_PAGE_DIR/index.html" "$OUT_DIR/index.html"
cp "$ROOT_DIR/scripts/install.sh" "$OUT_DIR/install.sh"
cp "$ROOT_DIR/scripts/install.sh" "$OUT_DIR/install"
chmod 0755 "$OUT_DIR/install.sh" "$OUT_DIR/install"

mkdir -p "$TMP_STAGE/rackup-src"
cp -R "$ROOT_DIR/bin" "$TMP_STAGE/rackup-src/bin"
cp -R "$ROOT_DIR/libexec" "$TMP_STAGE/rackup-src/libexec"
find "$TMP_STAGE/rackup-src/libexec" -type d -name compiled -prune -exec rm -rf {} +
tar -C "$TMP_STAGE" -czf "$OUT_DIR/rackup-src.tar.gz" rackup-src

: > "$OUT_DIR/.nojekyll"

echo "Built GitHub Pages site in $OUT_DIR"
