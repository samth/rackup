# Linked-toolchain compiled roots: drop the `.` fallback

Date: 2026-09-15

Status: proposed

Linked (source) toolchains currently set
`PLTCOMPILEDROOTS=compiled/<variant>-local-<name>:.` — a per-installation
keyed subdir plus a `.` fallback to the tree's default `compiled/`. The
`.` fallback silently reaches into whatever version last wrote the
default dir, which for a source tree drifts constantly. When that
version differs from the running toolchain, Racket errors with a hard
`version mismatch` at load time. This plan replaces the keyed-plus-fallback
scheme for **linked** toolchains with a single keyed root, recorded in
the tree's `config.rktd` so every invocation path agrees, and eliminates
the fallback entirely. Installer toolchains are unchanged.

## Problem

Reported symptom: after `rackup rebuild` on a locally-built checkout,
`racket` either ran the wrong version or "didn't work." Two independent
causes were found; the wrong-version cause (a worktree parked on the
wrong branch) is separate. This plan addresses the second: a linked
toolchain loading `.zo` files built by a *different* version.

Mechanism (all verified against the real binary, not the shim):

1. `PLTCOMPILEDROOTS=compiled/cs-local-<name>:.` yields
   `current-compiled-file-roots = (compiled/cs-local-<name> .)`. Reads
   try the keyed dir first, then fall back to `.` (the default
   `compiled/`).
2. `raco setup` **skip-copies**: when a module is already current in the
   `.` (default) dir, it does not rewrite it into the keyed dir. So core
   collections end up living only in the default dir (observed:
   `collects/racket/compiled/base_rkt.zo` present in the default dir,
   absent from `compiled/cs-local-plt/`). The keyed dir is therefore
   **incomplete**, and the fallback is load-bearing.
3. The default dir is written by any *non-shim* invocation — bare `make`,
   a direct `racket`/`raco`, or another version entirely — and its
   version drifts with the source.
4. On a plain run, a version-mismatched `.zo` found via `.` is a **hard
   error**, not a silent use and not an auto-recompile:

   ```
   loading code: version mismatch
     expected: "9.2"   found: "9.3.0.8"
     in: .../ ./compiled/m_rkt.zo
     possible solution: running `racket -y`, `raco make`, or `raco setup`
   ```

5. With **no** `.` and a missing keyed `.zo`, the same run compiles from
   source instead (`'from-source`, exit 0) — no error, even with a
   wrong-version `.zo` sitting in the (now unreferenced) default dir.

## Why not the alternatives

- **Native (`(same)`, no key).** Rejected. The key isolates *user*
  bytecode wherever it is compiled, not just the source tree.
  `raco make /tmp/foo.rkt` writes `/tmp/compiled/...`; without a key,
  every toolchain shares it, so compiling under one version and running
  under another reproduces the exact mismatch on the user's own files.
- **Keep `.` for linked toolchains.** Rejected. `.` is safe only where
  the default dir cannot hold a foreign version. For a source tree it
  always can (bare `make`, skip-copy, branch drift). Keeping `.` at build
  time is also what causes skip-copy to leave the keyed dir incomplete.
  To get a complete keyed dir you must build with keyed-only anyway, so
  keeping `.` only at runtime buys nothing for the tree and re-exposes the
  error for user code compiled elsewhere. `racket -y` self-heals a
  mismatch (recompiles into the keyed first-root) but that is per-invocation
  discipline, and recompiling core collections at startup is slow.
- **Installer toolchains keep `.`.** Their default dir holds the shipped
  `.zo` at a stable version that never drifts, so the fallback is always a
  version match and is pure reuse. Dropping it would pointlessly recompile
  the whole distribution. No change for them.

## Design

For a **linked** toolchain (`kind=local`, `distribution=in-place`,
`.git` present):

1. **Single keyed root, no fallback.** `compiled-roots-value` returns
   just `compiled/<variant>-local-<name>` (no appended `same`/`.`) for a
   migrated linked toolchain. On-disk layout is unchanged from today
   (relative root ⇒ `<dir>/compiled/<key>/compiled/<mod>_rkt.zo`).
2. **Write it into the tree's `config.rktd`.** `rackup link`/`rebuild`
   writes `compiled-file-roots = ("compiled/<variant>-local-<name>")`
   into `<plthome>/etc/config.rktd`, preserving all other keys. This
   makes bare `make`, direct `raco`/`racket`, and the shim all agree on
   one root without a fallback. (Verified: `config.rktd`'s
   `compiled-file-roots` is honored with no env var; and `make` preserves
   it — `lib.zuo:raco-setup-prepare-to-here` reads and carries it into the
   build copy, and `pkgs-config.rkt` only writes fresh when the file is
   absent, with `update-stamp-if-auto` round-tripping the full hash.)
3. **Shim env matches.** env.sh emits the same single keyed root (no
   `.`). We still emit it explicitly rather than relying on `config.rktd`
   alone, because `config.rktd` can be recreated fresh (e.g. after being
   deleted) as a catalog-only hash without `compiled-file-roots`; the
   explicit env value guarantees the keyed root regardless. `config.rktd`
   covers the paths that never see the env (`make`, direct `raco`).

Installer toolchains: `compiled-roots-value` keeps returning
`compiled/<version>-<variant>:.` and no `config.rktd` is written.

### Why both `config.rktd` and env

