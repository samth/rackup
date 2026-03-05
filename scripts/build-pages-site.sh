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
mkdir -p "$TMP_STAGE/rackup-src"
"$ROOT_DIR/scripts/copy-filtered-tree.sh" "$ROOT_DIR" "$TMP_STAGE/rackup-src" \
  bin \
  libexec \
  scripts/copy-filtered-tree.sh
tar -C "$TMP_STAGE" -czf "$OUT_DIR/rackup-src.tar.gz" rackup-src

if command -v sha256sum >/dev/null 2>&1; then
  SRC_SHA256="$(sha256sum "$OUT_DIR/rackup-src.tar.gz" | cut -d ' ' -f 1)"
elif command -v shasum >/dev/null 2>&1; then
  SRC_SHA256="$(shasum -a 256 "$OUT_DIR/rackup-src.tar.gz" | cut -d ' ' -f 1)"
else
  echo "Warning: no sha256sum or shasum found; install.sh will skip checksum verification" >&2
  SRC_SHA256="@@RACKUP_SRC_SHA256@@"
fi

sed "s/@@RACKUP_SRC_SHA256@@/$SRC_SHA256/g" "$ROOT_DIR/scripts/install.sh" > "$OUT_DIR/install.sh"
cp "$OUT_DIR/install.sh" "$OUT_DIR/install"
chmod 0755 "$OUT_DIR/install.sh" "$OUT_DIR/install"

: > "$OUT_DIR/.nojekyll"

echo "Built GitHub Pages site in $OUT_DIR"
