#!/bin/sh
set -eu

LOG_FILE=/var/log/rackup-native-i386-firstboot.log
MOUNT_POINT=/mnt/hostshare
REPO_DIR="$MOUNT_POINT/repo"
ARTIFACTS_DIR="$MOUNT_POINT/artifacts"
OUTPUT_DIR="$MOUNT_POINT/output"
CONFIG_ENV="$MOUNT_POINT/config.env"
RACKUP_HOME_DIR=/root/.rackup
TOOLCHAIN_ID=release-103p1-bc-i386-linux-full
ARTIFACT_NAME=plt-103p1-bin-i386-linux.tgz
REAL_BIN="$RACKUP_HOME_DIR/toolchains/$TOOLCHAIN_ID/install/plt/.bin/i386-linux/mzscheme"
ENV_FILE="$RACKUP_HOME_DIR/toolchains/$TOOLCHAIN_ID/env.sh"
PREP_MARKER=/var/lib/rackup-native-i386/prepared-v1
MODE=debug
RESULT=fail
LAST_STATUS=0
FAIL_REASON=unknown

exec >"$LOG_FILE" 2>&1
set -x

mount_hostshare() {
  mkdir -p "$MOUNT_POINT"
  modprobe 9p || true
  modprobe 9pnet || true
  modprobe 9pnet_virtio || true
  mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576 hostshare "$MOUNT_POINT"
}

load_config() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV"
  fi
  MODE="${RACKUP_NATIVE_I386_VM_MODE:-$MODE}"
}

init_summary() {
  {
    printf 'mode=%s\n' "$MODE"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'arch=%s\n' "$(dpkg --print-architecture)"
    printf 'toolchain_id=%s\n' "$TOOLCHAIN_ID"
    printf 'real_bin=%s\n' "$REAL_BIN"
    if [ -e "$REAL_BIN" ]; then
      file "$REAL_BIN" || true
      ldd "$REAL_BIN" || true
    fi
    if [ -x "$RACKUP_HOME_DIR/toolchains/$TOOLCHAIN_ID/install/plt/bin/archsys" ]; then
      printf 'archsys=%s\n' "$("$RACKUP_HOME_DIR/toolchains/$TOOLCHAIN_ID/install/plt/bin/archsys" z 2>/dev/null || true)"
    fi
  } >"$OUTPUT_DIR/summary.txt"
}

record_status() {
  printf '%s_status=%s\n' "$1" "$2" >>"$OUTPUT_DIR/summary.txt"
}

record_result() {
  printf 'result=%s\n' "$RESULT" >>"$OUTPUT_DIR/summary.txt"
  printf 'fail_reason=%s\n' "$FAIL_REASON" >>"$OUTPUT_DIR/summary.txt"
}

finish_and_poweroff() {
  record_result
  cp "$LOG_FILE" "$OUTPUT_DIR/guest.log"
  sync
  systemctl poweroff
}

run_case() {
  name="$1"
  shift
  set +e
  "$@" <"$OUTPUT_DIR/mzscheme.input" >"$OUTPUT_DIR/$name.stdout" 2>"$OUTPUT_DIR/$name.stderr"
  LAST_STATUS=$?
  set -e
  record_status "$name" "$LAST_STATUS"
}

run_case_sh() {
  name="$1"
  script="$2"
  shift 2
  set +e
  sh -c "$script" sh "$@" <"$OUTPUT_DIR/mzscheme.input" >"$OUTPUT_DIR/$name.stdout" 2>"$OUTPUT_DIR/$name.stderr"
  LAST_STATUS=$?
  set -e
  record_status "$name" "$LAST_STATUS"
}

