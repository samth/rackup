#!/bin/sh
set -eu

PREFIX="${RACKUP_HOME:-$HOME/.rackup}"
REPO="${RACKUP_GITHUB_REPO:-samth/rackup}"
REF="${RACKUP_REF:-main}"
ARCHIVE_URL_OVERRIDE="${RACKUP_ARCHIVE_URL:-}"
YES=0
INIT_SHELL=""
FROM_LOCAL=""
NO_INIT=0
do_init=0
BOOTSTRAP_MODE="${RACKUP_BOOTSTRAP_MODE:-install}"

is_tty_stdout() {
  [ -t 1 ]
}

supports_color() {
  [ -z "${NO_COLOR:-}" ] && is_tty_stdout
}

if supports_color; then
  C_RESET="$(printf '\033[0m')"
  C_BOLD="$(printf '\033[1m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

info() {
  printf '%s\n' "${C_BLUE}$*${C_RESET}"
}

warn() {
  printf '%s\n' "${C_YELLOW}$*${C_RESET}" >&2
}

ok() {
  printf '%s\n' "${C_GREEN}$*${C_RESET}"
}

usage() {
  cat <<'USAGE'
rackup bootstrap installer

Usage:
  install.sh [-y] [--no-init] [--prefix DIR] [--repo owner/name] [--ref REF] [--archive-url URL] [--shell bash|zsh] [--from-local PATH]

Behavior:
  - Prompts before editing shell config by default.
  - With -y, accepts defaults (including shell init).
  - With --no-init, skips shell init changes even with -y.
  - Installs files under ~/.rackup unless --prefix or RACKUP_HOME is set.
  - Installs a hidden internal Racket runtime for rackup itself.
  - For the default samth/rackup bootstrap, downloads a public source bundle from GitHub Pages.
  - Internal: set RACKUP_BOOTSTRAP_MODE=self-upgrade for upgrade-oriented completion messaging.

Examples:
  curl -fsSL https://samth.github.io/rackup/install.sh | sh
  curl -fsSL .../install.sh | sh -s -- -y
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      YES=1
      shift
      ;;
    --no-init)
      NO_INIT=1
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
    --archive-url)
      ARCHIVE_URL_OVERRIDE="$2"
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

case "$BOOTSTRAP_MODE" in
  install|self-upgrade) ;;
  *)
    warn "Invalid RACKUP_BOOTSTRAP_MODE: $BOOTSTRAP_MODE (expected install or self-upgrade)"
    exit 2
    ;;
esac

TMPDIR_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/rackup-install.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_INSTALL"
}
trap cleanup EXIT

SRC_DIR=""

if [ -n "$FROM_LOCAL" ]; then
  SRC_DIR="$FROM_LOCAL"
else
  if [ -n "$ARCHIVE_URL_OVERRIDE" ]; then
    ARCHIVE_URL="$ARCHIVE_URL_OVERRIDE"
  elif [ "$REPO" = "samth/rackup" ] && [ "$REF" = "main" ]; then
    ARCHIVE_URL="https://samth.github.io/rackup/rackup-src.tar.gz"
  else
    ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"
  fi
  info "Downloading rackup sources from ${ARCHIVE_URL}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ARCHIVE_URL" -o "$TMPDIR_INSTALL/rackup.tar.gz"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMPDIR_INSTALL/rackup.tar.gz" "$ARCHIVE_URL"
  else
    warn "Error: need curl or wget to download rackup sources."
    exit 1
  fi
  mkdir -p "$TMPDIR_INSTALL/src"
  # Use -m so future mtimes in the archive do not produce noisy warnings on skewed clocks.
  tar -xzmf "$TMPDIR_INSTALL/rackup.tar.gz" -C "$TMPDIR_INSTALL/src"
  SRC_DIR="$(find "$TMPDIR_INSTALL/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
fi

if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
  warn "Error: failed to locate source directory."
  exit 1
fi

mkdir -p "$PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/libexec"

info "Installing rackup into $PREFIX"
cp -R "$SRC_DIR/bin/." "$PREFIX/bin/"
cp -R "$SRC_DIR/libexec/." "$PREFIX/libexec/"
chmod +x "$PREFIX/bin/rackup"
chmod +x "$PREFIX/libexec/rackup-bootstrap.sh" 2>/dev/null || true

ok "Installed: $PREFIX/bin/rackup"

if [ ! -r "$PREFIX/libexec/rackup-bootstrap.sh" ]; then
  warn "Error: missing bootstrap helper after install."
  exit 1
fi

RACKUP_HOME="$PREFIX"
export RACKUP_HOME
. "$PREFIX/libexec/rackup-bootstrap.sh"

info "Ensuring hidden runtime is installed..."
rackup_hidden_runtime_install_if_missing

info "Registering/validating hidden runtime..."
"$PREFIX/bin/rackup" runtime install >/dev/null

default_shell="$(basename "${SHELL:-bash}")"
if [ -n "$INIT_SHELL" ]; then
  shell_to_init="$INIT_SHELL"
elif [ "$default_shell" = "zsh" ]; then
  shell_to_init="zsh"
else
  shell_to_init="bash"
fi

if [ "$NO_INIT" -eq 1 ]; then
  do_init=0
elif [ "$YES" -eq 1 ]; then
  do_init=1
else
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "Initialize %s shell config now? [Y/n] " "$shell_to_init" > /dev/tty
    answer=""
    read -r answer < /dev/tty || true
    case "${answer:-Y}" in
      y|Y|yes|YES|"")
        do_init=1
        ;;
      *)
        do_init=0
        ;;
    esac
  else
    warn "No interactive TTY detected; skipping shell init (rerun with -y to accept defaults)."
    do_init=0
  fi
fi

if [ "$do_init" -eq 1 ]; then
  info "Running rackup init --shell $shell_to_init"
  RACKUP_HOME="$PREFIX" "$PREFIX/bin/rackup" init --shell "$shell_to_init"
else
  if [ "$BOOTSTRAP_MODE" != "self-upgrade" ]; then
    info "Skipping shell init."
  fi
fi
printf '\n'
if [ "$BOOTSTRAP_MODE" = "self-upgrade" ]; then
  if [ "$do_init" -eq 1 ]; then
    info "Shell init updated for $shell_to_init."
  fi
  exit 0
fi
ok "${C_BOLD}rackup installed successfully.${C_RESET}"
printf '\n'
printf '%s\n' "${C_BOLD}Next steps:${C_RESET}"
if [ "$do_init" -eq 1 ]; then
  if [ "$shell_to_init" = "zsh" ]; then
    rc_file="$HOME/.zshrc"
  else
    rc_file="$HOME/.bashrc"
  fi
  cat <<EOF
  1. Start a new shell (or run: . $rc_file) so rackup shims are added to PATH.
  2. Install your first toolchain (the first install becomes the default automatically):
       $PREFIX/bin/rackup install stable
EOF
else
  cat <<EOF
  1. Add \${RACKUP_HOME:-$PREFIX}/shims to PATH (or run '$PREFIX/bin/rackup init').
  2. Install your first toolchain (the first install becomes the default automatically):
       $PREFIX/bin/rackup install stable
EOF
fi
