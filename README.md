# rackup

A Racket toolchain manager

## Status

Linux-first v1 scaffold implemented in Bash + Racket with:

- `rackup` CLI (`install`, `list`, `default`, `shell`, `run`, `which`, `current`, `remove`, `reshim`, `init`, `doctor`)
- state + metadata under `~/.rackup` (or `RACKUP_HOME`)
- dynamic shims and shell integration for bash/zsh
- release / pre-release / snapshot installer resolution via Racket metadata endpoints (`table.rktd`, `version.rktd`, `version.txt`)
- Linux installer orchestration for official `.sh` installers

## Local Usage

```bash
./bin/rackup help
./bin/rackup doctor
./bin/rackup init --shell bash
./bin/rackup install stable --set-default
```

## Bootstrap

Bootstrap script (designed for `curl | sh`):

```bash
bash scripts/install.sh
```

It supports `-y` for noninteractive installs and prompts before shell config edits by default.

## Docker E2E (Fresh Container)

To test `rackup` installing a Racket toolchain in a fresh Linux container:

```bash
scripts/docker-test-fresh-install.sh
```

This builds a Docker image (`ubuntu:24.04` + distro `racket`) and then runs an
end-to-end smoke test in a disposable container with an empty `RACKUP_HOME`.

Why the image includes system `racket`: current `rackup` is implemented in
Bash + Racket, so it needs a host Racket to run the manager itself while it
installs the target toolchain.

Useful variants:

```bash
# Test the bootstrap script path too (copies repo into a fresh prefix first)
scripts/docker-test-fresh-install.sh --mode bootstrap

# Also test pre-release install (network-dependent and slower)
scripts/docker-test-fresh-install.sh --spec stable --spec pre-release

# Snapshot test from a specific site
scripts/docker-test-fresh-install.sh --spec snapshot --snapshot-site utah
```
