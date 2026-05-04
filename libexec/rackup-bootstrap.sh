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

rackup_runtime_addon_dir() {
  printf '%s\n' "$(rackup_runtime_dir)/addon"
}

rackup_system_runtime_addon_dir() {
  uid_part=""
  if command -v id >/dev/null 2>&1; then
    uid_part="$(id -u 2>/dev/null || true)"
  fi
  if [ -n "$uid_part" ]; then
    printf '%s\n' "${TMPDIR:-/tmp}/rackup-system-addon-$uid_part"
  else
    printf '%s\n' "${TMPDIR:-/tmp}/rackup-system-addon"
  fi
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

rackup_state_dir() {
  printf '%s\n' "$(rackup_home)/state"
}

rackup_toolchains_dir() {
  printf '%s\n' "$(rackup_home)/toolchains"
}

rackup_addons_dir() {
  printf '%s\n' "$(rackup_home)/addons"
}

rackup_shims_dir() {
  printf '%s\n' "$(rackup_home)/shims"
}

rackup_default_toolchain_file() {
  printf '%s\n' "$(rackup_state_dir)/default-toolchain"
}

rackup_read_default_toolchain_shell() {
  f="$(rackup_default_toolchain_file)"
  if [ -f "$f" ]; then
    tr -d '\r\n' <"$f"
  fi
}

rackup_toolchain_meta_file_shell() {
  toolchain_id="$1"
  printf '%s\n' "$(rackup_toolchains_dir)/$toolchain_id/meta.rktd"
}

rackup_rktd_string_field_shell() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  grep -Eo "\\($key \\. \"[^\"]*\"\\)" "$file" 2>/dev/null |
    sed -n 's/.*"\([^"]*\)".*/\1/p' |
    head -n 1
}

rackup_rktd_symbol_field_shell() {
  key="$1"
  file="$2"
  [ -f "$file" ] || return 0
  grep -Eo "\\($key \\. [^ )]+\\)" "$file" 2>/dev/null |
    sed -n 's/.*\. \([^ )]*\)).*/\1/p' |
    head -n 1
}

rackup_prompt_short_shell() {
  active="$1"
  meta_file="$(rackup_toolchain_meta_file_shell "$active")"
  kind="$(rackup_rktd_symbol_field_shell kind "$meta_file")"
  version="$(rackup_rktd_string_field_shell resolved-version "$meta_file")"
  case "$kind" in
    release | stable)
      suffix="${version:-$active}"
      ;;
    pre-release)
      suffix="pre-${version:-$active}"
      ;;
    snapshot)
      suffix="snapshot-${version:-$active}"
      ;;
    local)
      spec="$(rackup_rktd_string_field_shell requested-spec "$meta_file")"
      printf '%s\n' "${spec:-${active#local-}}"
      return
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

