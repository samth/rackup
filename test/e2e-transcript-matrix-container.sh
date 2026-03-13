#!/usr/bin/env bash
set -euo pipefail

TRACE="${RACKUP_TRANSCRIPT_TRACE:-0}"
if [[ "$TRACE" == "1" ]]; then
  set -x
fi

WORKDIR="${WORKDIR:-/work}"
RUN_SRC="${RUN_SRC:-/tmp/rackup-transcript-src}"
RACKUP_HOME="${RACKUP_HOME:-$HOME/.rackup-transcript}"
INSTALL_TIMEOUT="${RACKUP_TRANSCRIPT_INSTALL_TIMEOUT:-900}"
UNINSTALL_AT_END="${RACKUP_TRANSCRIPT_UNINSTALL_AT_END:-1}"

export TMPDIR="${TMPDIR:-/tmp}"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
export RACKUP_HOME

cleanup() {
  rm -rf "$RUN_SRC"
  rm -rf /tmp/rackup-extra-pkg /tmp/rackup-local-src
  rm -f /tmp/rackup-matrix-isolation.out /tmp/rackup-matrix-isolation.err
  if [[ "$UNINSTALL_AT_END" == "1" && -n "${RACKUP_HOME:-}" ]]; then
    rm -rf "$RACKUP_HOME"
  fi
}
trap cleanup EXIT

note() {
  printf '\n== %s ==\n' "$*"
}

install_toolchain() {
  local label="$1"
  shift
  timeout "$INSTALL_TIMEOUT" "$RACKUP_BIN" install "$@" --set-default >&2
  local id
  id="$("$RACKUP_BIN" current id)"
  printf 'captured-id[%s]=%s\n' "$label" "$id" >&2
  printf '%s' "$id"
}

note "Preparing source copy"
rm -rf "$RUN_SRC"
mkdir -p "$RUN_SRC"
"$WORKDIR/scripts/copy-filtered-tree.sh" "$WORKDIR" "$RUN_SRC"

note "Bootstrapping rackup"
rm -rf "$RACKUP_HOME"
bash "$RUN_SRC/scripts/install.sh" -y --no-init --from-local "$RUN_SRC"
RACKUP_BIN="$RACKUP_HOME/bin/rackup"

note "Help and discovery commands"
"$RACKUP_BIN" --help
"$RACKUP_BIN" help install
"$RACKUP_BIN" available --limit 20
"$RACKUP_BIN" available --all | sed -n '1,40p'

note "Install matrix"
stable_min_id="$(install_toolchain stable-minimal --distribution minimal stable)"
stable_full_id="$(install_toolchain stable-full stable)"
id_818="$(install_toolchain v8_18_minimal 8.18 --distribution minimal)"
id_810="$(install_toolchain v8_10 8.10)"
id_79="$(install_toolchain v7_9 7.9)"
id_pre="$(install_toolchain pre_release pre-release)"
id_snap="$(install_toolchain snapshot snapshot --snapshot-site auto)"

id_612=""
if timeout "$INSTALL_TIMEOUT" "$RACKUP_BIN" install 6.12 --set-default; then
  id_612="$("$RACKUP_BIN" current id)"
  printf 'captured-id[%s]=%s\n' "v6_12" "$id_612"
else
  echo "note: install 6.12 failed, continuing"
fi

id_52="$(install_toolchain v5_2_minimal 5.2 --distribution minimal)"

note "List and switch matrix"
"$RACKUP_BIN" list
"$RACKUP_BIN" current
for id in "$stable_min_id" "$stable_full_id" "$id_818" "$id_810" "$id_79" "$id_pre" "$id_snap" "$id_52"; do
  "$RACKUP_BIN" default "$id"
  "$RACKUP_BIN" current
done
if [[ -n "$id_612" ]]; then
  "$RACKUP_BIN" default "$id_612"
  "$RACKUP_BIN" current
fi

note "Run commands under selected toolchains"
for id in "$stable_full_id" "$id_818" "$id_79" "$id_pre" "$id_snap"; do
  "$RACKUP_BIN" run "$id" -- racket -e '(display (version))'
  echo
done

