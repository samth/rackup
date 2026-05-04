#!/usr/bin/env bash

# Shared helpers for E2E container scripts.

fail() {
  echo "E2E failure: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assert_eq failed}"
  [[ "$expected" == "$actual" ]] || fail "$msg (expected='$expected' actual='$actual')"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-assert_contains failed}"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (needle='$needle' haystack='$haystack')"
}

assert_nonempty() {
  local value="$1"
  local msg="${2:-assert_nonempty failed}"
  [[ -n "$value" ]] || fail "$msg"
}

link_external_download_cache() {
  local target_home="$1"
  local external_cache="${RACKUP_E2E_DOWNLOAD_CACHE_DIR:-}"
  [[ -n "$external_cache" ]] || return 0
  mkdir -p "$target_home/cache"
  rm -rf "$target_home/cache/downloads"
  ln -s "$external_cache" "$target_home/cache/downloads"
}

create_local_test_package() {
  local pkg_dir="$1"
  local pkg_name="$2"
  local marker_value="$3"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"
  cat >"$pkg_dir/info.rkt" <<EOF_INFO
#lang info
(define collection "$pkg_name")
(define deps '("base"))
EOF_INFO
  cat >"$pkg_dir/main.rkt" <<EOF_MAIN
#lang racket/base
(provide marker)
(define marker "$marker_value")
EOF_MAIN
}

create_simple_local_source_tree() {
  local root="$1"
  local label_prefix="$2"
  local chez_machine="$3"
  local chez_bin_dir="$root/racket/src/build/cs/c/ChezScheme/$chez_machine/bin/$chez_machine"

  write_passthrough_script() {
    local script_path="$1"
    local label="$2"
    cat >"$script_path" <<EOF_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
printf "%s-%s %s\n" "$label_prefix" "$label" "$*"
EOF_SCRIPT
  }

  rm -rf "$root"
  mkdir -p     "$root/racket/bin"     "$root/racket/collects"     "$root/pkgs"     "$chez_bin_dir"

  cat >"$root/racket/bin/racket" <<EOF_RACKET
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
  case "$2" in
    *"(version)"*) printf "9.99-local"; exit 0 ;;
    *"system-type 'vm"*) printf "cs"; exit 0 ;;
  esac
fi
printf "%s-RACKET %s\n" "$label_prefix" "$*"
EOF_RACKET

  write_passthrough_script "$root/racket/bin/raco" "RACO"
  write_passthrough_script "$chez_bin_dir/scheme" "SCHEME"
  write_passthrough_script "$chez_bin_dir/petite" "PETITE"

  chmod +x     "$root/racket/bin/racket"     "$root/racket/bin/raco"     "$chez_bin_dir/scheme"     "$chez_bin_dir/petite"
}