ensure_guest_packages() {
  mkdir -p "$(dirname "$PREP_MARKER")"
  if [ ! -f "$PREP_MARKER" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends racket file util-linux
    if [ "$MODE" = debug ]; then
      apt-get install -y --no-install-recommends strace gdb
    fi
    date -u >"$PREP_MARKER"
  elif [ "$MODE" = debug ]; then
    if ! command -v strace >/dev/null 2>&1 || ! command -v gdb >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends strace gdb
    fi
  fi
}

output_contains_ok() {
  file="$1"
  grep -Fq "ok" "$file"
}

mount_hostshare
mkdir -p "$OUTPUT_DIR"
load_config
ensure_guest_packages

mkdir -p "$RACKUP_HOME_DIR/cache/downloads"
cp "$ARTIFACTS_DIR/$ARTIFACT_NAME" "$RACKUP_HOME_DIR/cache/downloads/"

cd "$REPO_DIR"
export RACKUP_HOME="$RACKUP_HOME_DIR"

set +e
racket -y libexec/rackup-core.rkt install --arch i386 103p1 >"$OUTPUT_DIR/install.stdout" 2>"$OUTPUT_DIR/install.stderr"
install_status=$?
set -e
record_status install "$install_status"

set +e
racket -y libexec/rackup-core.rkt list >"$OUTPUT_DIR/list.stdout" 2>"$OUTPUT_DIR/list.stderr"
list_status=$?
set -e
record_status list "$list_status"

export PATH="$RACKUP_HOME_DIR/shims:$PATH"
export RACKUP_TOOLCHAIN="$TOOLCHAIN_ID"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
if [ -z "${PLTADDONDIR:-}" ]; then
  export PLTADDONDIR="$RACKUP_HOME_DIR/addons/$TOOLCHAIN_ID"
fi

printf '(display "ok")\n(exit)\n' >"$OUTPUT_DIR/mzscheme.input"

init_summary

if [ "$install_status" -ne 0 ]; then
  FAIL_REASON=install_failed
  finish_and_poweroff
fi

if [ "$list_status" -ne 0 ]; then
  FAIL_REASON=list_failed
  finish_and_poweroff
fi

run_case shim mzscheme
shim_status=$LAST_STATUS
run_case_sh shim-no-aslr 'exec setarch i386 -R "$@"' mzscheme
shim_no_aslr_status=$LAST_STATUS

if [ "$MODE" = debug ]; then
  run_case direct "$REAL_BIN"
  run_case_sh direct-ulimit-unlimited 'ulimit -s unlimited; exec "$1"' "$REAL_BIN"
  run_case_sh direct-no-aslr 'exec setarch i386 -R "$1"' "$REAL_BIN"
  run_case_sh direct-min-env 'exec env -i HOME=/root PATH=/usr/bin:/bin PLTHOME="$2" PLTADDONDIR="$3" "$1"' "$REAL_BIN" "$PLTHOME" "$PLTADDONDIR"
  run_case_sh direct-no-aslr-min-env 'exec env -i HOME=/root PATH=/usr/bin:/bin PLTHOME="$2" PLTADDONDIR="$3" setarch i386 -R "$1"' "$REAL_BIN" "$PLTHOME" "$PLTADDONDIR"

  set +e
  strace -f -o "$OUTPUT_DIR/mzscheme.strace" "$REAL_BIN" <"$OUTPUT_DIR/mzscheme.input" >"$OUTPUT_DIR/mzscheme-strace.stdout" 2>"$OUTPUT_DIR/mzscheme-strace.stderr"
  strace_status=$?
  gdb -q -batch -ex "run < $OUTPUT_DIR/mzscheme.input" -ex bt --args "$REAL_BIN" >"$OUTPUT_DIR/mzscheme.gdb" 2>&1
  gdb_status=$?
  set -e
  record_status strace "$strace_status"
  record_status gdb "$gdb_status"
fi

if [ "$shim_no_aslr_status" -ne 0 ]; then
  FAIL_REASON=shim_no_aslr_failed
  finish_and_poweroff
fi

if ! output_contains_ok "$OUTPUT_DIR/shim-no-aslr.stdout"; then
  FAIL_REASON=shim_no_aslr_missing_ok
  finish_and_poweroff
fi

RESULT=pass
FAIL_REASON=none
record_status plain_shim_observed "$shim_status"
finish_and_poweroff