note "Which and prompt commands"
"$RACKUP_BIN" which racket --toolchain "$id_52"
"$RACKUP_BIN" which raco --toolchain "$id_52"
"$RACKUP_BIN" current id
"$RACKUP_BIN" current source
"$RACKUP_BIN" current line
"$RACKUP_BIN" default id
"$RACKUP_BIN" default status
"$RACKUP_BIN" prompt
"$RACKUP_BIN" prompt --long
"$RACKUP_BIN" prompt --short
"$RACKUP_BIN" prompt --raw
"$RACKUP_BIN" prompt --source

note "Package isolation"
pkg_dir=/tmp/rackup-extra-pkg
rm -rf "$pkg_dir"
mkdir -p "$pkg_dir"
cat >"$pkg_dir/info.rkt" <<'EOF'
#lang info
(define collection "rackup-extra-pkg")
(define deps '("base"))
EOF
cat >"$pkg_dir/main.rkt" <<'EOF'
#lang racket/base
(provide marker)
(define marker "rackup-extra-ok")
EOF
"$RACKUP_BIN" default "$stable_full_id"
"$RACKUP_BIN" run "$stable_full_id" -- raco pkg install --auto --batch --no-setup "$pkg_dir"
"$RACKUP_BIN" run "$stable_full_id" -- racket -e '(require rackup-extra-pkg) (displayln marker)'
"$RACKUP_BIN" default "$id_818"
if "$RACKUP_BIN" run "$id_818" -- racket -e '(require rackup-extra-pkg) (display marker)' >/tmp/rackup-matrix-isolation.out 2>/tmp/rackup-matrix-isolation.err; then
  echo "unexpected shared package visibility"
  exit 1
else
  echo "package isolation confirmed"
fi

note "Shell commands"
"$RACKUP_BIN" init --shell bash
"$RACKUP_BIN" init --shell zsh
"$RACKUP_BIN" switch "$stable_full_id" | sed -n '1,20p'
"$RACKUP_BIN" switch --unset | sed -n '1,20p'

note "Link local source tree"
local_src=/tmp/rackup-local-src
rm -rf "$local_src"
mkdir -p "$local_src/racket/bin" \
  "$local_src/racket/collects" \
  "$local_src/pkgs" \
  "$local_src/racket/src/build/cs/c/ChezScheme/pb/bin/pb"
cat >"$local_src/racket/bin/racket" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
  case "$2" in
    *"(version)"*) printf "9.99-local"; exit 0 ;;
    *"system-type 'vm"*) printf "cs"; exit 0 ;;
  esac
fi
printf "LOCAL-RACKET %s\n" "$*"
EOF
cat >"$local_src/racket/bin/raco" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "LOCAL-RACO %s\n" "$*"
EOF
cat >"$local_src/racket/src/build/cs/c/ChezScheme/pb/bin/pb/scheme" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "LOCAL-SCHEME %s\n" "$*"
EOF
cat >"$local_src/racket/src/build/cs/c/ChezScheme/pb/bin/pb/petite" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf "LOCAL-PETITE %s\n" "$*"
EOF
chmod +x \
  "$local_src/racket/bin/racket" \
  "$local_src/racket/bin/raco" \
  "$local_src/racket/src/build/cs/c/ChezScheme/pb/bin/pb/scheme" \
  "$local_src/racket/src/build/cs/c/ChezScheme/pb/bin/pb/petite"

"$RACKUP_BIN" link matrix "$local_src" --set-default
"$RACKUP_BIN" which scheme --toolchain local-matrix
"$RACKUP_BIN" run local-matrix -- scheme --version
"$RACKUP_BIN" default "$stable_full_id"

note "Remove and reshim"
"$RACKUP_BIN" remove "$id_810"
"$RACKUP_BIN" reshim
"$RACKUP_BIN" list

note "Runtime and self-upgrade"
"$RACKUP_BIN" runtime status
"$RACKUP_BIN" runtime upgrade || true
RACKUP_TEST_ALLOW_SELF_UPGRADE_INSTALL_SH=1 \
RACKUP_SELF_UPGRADE_INSTALL_SH="$RUN_SRC/scripts/install.sh" \
"$RACKUP_BIN" self-upgrade

if [[ "$UNINSTALL_AT_END" == "1" ]]; then
  note "Uninstall"
  "$RACKUP_BIN" uninstall --yes
  for _ in $(seq 1 30); do
    [[ ! -e "$RACKUP_HOME" ]] && break
    sleep 0.2
  done
  [[ ! -e "$RACKUP_HOME" ]]
fi

note "Done"
