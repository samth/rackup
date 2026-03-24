# Plan: `rackup upgrade` Command

## Context

Users install Racket toolchains via channels (`stable`, `pre-release`, `snapshot`). When a new version is released on a channel, there's currently no way to upgrade — users must manually install the new version and remove the old one. The `rackup upgrade` command automates this: resolve the latest version for each channel, install it, migrate user packages, and remove the old toolchain.

Additionally, this work includes producing a document proposing improvements to `raco pkg migrate` to better support toolchain managers like rackup.

## Design Decisions

- `rackup upgrade` (no args): upgrade all channel-based toolchains (stable, pre-release, snapshot)
- `rackup upgrade <spec>`: upgrade only toolchains matching that channel
- Version-pinned installs (kind = `release`, e.g. `rackup install 8.18`) are never upgraded
- Old version is auto-removed after successful upgrade
- User-scoped packages are migrated via list + reinstall (closest to what `raco pkg migrate` does internally)
- `--force` flag: reinstall even if up to date

## Key Constraint: Toolchain IDs Include Version

Canonical IDs embed the resolved version: `release-9.1-cs-x86_64-linux-full`. Upgrading stable from 9.1→9.2 produces a *different* ID. So upgrade = install new + migrate packages + transfer default + remove old.

## Files to Modify

### `libexec/rackup/install.rkt`
- Add `upgrade-toolchain!` function — core per-toolchain upgrade logic
- Add `upgrade-all-toolchains!` function — iterate installed toolchains, filter upgradeable, call `upgrade-toolchain!` for each
- Add `migrate-user-packages!` helper — runs `raco pkg show` on old toolchain, `raco pkg install` on new
- Add `run-raco-for-toolchain` helper — runs a raco command with the correct env (PLTADDONDIR, bin path) for a specific toolchain ID

### `libexec/rackup/main.rkt`
- Add `cmd-upgrade` function — parse CLI args, call upgrade functions
- Add dispatch clause: `[(list "upgrade" rest ...) (cmd-upgrade rest)]`
- Add upgrade to the usage/help text

### `libexec/rackup/state.rkt`
- May need a helper to find all toolchains matching a kind (e.g., all `'stable` toolchains). Currently `find-local-toolchain` finds one by name; we need to filter by `kind`.

### `docs/raco-pkg-migrate-improvements.md` (new file)
- Document proposing `--from-dir` flag for `raco pkg migrate`
- Explain the problem: `raco pkg migrate <version>` computes addon dir path from version number, which doesn't work when `PLTADDONDIR` overrides the standard layout
- Propose solution and use cases

## Implementation Steps

### Step 1: Add helper to find upgradeable toolchains

In `state.rkt`, add a function that returns toolchains filtered by kind:

```racket
(define (upgradeable-toolchains [filter-kind #f])
  ;; Returns list of (id . meta) for toolchains with kind ∈ {stable, pre-release, snapshot}
  ;; If filter-kind is given, further filter to that kind
  )
```

Uses existing: `installed-toolchain-ids`, `read-toolchain-meta` (state.rkt), `load-index` (state.rkt).

### Step 2: Add upgrade core logic in `install.rkt`

```racket
(define (upgrade-toolchain! id meta opts)
  ;; 1. Extract kind, variant, distribution, arch, snapshot-site from meta
  ;; 2. Determine the spec to resolve:
  ;;    - stable → "stable"
  ;;    - pre-release → "pre-release"
  ;;    - snapshot → "snapshot" or "snapshot:<site>"
  ;; 3. Call resolve-install-request with same variant/distribution/arch
  ;; 4. Compare versions:
  ;;    - stable/pre-release: cmp-versions on resolved-version
  ;;    - snapshot: string compare on snapshot-stamp
  ;; 5. If newer or --force:
  ;;    a. Record whether old is default (get-default-toolchain)
  ;;    b. Install new via install-toolchain! with matching options
  ;;    c. Migrate packages (migrate-user-packages! old-id new-id)
  ;;    d. If old was default, set-default-toolchain! new-id
  ;;    e. remove-toolchain! old-id
  ;; 6. If up to date: print message
  )
```