rackup_prompt_help_shell() {
  cat <<'EOF'
Usage: rackup prompt [--long|--short|--raw|--source]

Print prompt/status information for the active toolchain.
Prints nothing when no active/default toolchain is configured.
Handled by the shell wrapper without starting Racket when possible.

Default output:
  racket-9.1

Options:
  --long                  Print the long bracketed form: "[rk:<toolchain-id>]".
  --short                 Print a compact label like "racket-9.1" (same as default).
  --raw                   Print only the active toolchain id.
  --source                Print "<id><TAB><env|default>".

Examples:
  rackup prompt
  rackup prompt --long
  rackup prompt --short
  rackup prompt --raw
  PS1='$(rackup prompt) '$PS1
EOF
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

rackup_sha256_of_file() {
  _file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$_file" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$_file" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$_file" | awk '{print $NF}'
  else
    return 1
  fi
}

# Look up the expected SHA256 for a runtime installer filename
# from the RACKUP_RUNTIME_CHECKSUMS variable (set by install.sh).
# Format: "filename1:sha256hex\nfilename2:sha256hex\n..."
rackup_lookup_runtime_checksum() {
  _filename="$1"
  _checksums="${RACKUP_RUNTIME_CHECKSUMS:-}"
  if [ -z "$_checksums" ] || [ "$_checksums" = "@@RACKUP_RUNTIME_CHECKSUMS@@" ]; then
    # Unsubstituted token — only allow in test/dev mode
    if [ -n "${RACKUP_TESTING:-}" ]; then
      return 1
    fi
    rackup_fail "runtime checksums not available (unsubstituted install.sh); set RACKUP_TESTING=1 for development use"
  fi
  # Search for filename in the checksums list (filename:sha256hex per line).
  # Use a temp file to avoid subshell issues with piped while-read.
  _checksum_tmp="$(mktemp "${TMPDIR:-/tmp}/rackup-checksum.XXXXXX")"
  printf '%s\n' "$_checksums" >"$_checksum_tmp"
  _found_sha=""
  while IFS=: read -r name sha; do
    if [ "$name" = "$_filename" ]; then
      _found_sha="$sha"
      break
    fi
  done <"$_checksum_tmp"
  rm -f "$_checksum_tmp"
  if [ -n "$_found_sha" ]; then
    printf '%s' "$_found_sha"
    return 0
  fi
  return 1
}

rackup_verify_runtime_installer() {
  _filename="$1"
  _filepath="$2"
  _expected="$(rackup_lookup_runtime_checksum "$_filename")" || return 0
  if [ -z "$_expected" ]; then
    rackup_warn "no known checksum for $_filename; skipping verification"
    return 0
  fi
  _actual="$(rackup_sha256_of_file "$_filepath")" || {
    rackup_warn "no sha256 tool available; skipping verification"
    return 0
  }
  if [ "$_actual" != "$_expected" ]; then
    rackup_fail "checksum mismatch for $_filename: expected $_expected, got $_actual"
  fi
}

rackup_download_to() {
  url="$1"
  out="$2"
  mode="${3:-quiet}"
  if command -v curl >/dev/null 2>&1; then
    if [ "$mode" = "progress" ] && [ -t 2 ]; then
      curl -fL --progress-bar "$url" -o "$out"
    else
      curl -fsSL "$url" -o "$out"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ "$mode" = "progress" ] && [ -t 2 ]; then
      wget -O "$out" "$url"
    else
      wget -qO "$out" "$url"
    fi
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

rackup_host_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo "macosx" ;;
    Linux) echo "linux" ;;
    # TODO: BSD (FreeBSD, OpenBSD, NetBSD) also uses sh/tgz installers like Linux.
    # When BSD support is added, decide whether to return "linux" (shared installer
    # mechanics) or a distinct token like "freebsd" (matching Racket download filenames).
    *)
      rackup_fail "unsupported platform: $(uname -s)"
      ;;
  esac
}

