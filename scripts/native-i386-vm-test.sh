#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${RACKUP_NATIVE_I386_VM_WORKDIR:-/tmp/rackup-native-i386-vm}"
ISO_URL_DEFAULT="https://cdimage.debian.org/cdimage/archive/12.13.0/i386/iso-cd/debian-12.13.0-i386-netinst.iso"
ISO_SHA256_DEFAULT="61e5dbec68c511713611ffec58e40ba26c76487864b7dddfc59f8e55bacbe56a"
ARTIFACT_URL_DEFAULT="http://download.plt-scheme.org/bundles/103p1/plt/plt-103p1-bin-i386-linux.tgz"
ARTIFACT_SHA256_DEFAULT="7090e2d7df07c17530e50cbc5fde67b51b39f77c162b7f20413242dca923a20a"
ISO_URL="$ISO_URL_DEFAULT"
ISO_SHA256="$ISO_SHA256_DEFAULT"
ARTIFACT_URL="$ARTIFACT_URL_DEFAULT"
ARTIFACT_SHA256="$ARTIFACT_SHA256_DEFAULT"
MEMORY_MB="${RACKUP_NATIVE_I386_VM_MEMORY_MB:-2048}"
DISK_SIZE="${RACKUP_NATIVE_I386_VM_DISK_SIZE:-16G}"
CPUS="${RACKUP_NATIVE_I386_VM_CPUS:-2}"
MODE="${RACKUP_NATIVE_I386_VM_MODE:-debug}"
DOWNLOAD_ONLY=0
SKIP_INSTALL=0
NO_KVM=0

usage() {
  cat <<'EOF'
Boot a disposable native i386 Debian VM under KVM and run a rackup 103p1 smoke test.

This avoids the host's qemu-user/binfmt path by using a full 32-bit guest OS.

Usage:
  scripts/native-i386-vm-test.sh [options]

Options:
  --workdir DIR           Working directory (default: /tmp/rackup-native-i386-vm)
  --iso-url URL           Debian i386 netinst ISO URL
  --iso-sha256 HEX        Expected SHA256 for the ISO
  --artifact-url URL      Historical 103p1 artifact URL
  --artifact-sha256 HEX   Expected SHA256 for the 103p1 artifact
  --memory MB             Guest RAM in MB (default: 2048)
  --cpus N                Guest vCPU count (default: 2)
  --disk-size SIZE        Guest qcow2 size (default: 16G)
  --mode MODE             Guest run mode: debug or smoke (default: debug)
  --no-kvm                Use TCG instead of KVM
  --skip-install          Reuse an existing installed guest disk and run only the first-boot phase
  --download-only         Fetch inputs and stage assets, but do not boot QEMU
  -h, --help              Show this help

Host dependencies:
  qemu-system-x86_64, qemu-img, curl, sha256sum, xorriso, cpio, gzip, python3

Ubuntu host packages:
  sudo apt install qemu-system-x86 qemu-utils xorriso cpio gzip python3 curl
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 2
  fi
}

download_if_missing() {
  local url="$1"
  local dest="$2"
  if [[ ! -f "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    curl -fsSL "$url" -o "$dest"
  fi
}

verify_sha256() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'SHA256 mismatch for %s\nexpected %s\ngot      %s\n' "$path" "$expected" "$actual" >&2
    exit 2
  fi
}

qemu_accel_args() {
  if [[ "$NO_KVM" -eq 0 ]]; then
    printf '%s\n' "-enable-kvm"
    printf '%s\n' "-cpu"
    printf '%s\n' "host"
  else
    printf '%s\n' "-cpu"
    printf '%s\n' "qemu64"
  fi
}

run_qemu() {
  local args=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && args+=("$line")
  done < <(qemu_accel_args)
  qemu-system-x86_64 "${args[@]}" "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --iso-url)
      ISO_URL="$2"
      shift 2
      ;;
    --iso-sha256)
      ISO_SHA256="$2"
      shift 2
      ;;
    --artifact-url)
      ARTIFACT_URL="$2"
      shift 2
      ;;
    --artifact-sha256)
      ARTIFACT_SHA256="$2"
      shift 2
      ;;
    --memory)
      MEMORY_MB="$2"
      shift 2
      ;;
    --cpus)
      CPUS="$2"
      shift 2
      ;;
    --disk-size)
      DISK_SIZE="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --no-kvm)
      NO_KVM=1
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --download-only)
      DOWNLOAD_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  debug|smoke) ;;
  *)
    printf 'Unknown mode: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