Uses existing: `resolve-install-request` (remote.rkt), `cmp-versions` (versioning.rkt), `install-toolchain!` (install.rkt), `remove-toolchain!` (install.rkt), `get-default-toolchain` / `set-default-toolchain!` (state.rkt).

### Step 3: Add package migration helper

```racket
(define (migrate-user-packages! old-id new-id)
  ;; 1. Determine old raco path: (rackup-toolchain-bin-link old-id)/raco
  ;; 2. Determine old PLTADDONDIR: (rackup-addon-dir old-id)
  ;; 3. Run: PLTADDONDIR=<old-addon> <old-raco> pkg show --user --name-only
  ;;    → parse output to get list of package names
  ;; 4. If no packages, skip
  ;; 5. Determine new raco path and new PLTADDONDIR
  ;; 6. Run: PLTADDONDIR=<new-addon> <new-raco> pkg install --auto <packages...>
  ;; 7. If install fails, warn but don't abort
  )
```

Uses existing: `rackup-addon-dir` (paths.rkt), `rackup-toolchain-bin-link` (paths.rkt), `toolchain-env-vars` (state.rkt).

Note: `raco pkg show` output format and the exact flags needed will need to be verified during implementation. The `--auto` flag on install handles dependencies automatically.

### Step 4: Add `cmd-upgrade` in `main.rkt`

```racket
(define (cmd-upgrade rest)
  (define force? #f)
  (define no-cache? #f)
  (define spec
    (command-line #:program "rackup upgrade"
                  #:argv rest
                  #:once-each
                  [("--force") "Reinstall even if up to date" (set! force? #t)]
                  [("--no-cache") "Re-download installer" (set! no-cache? #t)]
                  #:args maybe-spec
                  (if (null? maybe-spec) #f (car maybe-spec))))
  ;; Find upgradeable toolchains, optionally filtered by spec
  ;; For each, call upgrade-toolchain!
  ;; Print summary
  )
```

Add to dispatch table and usage text.

### Step 5: Write `raco pkg migrate` improvements document

Create `docs/raco-pkg-migrate-improvements.md` covering:
- Problem: `raco pkg migrate <version>` constructs the source addon dir path from the version number, assuming standard Racket directory layout. When `PLTADDONDIR` is set (as in rackup, or any custom installation), there's no way to specify a different source directory.
- Proposed improvement: `--from-dir <path>` flag that accepts an explicit addon directory as the source for migration.
- Usage example: `PLTADDONDIR=<new> raco pkg migrate --from-dir <old-addon-dir>`
- Additional consideration: `--from-catalog` or reading the package database directly from a specified path.

### Step 6: Unit tests

Add `test/upgrade.rkt`:
- Test `upgradeable-toolchains` filtering logic
- Test version comparison decision (should-upgrade? logic) for stable, pre-release, snapshot
- Test that `--force` bypasses version check
- Test that spec argument filters correctly
- Test package list parsing from `raco pkg show` output
- Mock `resolve-install-request` to return controlled versions

### Step 7: Docker E2E test

Extend `test/docker-test-fresh-install.sh` or add a new docker test script:
- Install a specific older version (e.g., `rackup install 8.17`)
- Make it the default, install a user package
- Run `rackup upgrade`
- Verify: new version installed, old version removed, default transferred, user package present

## Verification

1. **Unit tests**: `raco test -y test/upgrade.rkt`
2. **All unit tests**: `raco test -y test/all.rkt`
3. **Shell lint**: `shellcheck --severity=warning bin/rackup` and `shfmt -d -i 2 -ci bin/rackup`
4. **Docker E2E**: Run the upgrade docker test with `--mode bootstrap --spec 8.17` then verify upgrade to stable
5. **Manual smoke test**: `rackup install stable`, `rackup upgrade` (should report "up to date"), `rackup upgrade --force` (should reinstall)
