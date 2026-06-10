# Deduplication, stdlib, and reusable-abstraction refactor

Date: 2026-06-09

A codebase-wide simplification pass in two phases: (1) eliminate
copy-paste duplication, (2) replace hand-rolled code with Racket
standard-library equivalents and extract cross-cutting patterns into
reusable helpers (in the spirit of `lock.rkt`'s `define-file-lock`).

## Phase 1: deduplication

- `ensure-installer-cached!` and its cache-path helper existed nearly
  verbatim in both `install.rkt` and `runtime.rkt`. Now one copy in
  `installer-backend.rkt` with an `#:announce` hook for the differing
  progress messages.
- The env.sh writer/deleter pair was duplicated between `install.rkt`
  and `shims.rkt`. The `shims.rkt` version (which skips rewriting
  unchanged files) is the only one left, plus
  `sync-toolchain-env-file!` replacing the write-or-delete conditional
  repeated at three call sites.
- `toolchain-runtime-env` (install.rkt) and `toolchain-runtime-env-vars`
  (main.rkt) were identical; now one function in `state.rkt`, along
  with `toolchain-env-var-entries` (the PLTADDONDIR/PLTCOMPILEDROOTS
  entry construction, previously written out in both `install.rkt` and
  `shims.rkt`) and `env-vars->meta`.
- `scripts/install.sh` had ~140 lines of copy-pasted binary-install
  logic between the GitHub-CI-artifact path and the published-binary
  path; both now call `install_binary_distribution()` (which also
  brings the macOS ad-hoc codesign step to the CI-artifact path, fixing
  a gap). Also extracted: `extract_tarball_dir()` (three sites),
  `download_stdout()`, `reshim_and_store_checksum()`; the inline
  `copy_filtered_tree` now invokes the bundled
  `scripts/copy-filtered-tree.sh` (the source tarball ships it for
  exactly this step).
- `bin/rackup`'s two save-and-unset Racket-env blocks became one
  helper; removed the dead `rackup_run_core` function and the vestigial
  `PLTHOME` save (nothing restores `_RACKUP_ORIG_PLTHOME`).
- The `_rackup_toolchains` shell function duplicated across the bash
  and zsh completion templates is now a shared include
  (`templates/toolchains-fn.scrbl`).
- `test/state-shims.rkt` (2662 → 2488 lines): `write-fake-exe!`
  replaces ~45 write+chmod pairs; `test-toolchain-meta` replaces ~19
  verbose metadata hash literals and the four locally-reinvented
  register helpers.

## Phase 2: stdlib replacements and reusable abstractions

Standard library:

- `rktd-io.rkt` reimplemented `call-with-atomic-output-file`; it now
  delegates to the `racket/file` version, keeping the
  permission-preservation behavior (which the stdlib version lacks and
  tests rely on) as a thin wrapper, `write-file-atomically`.
- `split-on-double-dash` uses `splitf-at`; `usage-line` uses
  `~a #:min-width`; the Chez-executable scoring in `install.rkt` uses
  `argmax` (over a path-sorted list to keep the deterministic
  tiebreak).
- Checked but rejected: `version/utils` for `versioning.rkt` (rackup
  must order PLT Scheme versions like `103`/`372` that `valid-version?`
  rejects); `net/head`'s `extract-field` (headers arrive as a list of
  byte strings from `http-sendrecv`, not a header block); `fold-files`
  for `for-each-named-subdir` (the explicit walk is clearer than
  encoding prune-on-match in fold-files' descend protocol).

New reusable abstractions:

- `error.rkt`: `try-or` — `(try-or default body ...)` for the
  pervasive swallow-exn:fail-and-return-default pattern; 20 simple call
  sites converted (sites whose handlers log or inspect the exception
  keep explicit `with-handlers`).
- `fs.rkt`: `delete-path!` (link/file/directory, no-op when absent) and
  `dir-or-link-exists?`.
- `process.rkt`: `call-with-env-overlay` (copied-environment overlay
  for subprocess calls; used by `capture-program-output`, package
  migration, and self-upgrade), and `run-quiet-program` (moved from
  `runtime.rkt`).
- `text.rkt`: `yes-answer?` for interactive `[y/N]`/`[Y/n]` prompts.

## Test-suite coverage fix

`test/all.rkt` required each test file's *main* module, but every test
file wraps its checks in `(module+ test ...)` — so `raco test
test/all.rkt` (what CI runs) executed only top-level checks: 316 of
what are actually 955 tests. `all.rkt` now requires the `test`
submodules. Latent bugs this exposed, all fixed:

- `install.rkt` and `shell.rkt` used `#lang at-exp`, violating
  `test/remote.rkt`'s no-at-exp-in-client-code invariant; both
  converted to plain `racket/base` with byte-identical generated
  output.
- A `test/state-shims.rkt` test restored originally-unset env vars with
  `(putenv name "")`; `putenv` cannot unset, so `PLTUSERHOME` was left
  as the empty string, making `(find-system-path 'home-dir)` return `/`
  for the rest of the process and breaking `test/uninstall.rkt`'s
  safety checks. It now poisons a copied environment via
  `parameterize` instead.
- `test/rktd-io.rkt` called `compile` relying on the namespace `raco
  test` happens to install; it now uses `make-base-namespace`.
- `test/version.rkt` called `cmd-version` without its argument.