need_cmd curl
need_cmd sha256sum
need_cmd xorriso
need_cmd cpio
need_cmd gzip
need_cmd python3

if [[ "$DOWNLOAD_ONLY" -eq 0 ]]; then
  need_cmd qemu-system-x86_64
  need_cmd qemu-img
fi

if [[ "$DOWNLOAD_ONLY" -eq 0 && "$NO_KVM" -eq 0 && ! -r /dev/kvm ]]; then
  printf '/dev/kvm is not available; rerun with --no-kvm or install/enable KVM.\n' >&2
  exit 2
fi

DOWNLOADS_DIR="$WORKDIR/downloads"
BUILD_DIR="$WORKDIR/build"
SHARE_DIR="$WORKDIR/share"
REPO_COPY_DIR="$SHARE_DIR/repo"
ARTIFACTS_DIR="$SHARE_DIR/artifacts"
OUTPUT_DIR="$SHARE_DIR/output"
ISO_PATH="$DOWNLOADS_DIR/$(basename "$ISO_URL")"
ARTIFACT_PATH="$ARTIFACTS_DIR/$(basename "$ARTIFACT_URL")"
DISK_PATH="$WORKDIR/debian-i386.qcow2"
INSTALL_LOG="$WORKDIR/install-serial.log"
RUN_LOG="$WORKDIR/run-serial.log"
PRESEED_PATH="$BUILD_DIR/preseed.cfg"
VMLINUX_PATH="$BUILD_DIR/vmlinuz"
INITRD_ORIG="$BUILD_DIR/initrd.orig.gz"
INITRD_EXTRA_TREE="$BUILD_DIR/initrd-extra-tree"
INITRD_EXTRA="$BUILD_DIR/initrd.extra.gz"
INITRD_CUSTOM="$BUILD_DIR/initrd.preseeded.gz"
CONFIG_ENV_PATH="$SHARE_DIR/config.env"

