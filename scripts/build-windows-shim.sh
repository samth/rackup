#!/bin/sh
set -eu

# Cross-compile rackup's Windows shim dispatcher
# (libexec/rackup/windows/rackup-shim.c) from Linux.
#
#   scripts/build-windows-shim.sh x86_64 out/rackup-shim-x86_64-win32.exe
#   scripts/build-windows-shim.sh aarch64 out/rackup-shim-aarch64-win32.exe
#
# The shim uses no C runtime, only kernel32, so it is about 12 KB.
#   x86_64:  mingw-w64 gcc (apt: gcc-mingw-w64-x86-64)
#   aarch64: clang, lld and llvm-dlltool (apt: clang lld llvm), with the
#            mingw-w64 headers (apt: mingw-w64-common).  mingw-w64 ships
#            no ARM64 import libraries, so kernel32's is generated from
#            the functions the shim actually calls.

if [ "$#" -ne 2 ]; then
  echo "usage: $0 x86_64|aarch64 OUTPUT.exe" >&2
  exit 2
fi
ARCH="$1"
OUTPUT="$2"

# shellcheck disable=SC1007
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$ROOT_DIR/libexec/rackup/windows/rackup-shim.c"

case "$ARCH" in
  x86_64)
    x86_64-w64-mingw32-gcc -Os -s -nostdlib -fno-builtin -e shim_entry \
      -o "$OUTPUT" "$SRC" -lkernel32
    ;;
  aarch64)
    MINGW_INCLUDE="${MINGW_INCLUDE:-/usr/share/mingw-w64/include}"
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/rackup-shim.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT
    TARGET=aarch64-w64-windows-gnu
    clang --target="$TARGET" -isystem "$MINGW_INCLUDE" -Os -ffreestanding -fno-builtin \
      -c "$SRC" -o "$TMP/shim.o"
    {
      echo "LIBRARY KERNEL32.dll"
      echo "EXPORTS"
      llvm-nm "$TMP/shim.o" | awk '$1 == "U" && $2 ~ /^__imp_/ { sub(/^__imp_/, "", $2); print "  " $2 }'
    } >"$TMP/kernel32.def"
    llvm-dlltool -m arm64 -d "$TMP/kernel32.def" -l "$TMP/libkernel32.a"
    clang --target="$TARGET" -fuse-ld=lld -nostdlib -s \
      -Wl,-e,shim_entry -Wl,--subsystem,console \
      "$TMP/shim.o" "$TMP/libkernel32.a" -o "$OUTPUT"
    ;;
  *)
    echo "unsupported arch: $ARCH (expected x86_64 or aarch64)" >&2
    exit 2
    ;;
esac
