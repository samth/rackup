#!/bin/sh
set -eu

PREFIX="${RACKUP_HOME:-$HOME/.rackup}"
REPO="${RACKUP_GITHUB_REPO:-samth/rackup}"
REF="${RACKUP_REF:-main}"
ARCHIVE_URL_OVERRIDE="${RACKUP_ARCHIVE_URL:-}"
YES=0
INIT_SHELL=""
FROM_LOCAL="${RACKUP_FROM_LOCAL:-}"
NO_INIT=0
do_init=0
BOOTSTRAP_MODE="${RACKUP_BOOTSTRAP_MODE:-install}"
EXPECTED_SRC_SHA256="@@RACKUP_SRC_SHA256@@"
FORCE_SOURCE="${RACKUP_FORCE_SOURCE:-0}"
FORCE_EXE="${RACKUP_FORCE_EXE:-0}"

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
  install.sh [-y] [--no-init] [--prefix DIR] [--repo owner/name] [--ref REF] [--archive-url URL] [--shell bash|zsh] [--from-local PATH] [--source | --exe]

Behavior:
  - Prompts before editing shell config by default.
  - With -y, accepts defaults (including shell init).
  - With --no-init, skips shell init changes even with -y.
  - Installs files under ~/.rackup unless --prefix or RACKUP_HOME is set.
  - By default, tries to download a prebuilt binary for the current platform.
  - Falls back to source distribution + hidden runtime if no binary is available.
  - Use --source to skip the prebuilt binary and install from source directly.
  - Use --exe to require a prebuilt binary (error if unavailable for this platform).
  - Internal: set RACKUP_BOOTSTRAP_MODE=self-upgrade for upgrade-oriented completion messaging.

Examples:
  curl -fsSL https://samth.github.io/rackup/install.sh | sh
  curl -fsSL .../install.sh | sh -s -- -y
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y | --yes)
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
    --source)
      FORCE_SOURCE=1
      shift
      ;;
    --exe)
      FORCE_EXE=1
      shift
      ;;
    -h | --help)
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
  install | self-upgrade) ;;
  *)
    warn "Invalid RACKUP_BOOTSTRAP_MODE: $BOOTSTRAP_MODE (expected install or self-upgrade)"
    exit 2
    ;;
esac

if [ "$FORCE_SOURCE" -eq 1 ] && [ "$FORCE_EXE" -eq 1 ]; then
  warn "Error: --source and --exe are mutually exclusive."
  exit 2
fi

if [ "$FORCE_EXE" -eq 1 ] && [ -n "$FROM_LOCAL" ]; then
  warn "Error: --exe and --from-local are mutually exclusive."
  exit 2
fi

# --- Early up-to-date check for self-upgrade ---
# On self-upgrade from the default repo, download just the tiny checksum
# file and compare to the stored hash.  Skip the full install if they match.
if [ "$BOOTSTRAP_MODE" = "self-upgrade" ] && [ -z "$FROM_LOCAL" ] &&
  [ -z "$ARCHIVE_URL_OVERRIDE" ] && [ "$REPO" = "samth/rackup" ] &&
  [ "$REF" = "main" ]; then
  _upgrade_base_url="https://samth.github.io/rackup"
  _installed_sha_file="$PREFIX/.installed-sha256"
  if [ "$FORCE_SOURCE" -eq 1 ]; then
    _remote_sha_url="$_upgrade_base_url/rackup-src.tar.gz.sha256"
  elif [ "$FORCE_EXE" -eq 1 ]; then
    _host_arch="$(detect_arch)"
    _host_platform="$(detect_platform)"
    _remote_sha_url="$_upgrade_base_url/rackup-${_host_arch}-${_host_platform}.tar.gz.sha256"
  else
    # Auto mode: check the exe checksum if a prebuilt is available, source otherwise.
    _host_arch="$(detect_arch)"
    _host_platform="$(detect_platform)"
    if has_prebuilt_binary "${_host_arch}-${_host_platform}"; then
      _remote_sha_url="$_upgrade_base_url/rackup-${_host_arch}-${_host_platform}.tar.gz.sha256"
    else
      _remote_sha_url="$_upgrade_base_url/rackup-src.tar.gz.sha256"
    fi
  fi
  if [ -f "$_installed_sha_file" ]; then
    _installed_sha="$(cat "$_installed_sha_file")"
    _remote_sha=""
    if command -v curl >/dev/null 2>&1; then
      _remote_sha_content="$(curl -fsSL "$_remote_sha_url" 2>/dev/null)" || true
    elif command -v wget >/dev/null 2>&1; then
      _remote_sha_content="$(wget -qO- "$_remote_sha_url" 2>/dev/null)" || true
    else
      _remote_sha_content=""
    fi
    if [ -n "$_remote_sha_content" ]; then
      _remote_sha="$(echo "$_remote_sha_content" | cut -d ' ' -f 1)"
    fi
    if [ -n "$_remote_sha" ] && [ "$_installed_sha" = "$_remote_sha" ]; then
      ok "Already up to date."
      exit 0
    fi
  fi
