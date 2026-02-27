#!/bin/sh
set -eu

OUT_DIR="${1:-_site}"
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rackup-pages.XXXXXX")"
PLT_WEB_STAGE="$TMP_STAGE/plt-web-out"

cleanup() {
  rm -rf "$TMP_STAGE"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

mkdir -p "$PLT_WEB_STAGE"
racket "$ROOT_DIR/pages/site.rkt" -r -o "$PLT_WEB_STAGE" -f
cp -R "$PLT_WEB_STAGE/www/." "$OUT_DIR/"
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
