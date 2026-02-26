#!/bin/sh
set -eu

# Shared shell helpers for rackup bootstrap and wrapper runtime selection.
# POSIX sh only (for curl|sh compatibility).

rackup_home() {
  if [ "${RACKUP_HOME:-}" ]; then
    printf '%s\n' "$RACKUP_HOME"
  else
    printf '%s\n' "$HOME/.rackup"
  fi
}

rackup_runtime_dir() {
  printf '%s\n' "$(rackup_home)/runtime"
}

rackup_runtime_versions_dir() {
  printf '%s\n' "$(rackup_runtime_dir)/versions"
}

rackup_runtime_current_link() {
  printf '%s\n' "$(rackup_runtime_dir)/current"
}

rackup_runtime_lock_dir() {
  printf '%s\n' "$(rackup_runtime_dir)/.lock"
}

rackup_runtime_current_racket() {
  printf '%s\n' "$(rackup_runtime_current_link)/bin/racket"
}

rackup_runtime_cache_dir() {
  printf '%s\n' "$(rackup_home)/cache/downloads"
}

rackup_mkdir_p() {
  mkdir -p "$1"
}

rackup_warn() {
  printf 'rackup bootstrap: %s\n' "$*" >&2
}

rackup_fail() {
  printf 'rackup bootstrap: %s\n' "$*" >&2
  exit 1
}

rackup_download_to() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    rackup_fail "need curl or wget"
  fi
}

rackup_fetch_text() {
  url="$1"
  tmp="$(mktemp "${TMPDIR:-/tmp}/rackup-fetch.XXXXXX")"
  rackup_download_to "$url" "$tmp"
  cat "$tmp"
  rm -f "$tmp"
}

rackup_normalized_arch() {
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$m" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    i386|i686|x86) echo "i386" ;;
    armv7*|armv6*|arm) echo "arm" ;;
    *) echo "$m" ;;
  esac
}

rackup_lookup_stable_version_shell() {
  txt="$(rackup_fetch_text "https://download.racket-lang.org/version.txt")" || return 1
  ver="$(printf '%s\n' "$txt" | sed -n 's/.*(stable "\([^"]*\)").*/\1/p' | head -n 1)"
  [ -n "$ver" ] || rackup_fail "failed to parse stable version from download.racket-lang.org/version.txt"
  printf '%s\n' "$ver"
}

rackup_select_hidden_runtime_filename() {
  version="$1"
  arch="$2"
  table_url="https://download.racket-lang.org/installers/$version/table.rktd"
  table="$(rackup_fetch_text "$table_url")" || rackup_fail "failed to fetch $table_url"

  # Extract candidate .sh installers from table.rktd conservatively.
  candidates="$(printf '%s\n' "$table" | grep -Eo 'racket(-minimal)?-[^"[:space:]]+\.sh' | sort -u || true)"
  [ -n "$candidates" ] || rackup_fail "failed to parse installer candidates from $table_url"

  found=""
  for f in $candidates; do
    case "$f" in
      racket-minimal-*.sh) ;;
      *) continue ;;
    esac

    base=${f%.sh}
    case "$base" in
      *-cs) : ;;
      *) continue ;;
    esac

    rest=${base#racket-minimal-}
    version_token=${rest%%-*}
    case "$version_token" in
      "$version"|"$version".*) : ;;
      *) continue ;;
    esac

    rest2=${rest#"$version_token"-}
    arch_token=${rest2%%-*}
    [ "$arch_token" = "$arch" ] || continue
    platform_and_variant=${rest2#"$arch_token"-}
    platform_token=${platform_and_variant%-cs}

    case "$platform_token" in
      linux|linux-*)
        case "$platform_token" in
          *natipkg*|*pkg-build*) continue ;;
        esac
        ;;
      *)
        continue
        ;;
    esac

    found="$f"
    break
  done

  [ -n "$found" ] || rackup_fail "no matching hidden runtime installer found for stable=$version arch=$arch"
  printf '%s\n' "$found"
}

rackup_detect_bin_dir_shell() {
  install_root="$1"
  if [ -d "$install_root/bin" ]; then
    printf '%s\n' "$install_root/bin"
  elif [ -d "$install_root/racket/bin" ]; then
    printf '%s\n' "$install_root/racket/bin"
  else
    rackup_fail "could not find runtime bin dir under $install_root"
  fi
}

rackup_acquire_runtime_lock_shell() {
  lockdir="$(rackup_runtime_lock_dir)"
  rackup_mkdir_p "$(rackup_runtime_dir)"
  if mkdir "$lockdir" 2>/dev/null; then
    return 0
  fi
  rackup_fail "runtime lock is held (remove $lockdir if stale)"
}