The env var overrides `config.rktd`, so the shim is governed by env; but
`make` and direct `raco` never see the env, so they need `config.rktd`.
Writing both, with the same single root, makes all three paths consistent
and removes the fallback everywhere.

## Implementation

- `libexec/rackup/state.rkt`
  - `compiled-roots-value` (currently line ~192): add a linked-migrated
    branch that returns the bare key (no `same` appended, no existing
    roots concatenated). Guard against double-prepend when the existing
    roots already equal the key.
  - Keep the installer branch (`compiled/<version>-<variant>` + fallbacks)
    unchanged.
- `libexec/rackup/shims.rkt`
  - `compute-local-env-vars` (line ~406): consult the per-toolchain
    "migrated" flag (see Migration) to decide keyed-only vs legacy `:.`.
- `libexec/rackup/install.rkt`
  - `toolchain-env-var-entries` / `compiled-roots-value` callers
    (lines ~445, ~467, ~977): thread the migrated flag / linked-ness.
  - `remove --clean-compiled` scan (lines ~966–1007): extend so a
    cleanup can also remove the now-dead default `compiled/` output and
    pre-`8a923dd` version-keyed graveyard dirs for a linked tree.
- New helper (state.rkt or a small `config-rktd.rkt`): read-modify-write
  `<plthome>/etc/config.rktd`, setting `compiled-file-roots` while
  preserving every other key; refuse to clobber a user's pre-existing
  non-default `compiled-file-roots` (warn instead).
- `libexec/rackup/main.rkt`
  - `cmd-rebuild` (line ~788) and `cmd-link`: on a linked in-place git
    checkout, write `config.rktd`, set the migrated flag, then build.
  - `cmd-reshim`/`cmd-init`/self-upgrade paths: do **not** flip an
    unmigrated linked toolchain (see Migration).

## Migration

env.sh is regenerated on every reshim (`init`, `install`, `link`,
`rebuild`, `reshim`, self-upgrade). Flipping the value on a bare reshim
would drop the fallback while the keyed dir is still incomplete, degrading
the toolchain (recompile-from-source on every run) with no warning. To
avoid a degraded window:

- **Gate the flip to `rackup rebuild`/`link`.** Those do a full build,
  which populates a complete keyed dir, writes `config.rktd`, sets a
  per-toolchain `compiled-roots-scheme: 'keyed-only` flag in meta, and
  emits the keyless env — atomically. No degraded window.
- **`reshim`/`self-upgrade` keep emitting the legacy `:.`** for a
  linked toolchain whose flag is unset. Status quo until the user
  rebuilds.
- **One-time notice** on upgrade for linked toolchains: "run
  `rackup rebuild <tc>` to isolate compiled output and remove the
  cross-version fallback."
- **Cleanup** (opt-in, e.g. via `remove --clean-compiled` or a dedicated
  step): delete the dead default `compiled/` output and old version-keyed
  graveyard dirs once migrated.

Impact summary:

- Installer/prebuilt-only users: **zero** impact (byte-identical env).
- Linked-toolchain users: one full `rackup rebuild` per toolchain, which
  they do routinely; with the gating above there is no degraded window and
  no forced action. No **new** hard failures — dropping `.` can only turn
  a fallback mismatch into compile-from-source. Anyone already mid-drift
  is broken today regardless; a rebuild fixes them.
- Side effects: `config.rktd` now steers direct `make`/`raco` in the tree
  to the keyed dir (intended; may surprise non-rackup tooling that assumed
  the default `compiled/`). Old default/graveyard dirs become dead disk
  until cleaned. Previously-reused same-version `.zo` in shared dirs
  (`/tmp`, projects) recompile once into the per-toolchain keyed subdir.

## Testing

- Unit (`test/`, accessed via the eval-on-namespace pattern):
  - `compiled-roots-value`: linked-migrated ⇒ bare key, no `same`, no
    dup when existing roots already equal the key; linked-unmigrated ⇒
    legacy `:.`; installer ⇒ unchanged.
  - `config.rktd` writer: sets `compiled-file-roots`, preserves other
    keys, refuses to clobber a custom value.
- Behavior (real binary, per project rule — not the shim):
  - keyed-only + missing `.zo` ⇒ compiles from source, no error.
  - keyed-only + wrong-version `.zo` only in the (unreferenced) default
    dir ⇒ no error.
  - two linked toolchains compiling the same `/tmp` file ⇒ distinct keyed
    subdirs, neither errors.
- E2E (`test/docker-test-fresh-install.sh`): a link + rebuild + switch +
  bare-`make` sequence on a source checkout, asserting no `version
  mismatch` and that `make` and the shim share one dir.
- Migration: an unmigrated linked toolchain keeps `:.` across a bare
  reshim; a `rebuild` flips it to keyed-only with a complete keyed dir.

## Decisions

- **Default on.** `rackup link`/`rebuild` on a local in-place git
  checkout applies the keyed-only scheme automatically; no flag required.
  That is the case that breaks, so it is the default.
- **Never remove build output implicitly.** The dead default `compiled/`
  and pre-`8a923dd` version-keyed graveyard dirs are left in place on
  migration. Cleanup is opt-in only — via `remove --clean-compiled`, or
  when the user explicitly asks. rackup never deletes them on its own.
- Meta flag for the migrated state: `compiled-roots-scheme`, value
  `'keyed-only` for a migrated linked toolchain; absent/legacy ⇒ the
  current `:.` behavior.
