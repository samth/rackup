#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${RACKUP_NATIVE_I386_VM_CI_WORKDIR:-$ROOT_DIR/.ci-cache/native-i386-vm}"
MEMORY_MB="${RACKUP_NATIVE_I386_VM_CI_MEMORY_MB:-1536}"
CPUS="${RACKUP_NATIVE_I386_VM_CI_CPUS:-2}"
DISK_SIZE="${RACKUP_NATIVE_I386_VM_CI_DISK_SIZE:-8G}"

args=(
  --workdir "$WORKDIR"
  --mode smoke
  --no-kvm
  --memory "$MEMORY_MB"
  --cpus "$CPUS"
  --disk-size "$DISK_SIZE"
)

if [[ -f "$WORKDIR/debian-i386.qcow2" ]]; then
  args+=(--skip-install)
fi

exec "$ROOT_DIR/test/native-i386-vm-test.sh" "${args[@]}" "$@"
