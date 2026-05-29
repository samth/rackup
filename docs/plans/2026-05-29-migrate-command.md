# `rackup migrate` — plan & design notes

Date: 2026-05-29
Issue: #85

## Problem

`raco pkg migrate <from>` does not work for packages installed by a Racket
that rackup does not manage (e.g. a stock `/Applications/Racket vX` on macOS,
or a distro Racket on Linux). It reports `No packages from "X" to install`.

### Root cause

`raco pkg migrate <from>` takes no source location. It reads the old list
from `<addon>/<from>/pkgs/pkgs.rktd` and installs into `<addon>/<current>/pkgs/`,
both derived from the single `(find-system-path 'addon-dir)` (= `PLTADDONDIR`).
Stock Racket shares one addon dir across versions with per-version subdirs.

rackup isolates each toolchain's addon dir at `~/.rackup/addons/<id>` (set as
`PLTADDONDIR` by the shim dispatcher, `shims.rkt`). So a `raco pkg migrate`
run inside a rackup toolchain only ever looks under that toolchain's own
addon dir, which has no `<from>` subdir. The old packages live in the
OS-default addon dir (`~/Library/Racket/<from>/pkgs` on macOS,
`~/.local/share/racket/<from>/pkgs` on Linux), which `migrate` never consults.

Upstream code: `pkg/private/migrate.rkt`, `pkg/path.rkt`
(`get-pkgs-dir`/`read-pkgs-db`), `setup/private/dirs.rkt`
(`find-user-pkgs-dir` → `(build-path (find-system-path 'addon-dir) vers "pkgs")`).

## Manual workaround (documented in the issue, for the reporter)

```bash
ADDON=$(racket -e '(require setup/dirs)(displayln (path->string (find-system-path (quote addon-dir))))')
ln -s "$HOME/Library/Racket/9.1" "$ADDON/9.1"   # expose old packages under rackup's addon dir
raco pkg migrate 9.1
rm "$ADDON/9.1"
```

## Considered approaches for "make it automatic"

1. **Reconstruct the package list and `raco pkg install` by name.** Rejected:
   reimplements migrate's auto-filtering, link/clone/git source
   reconstruction, and dep handling.
2. **Override `PLTADDONDIR` to the old location for the whole run.** Rejected:
   that redirects both source *and* destination, so the migrated packages land
   in the old addon dir, invisible to the rackup toolchain.
3. **Stage the source from-list under the target addon dir, run the real
   `raco pkg migrate`, clean up.** Chosen. Source and destination are both
   correct (dest = rackup addon dir; source = staged `<from>` subdir), and the
   real migrate logic is reused verbatim.
4. **Upstream `raco pkg migrate --from-dir <pkgs-dir>`.** The proper long-term
   fix: let the source be specified independently of the destination addon
   dir. `pkg/path.rkt`'s `read-pkgs-db` already accepts a complete-path scope,
   so `pkg-migrate` could read the from-db from an explicit dir. Documented as
   a follow-up; not required for the rackup command.

## Implementation (this PR)

- `libexec/rackup/migrate.rkt`: `run-migrate!` (existence check → staging via
  `dynamic-wind` → run → cleanup), `detect-native-addon-dir` (probe target
  toolchain's racket with a clean env), `migrate-source-versions`,
  `build-target-env`. Two stubbable seams: `current-native-addon-dir-proc`,
  `current-migrate-system*-proc`.
- `libexec/rackup/main.rkt`: `cmd-migrate` (arg parsing, source resolution).
  Moved `toolchain-runtime-env-vars` to `state.rkt` so `migrate.rkt` and
  `main.rkt` share it.
- `commands-data.rkt`, `pages/site.rkt`: register the command (the latter for
  the CI webpage-coverage check).
- `test/migrate.rkt`: unit tests for version listing, staging + cleanup, env
  setup, error paths, and `cmd-migrate` arg parsing.

CLI:

```
rackup migrate <from-version> [--toolchain <id>]
              [--from-addon <dir> | --from-toolchain <id>]
              [--dry-run] [-- <raco-pkg-migrate-args>...]
```

## Validation

- `raco test -y test/all.rkt`: 316 tests pass.
- Real `--dry-run` against an installed 9.2 toolchain with a synthetic source
  addon: `raco pkg migrate` found the non-auto package, skipped the
  auto-installed one, staging was cleaned up.
- Native auto-detection (no `--from-addon`) probed the toolchain's racket,
  found `~/.local/share/racket`, and listed available versions on a miss.

## Possible follow-ups

- Upstream `raco pkg migrate --from-dir` (approach 4).
- Post-install hint: after `rackup install`, if the OS-default addon dir has
  user packages for a nearby version, suggest `rackup migrate <version>`.
