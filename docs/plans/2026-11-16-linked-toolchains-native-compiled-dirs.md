# Linked toolchains use plain `compiled/` (2026-11-16)

## Decision

A linked source toolchain (`rackup link`) gets no `PLTCOMPILEDROOTS` and no
`compiled-file-roots` entry in the checkout's config.rktd. The shim,
`rackup run`, `rackup rebuild`, the checkout's own `make`, its own
`bin/racket`, and direct `raco` all read and write the default `compiled/`
dirs. Nothing in rackup deletes `.zo` files.

This replaces the keyed designs of #96 (`compiled/cs-local-<name>:.`), #98
(keyed-only, also written into config.rktd), and the open PRs #99, #100 and
#111 (`compiled/cs-local-<name>/@(version):.`, plus purging keyed dirs after
a build). Installer toolchains keep their `compiled/<version>-<variant>:.`
roots unchanged.

## Why

Racket's in-place build compiles only into the default `compiled/` dirs: its
setup runs with the installation's own config dirs and ignores
`PLTCOMPILEDROOTS`. Any second root for code that the build compiles has to
go wrong one of two ways:

- **Double compilation.** The shim's root holds a second copy of the tree's
  and packages' `.zo`, which `make` never refreshes. A real-build test showed
  a no-op `make` followed by the shim recompiling the shim-installed packages.
- **Shadowing.** At the same version, the stale keyed copy is found first, so
  the shim runs older code than the tree's own binary. After a version bump,
  a version-less key gives `version mismatch`.

Purging keyed dirs after each build (the fix tried on #111) removes the
shadowing, but forces recompiles that take tens of minutes to an hour for a
full `raco setup`. That is not acceptable.

In a real-build lab run of this design (scenario S10, 114/114 checks), there
was no double compilation and no shadowing, and mixing the shim with direct
use of the checkout worked.

## What it costs

Project code outside the checkout that is used with both a linked checkout
and another toolchain shares one `compiled/` dir:

1. Switching between a release and a linked checkout on the same project.
   The release writes its own keyed dir, but both fall back to `.`, where
   the linked checkout's `.zo` live, so either can load the other's `.zo`.
2. A checkout's version bump leaves the project's `.zo` stale until
   `raco make` is run again.
3. Two linked checkouts share the project's `compiled/` and user-scope
   packages (every in-place checkout uses the "development" installation
   name, so they share `~/.local/share/racket/development`). This is the main
   remaining problem.

Each of these is a `version mismatch` error fixed by `raco make` (or
`raco setup` for packages) with the toolchain in use. None leaves the
checkout itself broken.

## Upgrade

Reshim, link, and rebuild remove a keyed-only config.rktd entry left by #98
(only when it equals exactly the toolchain's key) and rewrite env.sh without
`PLTCOMPILEDROOTS`. Keyed dirs left by earlier rackup versions are not read
any more and are not deleted automatically; `rackup remove --clean-compiled`
removes the ones under user-scope packages.

The shim dispatcher now drops a `PLTCOMPILEDROOTS` equal to
`_RACKUP_MANAGED_PLTCOMPILEDROOTS` before sourcing env.sh, so a linked
toolchain launched from inside another toolchain's process does not inherit
that toolchain's roots. A value the user set is still kept.

## Follow-ups under discussion

- A per-checkout compiled root for project code only (a symlink farm keyed
  per checkout), opt-in.
- Racket changes: a root list that applies only to code outside the package
  system (R2), a per-installation user scope (R4), and treating a
  wrong-version `.zo` as absent (R1). See issue #101.
