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

if command -v sha256sum >/dev/null 2>&1; then
  sha256_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  sha256_cmd="shasum -a 256"
else
  echo "Error: no sha256sum or shasum found; cannot build site without a hash tool" >&2
  exit 1
fi

# Build tarball and install.sh first so we can hash install.sh before generating HTML.
mkdir -p "$TMP_STAGE/rackup-src"
"$ROOT_DIR/scripts/copy-filtered-tree.sh" "$ROOT_DIR" "$TMP_STAGE/rackup-src" \
  bin \
  libexec \
  scripts/copy-filtered-tree.sh
tar -C "$TMP_STAGE" -czf "$OUT_DIR/rackup-src.tar.gz" rackup-src

SRC_SHA256="$($sha256_cmd "$OUT_DIR/rackup-src.tar.gz" | cut -d ' ' -f 1)"
sed "s/@@RACKUP_SRC_SHA256@@/$SRC_SHA256/g" "$ROOT_DIR/scripts/install.sh" > "$OUT_DIR/install.sh"
cp "$OUT_DIR/install.sh" "$OUT_DIR/install"
chmod 0755 "$OUT_DIR/install.sh" "$OUT_DIR/install"

INSTALL_SHA256="$($sha256_cmd "$OUT_DIR/install.sh" | cut -d ' ' -f 1)"

# Generate HTML with the install.sh hash available to the Racket code.
mkdir -p "$PLT_WEB_STAGE"
RACKUP_INSTALL_SH_SHA256="$INSTALL_SHA256" racket "$ROOT_DIR/pages/site.rkt" -r -o "$PLT_WEB_STAGE" -f
cp -R "$PLT_WEB_STAGE/www/." "$OUT_DIR/"

: > "$OUT_DIR/.nojekyll"

echo "Built GitHub Pages site in $OUT_DIR"