rackup_normalized_arch() {
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$m" in
    x86_64 | amd64) echo "x86_64" ;;
    aarch64 | arm64) echo "aarch64" ;;
    i386 | i686 | x86) echo "i386" ;;
    armv7* | armv6* | arm) echo "arm" ;;
    riscv64) echo "riscv64" ;;
    ppc | powerpc | ppc64 | ppc64le | powerpc64 | powerpc64le) echo "ppc" ;;
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
  host_platform="$(rackup_host_platform)"
  table_url="https://download.racket-lang.org/installers/$version/table.rktd"
  table="$(rackup_fetch_text "$table_url")" || rackup_fail "failed to fetch $table_url"

  # Extract candidate installers from table.rktd conservatively.
  # On Linux: look for .sh and .tgz; on macOS: look for .tgz and .dmg
  case "$host_platform" in
    macosx)
      candidates="$(printf '%s\n' "$table" | grep -Eo 'racket(-minimal)?-[^"[:space:]]+\.(tgz|dmg)' | sort -u || true)"
      ;;
    *)
      candidates="$(printf '%s\n' "$table" | grep -Eo 'racket(-minimal)?-[^"[:space:]]+\.(sh|tgz)' | sort -u || true)"
      ;;
  esac
  [ -n "$candidates" ] || rackup_fail "failed to parse installer candidates from $table_url"

  # Set extension preference order based on platform
  case "$host_platform" in
    macosx) want_exts="tgz dmg" ;;
    *) want_exts="sh tgz" ;;
  esac

  found=""
  for want_variant in cs bc; do
    for want_ext in $want_exts; do
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
          "$version" | "$version".*) : ;;
          *) continue ;;
        esac

        rest2=${rest#"$version_token"-}
        arch_token=${rest2%%-*}
        [ "$arch_token" = "$arch" ] || continue
        platform_and_variant=${rest2#"$arch_token"-}

        variant='bc'
        platform_token=$platform_and_variant
        case "$platform_and_variant" in
          *-cs)
            variant='cs'
            platform_token=${platform_and_variant%-cs}
            ;;
          *-bc)
            variant='bc'
            platform_token=${platform_and_variant%-bc}
            ;;
        esac
        [ "$variant" = "$want_variant" ] || continue

        case "$host_platform" in
          linux)
            case "$platform_token" in
              linux | linux-*)
                case "$platform_token" in
                  *natipkg* | *pkg-build*) continue ;;
                esac
                ;;
              *)
                continue
                ;;
            esac
            ;;
          macosx)
            case "$platform_token" in
              macosx | macosx-*) ;;
              *) continue ;;
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

  [ -n "$found" ] || rackup_fail "no matching hidden runtime installer found for stable=$version arch=$arch platform=$host_platform"
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
  runtime_id="runtime-$stable_ver-$runtime_variant-$arch-$(rackup_host_platform)-minimal"
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

  if [ -f "$installer_cache" ]; then
    rackup_verify_runtime_installer "$filename" "$installer_cache"
  else
    rackup_warn "downloading hidden runtime installer: $installer_url"
    rackup_download_to "$installer_url" "$installer_cache" progress
    rackup_verify_runtime_installer "$filename" "$installer_cache"
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
    dmg)
      dmg_mount="$(mktemp -d "${TMPDIR:-/tmp}/rackup-dmg.XXXXXX")"
      if ! hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$dmg_mount" "$installer_cache" >/dev/null 2>&1; then
        rm -rf "$dmg_mount" "$tmp_version_dir"
        rackup_fail "failed to mount DMG installer"
      fi
      mkdir -p "$install_root"
      # Racket .dmg files contain a top-level directory (e.g. "Racket v9.1/")
      # with the standard bin/, lib/, share/ layout inside.
      src_dir=""
      for d in "$dmg_mount"/*/; do
        if [ -d "${d}bin" ]; then
          src_dir="$d"
          break
        fi
      done
      if [ -z "$src_dir" ]; then
        if [ -d "$dmg_mount/bin" ]; then
          src_dir="$dmg_mount/"
        else
          # Fall back to first directory
          for d in "$dmg_mount"/*/; do
            src_dir="$d"
            break
          done
        fi
      fi
      if [ -z "$src_dir" ]; then
        hdiutil detach "$dmg_mount" -quiet 2>/dev/null || true
        rm -rf "$dmg_mount" "$tmp_version_dir"
        rackup_fail "could not find Racket installation inside DMG"
      fi
      cp -R "$src_dir"/* "$install_root/" 2>/dev/null || cp -R "$src_dir". "$install_root/" 2>/dev/null || true
      hdiutil detach "$dmg_mount" -quiet 2>/dev/null || true
      rm -rf "$dmg_mount"
      ;;
    *)
      rm -rf "$tmp_version_dir"
      rackup_fail "unsupported hidden runtime installer format: $runtime_ext"
      ;;
  esac

  rm -rf "$tmp_version_dir/_pkg_cache_install_log" 2>/dev/null || true
  rm -rf "$version_dir"
  mv "$tmp_version_dir" "$version_dir"
  final_real_bin="$(rackup_detect_bin_dir_shell "$version_dir/install")"
  ln -sfn "$final_real_bin" "$version_dir/bin"
  ln -sfn "$version_dir" "$current_link"

  # The hidden runtime is a *minimal* Racket distribution. rackup's
  # libexec/rackup/shell.rkt requires `scribble/text` for the shell
  # helper templates, which lives in `scribble-text-lib`. Install it
  # at *installation* scope (under the hidden runtime tree, which
  # rackup owns) — bin/rackup invokes the runtime with `racket -U -A …`,
  # which suppresses user-scope pkgs even if PLTADDONDIR points at the
  # addon dir, so installation scope is the only consistent choice.
  raco_exe="$final_real_bin/raco"
  if [ ! -x "$raco_exe" ]; then
    rackup_fail "hidden runtime is missing raco at $raco_exe"
  fi
  rackup_warn "installing 'scribble-text-lib' package into hidden runtime..."
  if ! "$raco_exe" pkg install \
    --scope installation --no-docs --auto --skip-installed --batch scribble-text-lib >&2; then
    rm -rf "$version_dir"
    rm -f "$current_link"
    rackup_fail "failed to install 'scribble-text-lib' package into hidden runtime"
  fi

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
  if [ "${RACKUP_ALLOW_SYSTEM_RACKET:-}" = "1" ]; then
    if sys="$(rackup_find_system_racket 2>/dev/null)"; then
      printf '%s\n' "$sys"
      return 0
    fi
  fi
  cat >&2 <<'EOF'
rackup: no Racket runtime available.

`rackup` uses an internal hidden runtime. It appears to be missing.

Recovery:
  curl -fsSL https://samth.github.io/rackup/install.sh | sh
  # or, from a checkout:
  sh scripts/install.sh

To use a system `racket` from PATH instead (for development/testing):
  RACKUP_ALLOW_SYSTEM_RACKET=1 rackup ...
EOF
  return 1
}
