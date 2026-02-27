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

rackup_default_toolchain_file() {
  printf '%s\n' "$(rackup_home)/state/default-toolchain"
}

rackup_read_default_toolchain_shell() {
  f="$(rackup_default_toolchain_file)"
  if [ -f "$f" ]; then
    tr -d '\r\n' < "$f"
  fi
}

rackup_toolchain_meta_file_shell() {
  toolchain_id="$1"
  printf '%s\n' "$(rackup_home)/toolchains/$toolchain_id/meta.rktd"
}

rackup_rktd_string_field_shell() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  grep -Eo "\\($key \\. \"[^\"]*\"\\)" "$file" 2>/dev/null \
    | sed -n 's/.*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

rackup_rktd_symbol_field_shell() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  grep -Eo "\\($key \\. [^ )]+\\)" "$file" 2>/dev/null \
    | sed -n 's/.*\. \([^ )]*\)).*/\1/p' \
    | head -n 1
}

rackup_prompt_short_shell() {
  active="$1"
  meta_file="$(rackup_toolchain_meta_file_shell "$active")"
  kind="$(rackup_rktd_symbol_field_shell kind "$meta_file")"
  version="$(rackup_rktd_string_field_shell resolved-version "$meta_file")"
  case "$kind" in
    release|stable)
      suffix="${version:-$active}"
      ;;
    pre-release)
      suffix="pre-${version:-$active}"
      ;;
    snapshot)
      suffix="snapshot-${version:-$active}"
      ;;
    local)
      if [ -n "${version:-}" ] && [ "$version" != "local" ]; then
        suffix="local-$version"
      else
        suffix="local-${active#local-}"
      fi
      ;;
    *)
      case "$active" in
        release-*)
          suffix="${active#release-}"
          suffix="${suffix%%-*}"
          ;;
        pre-*)
          suffix="${active#pre-}"
          suffix="pre-${suffix%%-*}"
          ;;
        snapshot-*)
          suffix="snapshot-$active"
          ;;
        local-*)
          suffix="local-${active#local-}"
          ;;
        *)
          suffix="$active"
          ;;
      esac
      ;;
  esac
  printf 'racket-%s\n' "$suffix"
}

rackup_prompt_shell() {
  mode="${1:-}"
  active="${RACKUP_TOOLCHAIN:-}"
  source_kind=""
  if [ -n "$active" ]; then
    source_kind="env"
  else
    active="$(rackup_read_default_toolchain_shell)"
    if [ -n "$active" ]; then
      source_kind="default"
    fi
  fi
  [ -n "$active" ] || return 0
  case "$mode" in
    --long)
      printf '[rk:%s]\n' "$active"
      ;;
    --short)
      rackup_prompt_short_shell "$active"
      ;;
    --raw)
      printf '%s\n' "$active"
      ;;
    --source)
      printf '%s\t%s\n' "$active" "$source_kind"
      ;;
    *)
      rackup_prompt_short_shell "$active"
      ;;
  esac
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
    riscv64) echo "riscv64" ;;
    ppc|powerpc|ppc64|ppc64le|powerpc64|powerpc64le) echo "ppc" ;;
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

  # Extract candidate installers from table.rktd conservatively.
  candidates="$(printf '%s\n' "$table" | grep -Eo 'racket(-minimal)?-[^"[:space:]]+\.(sh|tgz)' | sort -u || true)"
  [ -n "$candidates" ] || rackup_fail "failed to parse installer candidates from $table_url"

  found=""
  for want_variant in cs bc; do
    for want_ext in sh tgz; do
      for f in $candidates; do
        case "$f" in
          racket-minimal-*."$want_ext") ;;
          *) continue ;;
        esac

        ext=${f##*.}
        base=${f%."$ext"}
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

        variant=bc
        platform_token=$platform_and_variant
        case "$platform_and_variant" in
          *-cs)
            variant=cs
            platform_token=${platform_and_variant%-cs}
            ;;
          *-bc)
            variant=bc
            platform_token=${platform_and_variant%-bc}
            ;;
        esac
        [ "$variant" = "$want_variant" ] || continue

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
        break 3
      done
    done
  done

  [ -n "$found" ] || rackup_fail "no matching hidden runtime installer found for stable=$version arch=$arch"
  printf '%s\n' "$found"
}

rackup_runtime_variant_from_filename() {
  f="$1"
  base=${f%.*}
  case "$base" in
    *-cs) printf '%s\n' "cs" ;;
    *-bc) printf '%s\n' "bc" ;;
    *) printf '%s\n' "bc" ;;
  esac
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
  runtime_variant="$(rackup_runtime_variant_from_filename "$filename")"
  runtime_ext="${filename##*.}"
  installer_url="https://download.racket-lang.org/installers/$stable_ver/$filename"
  runtime_id="runtime-$stable_ver-$runtime_variant-$arch-linux-minimal"
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
    if [ "$runtime_ext" = "sh" ]; then
      chmod 0755 "$installer_cache" || true
    fi
  fi

  rackup_warn "installing hidden runtime: $runtime_id"
  case "$runtime_ext" in
    sh)
      installer_log="$(mktemp "${TMPDIR:-/tmp}/rackup-hidden-runtime-installer.XXXXXX.log")"
      if ! /bin/sh "$installer_cache" --create-dir --in-place --dest "$install_root" >"$installer_log" 2>&1; then
        sed -n '1,200p' "$installer_log" >&2 || true
        rm -f "$installer_log"
        rm -rf "$tmp_version_dir"
        rackup_fail "hidden runtime installer failed"
      fi
      rm -f "$installer_log"
      ;;
    tgz)
      mkdir -p "$install_root"
      if ! tar -xzf "$installer_cache" -C "$install_root"; then
        rm -rf "$tmp_version_dir"
        rackup_fail "hidden runtime archive extraction failed"
      fi
      ;;
    *)
      rm -rf "$tmp_version_dir"
      rackup_fail "unsupported hidden runtime installer format: $runtime_ext"
      ;;
  esac

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
