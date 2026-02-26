#!/usr/bin/env bash
set -euo pipefail

PREFIX="${RACKUP_HOME:-$HOME/.rackup}"
REPO="${RACKUP_GITHUB_REPO:-samth/rackup}"
REF="${RACKUP_REF:-main}"
YES=0
INIT_SHELL=""
FROM_LOCAL=""

usage() {
  cat <<'USAGE'
rackup bootstrap installer

Usage:
  install.sh [-y] [--prefix DIR] [--repo owner/name] [--ref REF] [--shell bash|zsh] [--from-local PATH]

Behavior:
  - Prompts before editing shell config by default.
  - With -y, accepts defaults (including shell init).
  - Installs files under ~/.rackup unless --prefix or RACKUP_HOME is set.

Examples:
  curl -fsSL https://raw.githubusercontent.com/samth/rackup/main/scripts/install.sh | bash
  curl -fsSL .../install.sh | bash -s -- -y
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      YES=1
      shift
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --ref)
      REF="$2"
      shift 2
      ;;
    --shell)
      INIT_SHELL="$2"
      shift 2
      ;;
    --from-local)
      FROM_LOCAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v racket >/dev/null 2>&1; then
  echo "Error: 'racket' is required to run rackup." >&2
  exit 1
fi

TMPDIR_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/rackup-install.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_INSTALL"
}
trap cleanup EXIT

SRC_DIR=""

if [[ -n "$FROM_LOCAL" ]]; then
  SRC_DIR="$FROM_LOCAL"
else
  ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
  echo "Downloading rackup sources from ${ARCHIVE_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ARCHIVE_URL" -o "$TMPDIR_INSTALL/rackup.tar.gz"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMPDIR_INSTALL/rackup.tar.gz" "$ARCHIVE_URL"
  else
    echo "Error: need curl or wget to download rackup sources." >&2
    exit 1
  fi
  mkdir -p "$TMPDIR_INSTALL/src"
  tar -xzf "$TMPDIR_INSTALL/rackup.tar.gz" -C "$TMPDIR_INSTALL/src"
  SRC_DIR="$(find "$TMPDIR_INSTALL/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
  echo "Error: failed to locate source directory." >&2
  exit 1
fi

mkdir -p "$PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/libexec"

echo "Installing rackup into $PREFIX"
cp -R "$SRC_DIR/bin/." "$PREFIX/bin/"
cp -R "$SRC_DIR/libexec/." "$PREFIX/libexec/"
chmod +x "$PREFIX/bin/rackup"

echo "Installed: $PREFIX/bin/rackup"

default_shell="$(basename "${SHELL:-bash}")"
if [[ -n "$INIT_SHELL" ]]; then
  shell_to_init="$INIT_SHELL"
elif [[ "$default_shell" == "zsh" ]]; then
  shell_to_init="zsh"
else
  shell_to_init="bash"
fi

do_init=0
if [[ "$YES" -eq 1 ]]; then
  do_init=1
else
  printf "Initialize %s shell config now? [Y/n] " "$shell_to_init"
  read -r answer || true
  case "${answer:-Y}" in
    y|Y|yes|YES|"")
      do_init=1
      ;;
    *)
      do_init=0
      ;;
  esac
fi

if [[ "$do_init" -eq 1 ]]; then
  echo "Running rackup init --shell $shell_to_init"
  RACKUP_HOME="$PREFIX" "$PREFIX/bin/rackup" init --shell "$shell_to_init"
else
  echo "Skipping shell init."
fi

cat <<EOF

rackup installed successfully.

Next steps:
  1. Ensure \${RACKUP_HOME:-$PREFIX}/shims is on PATH (or run 'rackup init').
  2. Install a toolchain:
       $PREFIX/bin/rackup install stable --set-default
EOF