fi

TMPDIR_INSTALL="$(mktemp -d "${TMPDIR:-/tmp}/rackup-install.XXXXXX")"
cleanup() {
  rm -rf "$TMPDIR_INSTALL"
}
trap cleanup EXIT

# --- Detect host arch/platform for prebuilt binary selection ---
detect_arch() {
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$m" in
    x86_64 | amd64) echo "x86_64" ;;
    aarch64 | arm64) echo "aarch64" ;;
    i386 | i686 | x86) echo "i386" ;;
    armv7* | armv6* | arm) echo "arm" ;;
    *) echo "$m" ;;
  esac
}

detect_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "macosx" ;;
    Linux) echo "linux" ;;
    *) echo "unknown" ;;
  esac
}

download_file() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" 2>/dev/null
  else
    return 1
  fi
}

# Compute SHA-256 of a file, printing the hex digest to stdout.
# Returns 1 if no hash tool is available.
compute_sha256() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | cut -d ' ' -f 1
  else
    return 1
  fi
}

# Verify SHA-256 of a file against an expected digest.
# $1 = file path, $2 = expected hex digest, $3 = label for error messages
# Exits on mismatch; prompts on missing hash tool.
verify_sha256() {
  file="$1"
  expected="$2"
  label="$3"
  actual=""
  if actual="$(compute_sha256 "$file")"; then
    : # ok
  else
    warn "Warning: neither sha256sum nor shasum found; cannot verify download."
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      printf "Continue without checksum verification? [y/N] " >/dev/tty
      answer=""
      read -r answer </dev/tty || true
      case "$answer" in
        y | Y | yes | YES) ;;
        *) exit 1 ;;
      esac
    else
      warn "Error: no hash tool available and no TTY to prompt; aborting."
      warn "Install sha256sum or shasum and try again."
      exit 1
    fi
    return 0
  fi
  if [ "$actual" != "$expected" ]; then
    warn "Error: SHA-256 checksum mismatch for $label"
    warn "  expected: $expected"
    warn "  actual:   $actual"
    exit 1
  fi
  ok "Checksum OK ($label)."
}

# Targets for which prebuilt binaries are published.
# This list must match the build-exe matrix in .github/workflows/build-exe.yml.
has_prebuilt_binary() {
  target="$1"
  case "$target" in
    x86_64-linux | aarch64-linux | x86_64-macosx | aarch64-macosx | \
      i386-linux)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Try prebuilt binary before falling back to source ---
INSTALLED_PREBUILT=0

