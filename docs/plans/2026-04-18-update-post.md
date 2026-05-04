# rackup update: per-toolchain compiled files, upgrade command, and more

Outline for a Racket Discourse post updating on rackup changes since the
initial announcement on March 11.

## Per-toolchain compiled files (PLTCOMPILEDROOTS)

The headline feature. Different Racket versions produce incompatible
`.zo` files. Previously, switching toolchains could leave stale compiled
files that caused errors or required manual `raco setup`.

rackup now automatically sets `PLTCOMPILEDROOTS` per toolchain (e.g.,
`compiled/9.1-cs/` vs `compiled/9.2.0.2-cs/`), so switching between
versions just works — no recompilation needed, even with linked packages.

Linked source builds get their own suffix (e.g.,
`compiled/9.1-cs-local-dev/`) so they don't conflict with
installer-built toolchains at the same version.

Existing toolchains are backfilled automatically on the next rackup
command after upgrading.

## `rackup upgrade` command

Upgrade a toolchain in place (e.g., `rackup upgrade stable` to pick up a
new point release).

## macOS fixes

Fixed binary signing for macOS Tahoe (26), which enforces stricter code
signing than previous versions.

## Shell integration improvements

`rackup switch` now only sets `RACKUP_TOOLCHAIN` in your shell;
Racket-specific env vars (`PLTADDONDIR`, `PLTCOMPILEDROOTS`) are scoped
internally to each shim invocation, preventing leakage into non-rackup
commands like `make install` in a source checkout.

## Security hardening

Pinned GitHub Actions to SHAs, scoped permissions, added installer
checksum verification.

## How to upgrade

`rackup self-upgrade`