mkdir -p "$DOWNLOADS_DIR" "$BUILD_DIR" "$ARTIFACTS_DIR" "$OUTPUT_DIR"
rm -f "$INSTALL_LOG" "$RUN_LOG"
rm -f "$OUTPUT_DIR"/*
cat >"$CONFIG_ENV_PATH" <<EOF
RACKUP_NATIVE_I386_VM_MODE='$MODE'
EOF

download_if_missing "$ISO_URL" "$ISO_PATH"
verify_sha256 "$ISO_SHA256" "$ISO_PATH"
download_if_missing "$ARTIFACT_URL" "$ARTIFACT_PATH"
verify_sha256 "$ARTIFACT_SHA256" "$ARTIFACT_PATH"

rm -rf "$REPO_COPY_DIR"
"$ROOT_DIR/scripts/copy-filtered-tree.sh" "$ROOT_DIR" "$REPO_COPY_DIR"

cat >"$PRESEED_PATH" <<'EOF'
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string rackup-i386
d-i netcfg/get_domain string local
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-password password root
d-i passwd/root-password-again password root
d-i user-setup/allow-password-weak boolean true
d-i passwd/make-user boolean false
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i debian-installer/add-kernel-opts string console=ttyS0,115200n8
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-auto/disk string /dev/vda
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect
d-i pkgsel/include string
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda
d-i finish-install/reboot_in_progress note
d-i preseed/late_command string \
    cp /rackup-native-i386-firstboot.sh /target/usr/local/sbin/rackup-native-i386-firstboot; \
    chmod 0755 /target/usr/local/sbin/rackup-native-i386-firstboot; \
    cp /rackup-native-i386-firstboot.service /target/etc/systemd/system/rackup-native-i386-firstboot.service; \
    in-target systemctl enable rackup-native-i386-firstboot.service
EOF

xorriso -osirrox on -indev "$ISO_PATH" -extract /install.386/vmlinuz "$VMLINUX_PATH" >/dev/null 2>&1
xorriso -osirrox on -indev "$ISO_PATH" -extract /install.386/initrd.gz "$INITRD_ORIG" >/dev/null 2>&1

rm -rf "$INITRD_EXTRA_TREE"
mkdir -p "$INITRD_EXTRA_TREE"
cp "$PRESEED_PATH" "$INITRD_EXTRA_TREE/preseed.cfg"
cp "$ROOT_DIR/vm/native-i386-firstboot.sh" "$INITRD_EXTRA_TREE/rackup-native-i386-firstboot.sh"
cp "$ROOT_DIR/vm/native-i386-firstboot.service" "$INITRD_EXTRA_TREE/rackup-native-i386-firstboot.service"
(
  cd "$INITRD_EXTRA_TREE"
  find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$INITRD_EXTRA"
)
cat "$INITRD_ORIG" "$INITRD_EXTRA" > "$INITRD_CUSTOM"

if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then
  printf 'Prepared native i386 VM assets in %s\n' "$WORKDIR"
  printf 'ISO: %s\n' "$ISO_PATH"
  printf 'Artifact: %s\n' "$ARTIFACT_PATH"
  printf 'Repo copy: %s\n' "$REPO_COPY_DIR"
  printf 'Preseeded initrd: %s\n' "$INITRD_CUSTOM"
  exit 0
fi

if [[ "$SKIP_INSTALL" -eq 1 && ! -f "$DISK_PATH" ]]; then
  printf 'Requested --skip-install, but no guest disk exists at %s\n' "$DISK_PATH" >&2
  exit 2
fi

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  rm -f "$DISK_PATH"
  qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null
  run_qemu \
    -smp "$CPUS" \
    -m "$MEMORY_MB" \
    -name rackup-native-i386-install \
    -drive "file=$DISK_PATH,if=virtio,format=qcow2" \
    -drive "file=$ISO_PATH,media=cdrom" \
    -kernel "$VMLINUX_PATH" \
    -initrd "$INITRD_CUSTOM" \
    -append "auto=true priority=critical console=ttyS0,115200n8" \
    -nic user,model=e1000 \
    -nographic \
    -no-reboot | tee "$INSTALL_LOG"
fi

run_qemu \
  -smp "$CPUS" \
  -m "$MEMORY_MB" \
  -name rackup-native-i386-run \
  -drive "file=$DISK_PATH,if=virtio,format=qcow2" \
  -nic user,model=e1000 \
  -virtfs "local,id=hostshare,path=$SHARE_DIR,security_model=none,mount_tag=hostshare" \
  -nographic \
  -no-reboot | tee "$RUN_LOG"

SUMMARY_PATH="$OUTPUT_DIR/summary.txt"
if [[ ! -f "$SUMMARY_PATH" ]]; then
  printf 'Native i386 VM run did not produce %s\n' "$SUMMARY_PATH" >&2
  exit 1
fi
if ! grep -Fqx 'result=pass' "$SUMMARY_PATH"; then
  printf 'Native i386 VM run failed.\n' >&2
  sed -n '1,200p' "$SUMMARY_PATH" >&2 || true
  exit 1
fi

printf 'Native i386 VM run complete.\n'
printf 'Workdir: %s\n' "$WORKDIR"
printf 'Guest output: %s\n' "$OUTPUT_DIR"
printf 'Install log: %s\n' "$INSTALL_LOG"
printf 'Run log: %s\n' "$RUN_LOG"
printf 'Workdir retained for inspection: %s\n' "$WORKDIR"