if [ -z "$FROM_LOCAL" ] && [ "$FORCE_SOURCE" -eq 0 ]; then
  HOST_ARCH="$(detect_arch)"
  HOST_PLATFORM="$(detect_platform)"
  HOST_TARGET="${HOST_ARCH}-${HOST_PLATFORM}"
  BINARY_NAME="rackup-${HOST_TARGET}.tar.gz"

  if [ -n "$ARCHIVE_URL_OVERRIDE" ]; then
    BINARY_BASE_URL=""
  elif [ "$REPO" = "samth/rackup" ] && [ "$REF" = "main" ]; then
    BINARY_BASE_URL="https://samth.github.io/rackup"
  else
    BINARY_BASE_URL=""
  fi

  # With --exe, the binary must be available; otherwise we try and fall back.
  if [ "$FORCE_EXE" -eq 1 ] && [ -z "$BINARY_BASE_URL" ]; then
    warn "Error: --exe requires the default repo (samth/rackup, main branch)."
    warn "Custom --repo, --ref, or --archive-url installs do not publish prebuilt binaries."
    exit 1
  fi
  if [ "$FORCE_EXE" -eq 1 ] && ! has_prebuilt_binary "$HOST_TARGET"; then
    warn "Error: no prebuilt binary is published for $HOST_TARGET."
    warn "Available targets: x86_64-linux, aarch64-linux, x86_64-macosx, aarch64-macosx, i386-linux"
    exit 1
  fi

  if [ -n "$BINARY_BASE_URL" ] && has_prebuilt_binary "$HOST_TARGET"; then
    BINARY_URL="$BINARY_BASE_URL/$BINARY_NAME"
    CHECKSUM_URL="${BINARY_URL}.sha256"
    info "Downloading prebuilt binary for $HOST_TARGET..."
    if download_file "$BINARY_URL" "$TMPDIR_INSTALL/rackup-binary.tar.gz"; then
      info "Downloaded prebuilt binary."
      # Verify SHA-256 checksum of the binary tarball.
      if download_file "$CHECKSUM_URL" "$TMPDIR_INSTALL/rackup-binary.tar.gz.sha256"; then
        expected_bin_sha256="$(cut -d ' ' -f 1 <"$TMPDIR_INSTALL/rackup-binary.tar.gz.sha256")"
        info "Verifying binary checksum..."
        verify_sha256 "$TMPDIR_INSTALL/rackup-binary.tar.gz" "$expected_bin_sha256" "$BINARY_NAME"
      else
        if [ "$FORCE_EXE" -eq 1 ]; then
          warn "Error: could not download checksum file for $BINARY_NAME."
          warn "Cannot verify binary integrity; aborting (--exe requires verified download)."
          exit 1
        fi
        warn "Warning: could not download checksum file for $BINARY_NAME."
        warn "Cannot verify binary integrity.  Falling back to source install."
        rm -f "$TMPDIR_INSTALL/rackup-binary.tar.gz"
      fi
      if [ -f "$TMPDIR_INSTALL/rackup-binary.tar.gz" ]; then
        mkdir -p "$TMPDIR_INSTALL/binary"
        tar -xzmf "$TMPDIR_INSTALL/rackup-binary.tar.gz" -C "$TMPDIR_INSTALL/binary"
        BINARY_DIR="$(find "$TMPDIR_INSTALL/binary" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        if [ -n "$BINARY_DIR" ] && [ -x "$BINARY_DIR/bin/rackup-core" ]; then
          mkdir -p "$PREFIX"
          mkdir -p "$PREFIX/bin" "$PREFIX/libexec"
          # Install the prebuilt binary distribution
          cp "$BINARY_DIR/bin/rackup" "$PREFIX/bin/rackup"
          cp "$BINARY_DIR/bin/rackup-core" "$PREFIX/bin/rackup-core"
          chmod +x "$PREFIX/bin/rackup" "$PREFIX/bin/rackup-core"
          if [ -d "$BINARY_DIR/lib" ]; then
            rm -rf "${PREFIX:?}/lib"
            cp -R "$BINARY_DIR/lib" "$PREFIX/lib"
          fi
          cp "$BINARY_DIR/libexec/rackup-bootstrap.sh" "$PREFIX/libexec/rackup-bootstrap.sh"
          chmod +x "$PREFIX/libexec/rackup-bootstrap.sh"
          ok "Installed prebuilt binary: $PREFIX/bin/rackup"
          # Store the checksum so self-upgrade can detect no-ops.
          if [ -n "${expected_bin_sha256:-}" ]; then
            printf '%s\n' "$expected_bin_sha256" >"$PREFIX/.installed-sha256"
          fi
          INSTALLED_PREBUILT=1
        else
          if [ "$FORCE_EXE" -eq 1 ]; then
            warn "Error: prebuilt binary archive was invalid."
            exit 1
          fi
          warn "Prebuilt binary archive was invalid; falling back to source install."
        fi
      fi
    else
      if [ "$FORCE_EXE" -eq 1 ]; then
        warn "Error: failed to download prebuilt binary for $HOST_TARGET."
        exit 1
      fi
      warn "Failed to download prebuilt binary; falling back to source install."
    fi
  elif [ -n "$BINARY_BASE_URL" ]; then
    info "No prebuilt binary published for $HOST_TARGET; falling back to source install."
  fi