rackup_release_runtime_lock_shell() {
  lockdir="$(rackup_runtime_lock_dir)"
  rmdir "$lockdir" 2>/dev/null || true
}

rackup_hidden_runtime_present() {
  [ -x "$(rackup_runtime_current_racket)" ]
}

rackup_hidden_runtime_install_if_missing() {
  if rackup_hidden_runtime_present; then
    return 0
  fi

  rackup_acquire_runtime_lock_shell
  trap 'rackup_release_runtime_lock_shell' EXIT INT TERM HUP

  if rackup_hidden_runtime_present; then
    rackup_release_runtime_lock_shell
    trap - EXIT INT TERM HUP
    return 0
  fi

  home="$(rackup_home)"
  runtime_dir="$(rackup_runtime_dir)"
  versions_dir="$(rackup_runtime_versions_dir)"
  current_link="$(rackup_runtime_current_link)"
  cache_dir="$(rackup_runtime_cache_dir)"

  rackup_mkdir_p "$home"
  rackup_mkdir_p "$versions_dir"
  rackup_mkdir_p "$cache_dir"

  arch="$(rackup_normalized_arch)"
  stable_ver="$(rackup_lookup_stable_version_shell)"
  filename="$(rackup_select_hidden_runtime_filename "$stable_ver" "$arch")"
  installer_url="https://download.racket-lang.org/installers/$stable_ver/$filename"
  runtime_id="runtime-$stable_ver-cs-$arch-linux-minimal"
  version_dir="$versions_dir/$runtime_id"
  tmp_version_dir="$versions_dir/.${runtime_id}.tmp.$$"
  install_root="$tmp_version_dir/install"
  bin_link="$tmp_version_dir/bin"
  installer_cache="$cache_dir/$filename"

  if [ -d "$version_dir" ] && [ -x "$bin_link/racket" ]; then
    ln -sfn "$version_dir" "$current_link"
    rackup_release_runtime_lock_shell
    trap - EXIT INT TERM HUP
    return 0
  fi

  rm -rf "$tmp_version_dir"
  mkdir -p "$tmp_version_dir"

  if [ ! -f "$installer_cache" ]; then
    rackup_warn "downloading hidden runtime installer: $installer_url"
    rackup_download_to "$installer_url" "$installer_cache"
    chmod 0755 "$installer_cache" || true
  fi

  rackup_warn "installing hidden runtime: $runtime_id"
  installer_log="$(mktemp "${TMPDIR:-/tmp}/rackup-hidden-runtime-installer.XXXXXX.log")"
  if ! /bin/sh "$installer_cache" --create-dir --in-place --dest "$install_root" >"$installer_log" 2>&1; then
    sed -n '1,200p' "$installer_log" >&2 || true
    rm -f "$installer_log"
    rm -rf "$tmp_version_dir"
    rackup_fail "hidden runtime installer failed"
  fi
  rm -f "$installer_log"

  rm -rf "$version_dir"
  mv "$tmp_version_dir" "$version_dir"
  final_real_bin="$(rackup_detect_bin_dir_shell "$version_dir/install")"
  ln -sfn "$final_real_bin" "$version_dir/bin"
  ln -sfn "$version_dir" "$current_link"

  rackup_release_runtime_lock_shell
  trap - EXIT INT TERM HUP
  return 0
}

rackup_find_system_racket() {
  home="$(rackup_home)"
  shims="$home/shims"
  oldifs="${IFS:- }"
  IFS=:
  for d in ${PATH:-}; do
    [ -n "$d" ] || continue
    [ "$d" = "$shims" ] && continue
    cand="$d/racket"
    if [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      IFS="$oldifs"
      return 0
    fi
  done
  IFS="$oldifs"
  return 1
}

rackup_select_runtime_racket_or_fail() {
  if rackup_hidden_runtime_present; then
    rackup_runtime_current_racket
    return 0
  fi
  if sys="$(rackup_find_system_racket 2>/dev/null)"; then
    printf '%s\n' "$sys"
    return 0
  fi
  cat >&2 <<'EOF'
rackup: no Racket runtime available.

`rackup` uses an internal hidden runtime. It appears to be missing, and no system
`racket` was found on PATH.

Recovery:
  curl -fsSL https://samth.github.io/rackup/install.sh | sh
  # or, from a checkout:
  sh scripts/install.sh
EOF
  return 1
}
