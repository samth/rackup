# Native i386 VM Test

This document describes the disposable VM path for testing very old PLT
toolchains, such as `103p1`, without relying on the host's `qemu-i386`
`binfmt_misc` handler.

## Why this exists

On the current host, 32-bit ELF binaries are intercepted by
`/proc/sys/fs/binfmt_misc/qemu-i386`. That means:

- direct host execution is not native
- Docker execution is not native either
- results for `103` and `103p1` are polluted by qemu-user

The VM harness avoids that by booting a full `i386` guest OS under KVM.

## Host requirements

On Ubuntu, install:

```sh
sudo apt install qemu-system-x86 qemu-utils xorriso cpio gzip python3 curl
```

The host also needs:

- `/dev/kvm`
- outbound network access for the Debian installer and guest `apt`

## What the script does

`test/native-i386-vm-test.sh` performs these steps:

1. Download the official Debian 12.13.0 `i386` netinst ISO.
2. Verify the ISO checksum.
3. Download the historical `plt-103p1-bin-i386-linux.tgz` artifact.
4. Verify the artifact checksum.
5. Create a filtered copy of the current repo, excluding `.zo`, `.dep`, and
   `compiled/`.
6. Build a preseeded Debian installer initrd.
7. Install a disposable `i386` Debian guest onto a qcow2 disk.
8. Boot the installed guest with a 9p host share.
9. In the guest, install `racket` and `file`, run `rackup install 103p1`,
   execute `mzscheme`, capture the transcript, and power off.

The host share captures:

- `install.stdout`
- `install.stderr`
- `list.stdout`
- `list.stderr`
- `mzscheme.stdout`
- `mzscheme.stderr`
- `summary.txt`
- `guest.log`

## CI usage

The CI job uses `test/ci-native-i386-vm-smoke.sh`, which:

- runs the harness in `--mode smoke`
- forces `--no-kvm` so it works on GitHub-hosted runners
- caches the Debian ISO and historical `103p1` artifact
- caches the installed qcow2 guest disk

The guest smoke path intentionally installs only the minimum Debian packages it
needs to run `rackup`:

- `racket`
- `file`
- `util-linux`

and does so with `--no-install-recommends` to avoid pulling in large GUI/doc
dependencies.

## Usage

```sh
test/native-i386-vm-test.sh
```

Useful options:

```sh
test/native-i386-vm-test.sh --download-only
test/native-i386-vm-test.sh --workdir /tmp/rackup-native-i386-vm
test/native-i386-vm-test.sh --skip-install
test/native-i386-vm-test.sh --no-kvm
```

## Current default inputs

ISO:

```text
https://cdimage.debian.org/cdimage/archive/12.13.0/i386/iso-cd/debian-12.13.0-i386-netinst.iso
```

ISO SHA256:

```text
61e5dbec68c511713611ffec58e40ba26c76487864b7dddfc59f8e55bacbe56a
```

Historical artifact:

```text
http://download.plt-scheme.org/bundles/103p1/plt/plt-103p1-bin-i386-linux.tgz
```

Historical artifact SHA256:

```text
7090e2d7df07c17530e50cbc5fde67b51b39f77c162b7f20413242dca923a20a
```

## Notes

- This path is intended to answer a specific question: whether `103p1` works in
  a real `i386` guest without host `qemu-user` interception.
- The script currently targets Debian 12 `i386` because it is still available
  from official Debian archives and is recent enough to automate reliably.
- If you need an older guest OS, reuse the same structure but swap the ISO URL
  and preseed mirror settings.