fi

if [ "$INSTALLED_PREBUILT" -eq 0 ]; then
  # --- Source-based installation fallback ---

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
    if [ "$EXPECTED_SRC_SHA256" != "@@RACKUP_SRC_SHA256@@" ]; then
      info "Verifying source download (SHA-256)..."
      verify_sha256 "$TMPDIR_INSTALL/rackup.tar.gz" "$EXPECTED_SRC_SHA256" "rackup-src.tar.gz"
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
  copy_filtered_tree() {
    src_dir="$1"
    dest_dir="$2"
    shift 2
    mkdir -p "$dest_dir"
    (
      cd "$src_dir"
      find "$@" \
        \( -type d \( -name .git -o -name compiled \) -prune \) -o \
        \( -type f \( -name '*.zo' -o -name '*.dep' \) -prune \) -o \
        \( -type f -o -type l \) -print0
    ) | tar -C "$src_dir" --null -T - -cf - | tar -C "$dest_dir" -xf -
  }

  copy_filtered_tree "$SRC_DIR" "$PREFIX" bin libexec
  chmod +x "$PREFIX/bin/rackup"
  chmod +x "$PREFIX/libexec/rackup-bootstrap.sh" 2>/dev/null || true

  # Remove any stale prebuilt binary from a prior exe install so the
  # shell wrapper does not pick up an outdated rackup-core executable.
  if [ -f "$PREFIX/bin/rackup-core" ]; then
    rm -f "$PREFIX/bin/rackup-core"
  fi
  # Also remove stale lib/ from a prior raco distribute output.
  if [ -d "$PREFIX/lib/plt" ]; then
    rm -rf "${PREFIX:?}/lib"
  fi

  ok "Installed: $PREFIX/bin/rackup"
  # Store the checksum so self-upgrade can detect no-ops.
  if [ "$EXPECTED_SRC_SHA256" != "@@RACKUP_SRC_SHA256@@" ]; then
    printf '%s\n' "$EXPECTED_SRC_SHA256" >"$PREFIX/.installed-sha256"
  elif [ -f "$TMPDIR_INSTALL/rackup.tar.gz" ]; then
    _src_sha="$(compute_sha256 "$TMPDIR_INSTALL/rackup.tar.gz")" || true
    if [ -n "${_src_sha:-}" ]; then
      printf '%s\n' "$_src_sha" >"$PREFIX/.installed-sha256"
    fi
  fi

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
  "$PREFIX/bin/rackup" reshim >/dev/null

fi
# --- End source/prebuilt branch ---

if [ "$INSTALLED_PREBUILT" -eq 1 ]; then
  RACKUP_HOME="$PREFIX"
  export RACKUP_HOME
  . "$PREFIX/libexec/rackup-bootstrap.sh"
  # No hidden runtime needed — the prebuilt binary embeds its own Racket.
  # Remove any stale hidden runtime from a prior source install.
  if [ -d "$PREFIX/runtime" ]; then
    rm -rf "$PREFIX/runtime"
  fi
  # Also remove stale source files from a prior source install.
  if [ -f "$PREFIX/libexec/rackup-core.rkt" ]; then
    rm -rf "$PREFIX/libexec/rackup" "$PREFIX/libexec/rackup-core.rkt"
  fi
  "$PREFIX/bin/rackup" reshim >/dev/null
fi

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
    printf "Initialize %s shell config now? [Y/n] " "$shell_to_init" >/dev/tty
    answer=""
    read -r answer </dev/tty || true
    case "${answer:-Y}" in
      y | Y | yes | YES | "")
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
