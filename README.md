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
curl -fsSL https://samth.github.io/rackup/install.sh | sh
```

Noninteractive:

```bash
curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y
```

Local bootstrap script (same script served via Pages):

```bash
sh scripts/install.sh
```

It supports `-y` for noninteractive installs and prompts before shell config edits by default.
The bootstrap installs a hidden internal Racket runtime for `rackup` itself, but does not
install a user toolchain automatically. The first user toolchain install is explicit, e.g.:

```bash
rackup install stable --set-default
```

## GitHub Pages Installer Site

The repo includes a GitHub Pages workflow that publishes a small install page and serves:

- `/` (landing page with copy/paste commands)
- `/install.sh` (bootstrap script for `curl | sh`)
- `/install` (alias)

Workflow file: `.github/workflows/pages.yml`

## Docker E2E (Fresh Container)

To test `rackup` installing a Racket toolchain in a fresh Linux container:

```bash
scripts/docker-test-fresh-install.sh
```

This builds a Docker image (`ubuntu:24.04` + distro `racket`) and then runs an
end-to-end smoke test in a disposable container with an empty `RACKUP_HOME`.

`rackup` bootstraps without a host Racket by installing a hidden internal
runtime first. The default Docker E2E image includes system `racket`
because several test modes exercise direct (non-bootstrap) execution.

Useful variants:

```bash
# Test the bootstrap script path too (copies repo into a fresh prefix first)
scripts/docker-test-fresh-install.sh --mode bootstrap

# Also test pre-release install (network-dependent and slower)
scripts/docker-test-fresh-install.sh --spec stable --spec pre-release

# Snapshot test from a specific site
scripts/docker-test-fresh-install.sh --spec snapshot --snapshot-site utah
```
