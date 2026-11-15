# Real-build test matrix for linked toolchains (2026-11-14)

Goal: before merging #99, #100 and #111, check against real Racket builds
that a linked source checkout stays usable through version bumps, whether
the user rebuilds with `rackup rebuild` or with plain `make`, with
packages installed in every scope and mode, and with files outside the
tree that several Racket versions compile.

The unit tests (`test/stale-zo.rkt`, `test/env-consistency.rkt`) plant
`.zo` files with patched headers.  This matrix uses real builds of
samth/racket at three consecutive versions:

| Name | Commit    | Version |
|------|-----------|---------|
| V1   | `c39f716` | 9.4.0.3 |
| V2   | `b24e301` | 9.4.0.4 |
| V3   | `9bc6152` | 9.4.0.5 |

Builds use `make -j4 CPUS=4 PKGS="compiler-lib rackunit-lib"`: the same
in-place build path as a full `make`, with a package set small enough to
rebuild many times.  It still covers in-tree packages (`pkgs/`, linked at
installation scope) and catalog packages (`racket/share/pkgs`).

## Method

Every command runs through a harness (`lab.py`) that records, in order:

1. the expectation, in prose and as machine checks, written before the run;
2. the command, the actor, the working directory;
3. exit code, duration, full output;
4. a state snapshot after the command and the `.zo` inventory diff against
   the snapshot before it;
5. a verdict per check (MATCH or MISMATCH).

### State snapshot

- git: HEAD, version in `racket_version.h`, number of dirty paths.
- binary: what `racket/bin/racket --version` reports.
- `racket/etc/config.rktd` (rackup must leave no `compiled-file-roots`).
- rackup: toolchain `meta.rktd`, `env.sh`, default, shim list.
- `.zo` inventory, per file class and per compiled root: number of `.zo`,
  the version in each `.zo` header, how many are older than their source
  (mtime), how many record a source SHA-1 in the `.dep` that no longer
  matches the source, how many have no source.

File classes: `collects` (racket/collects), `tree-pkgs` (pkgs/),
`share-pkgs` (racket/share/pkgs), `native-addon` (~/.local/share/racket),
`rackup-addons` (~/.rackup/addons), `work` (clones, link packages and
scratch files outside the tree).

Compiled roots are named by path: `compiled` is the default root,
`compiled/cs-local-lab/9.4.0.3/compiled` the keyed root of toolchain `lab`
at 9.4.0.3, `compiled/cs-local-lab/compiled` the version-less keyed root
that main's rackup writes.

### Actors

| Actor    | How racket is started                           | Compiled roots |
|----------|--------------------------------------------------|----------------|
| `direct` | `<tree>/racket/bin/racket`, clean environment   | config.rktd, else `compiled` |
| `shim`   | `~/.rackup/shims/racket`                         | `compiled/cs-local-lab/@(version)` then `.` |
| `run`    | `rackup run lab -- racket`                       | same as shim |
| `make`   | plain `make` in the checkout                     | as `direct` |
| `rebuild`| `rackup rebuild lab`                             | make as `direct`, addon dir as shim |

### Probes

Read-only probes run `racket -t trace.rkt ...`, where `trace.rkt` wraps
`current-load` and logs every file the load handler is given.  Each probe
records, per actor, the exit code, the output, how many `.zo` came from
which root at which version, and every module loaded from source.  A
healthy state means exit 0, the expected output, and no load from source
except where the expectation names one.

## Expected behaviour (the contract under test)

C1. No actor ever fails with a version mismatch on a file that actor, or a
    build step, could have recompiled.  A rackup-managed root never holds a
    `.zo` that a newer binary can reach.
C2. After `rackup rebuild` or plain `make` succeeds, `direct`, `shim` and
    `run` all load the tree's collections and installation-scope packages
    from `.zo` of the new version, none from source.
C3. Using rackup must not make the tree worse than not using it: plain
    `make` and the direct binary behave as in a checkout rackup never saw
    (config.rktd untouched, `git status` clean, default `compiled/` complete).
C4. The shim, `rackup run` and rebuild's `make` use the same addon dir (the
    checkout's native one), so they see the same user-scope packages.
C5. A stale `.zo` of the same version must not shadow a fresh one: after a
    rebuild, the shim must not run older code than the direct binary.
C6. `rackup rebuild` leaves no keyed dirs of other versions in the tree.
C7. Removing or relinking a toolchain never deletes anything in the
    checkout's sources or the native addon dir.

Known limits of stock Racket that rackup does not claim to fix, recorded
when observed: a file outside the tree compiled by the direct binary into
the default `compiled/` is a version mismatch for any later version, for
every actor, until it is recompiled; and between `git checkout` of a new
version and the build, `raco pkg show` fails for every actor.

## Scenarios

| Id  | Scenario | Starts from |
|-----|----------|-------------|
| S0  | Golden build at V1 with plain make, no rackup. Baseline inventory; second `make` is a no-op; second `make` rewrites no `.zo`. | clone |
| S1  | Link at V1; packages in all 8 scope/mode/installer combinations plus link packages; scratch files; bump to V2 with `rackup rebuild`; bump to V3 with `rackup rebuild --pull`. | own clone |
| S2  | Same setup; bump to V2 with plain `make` only; then use the shim without any rackup command; then `rackup rebuild`. | own clone |
| S3  | Same-version source change: keyed `.zo` written by the shim, then a dependency changes and the tree is rebuilt with `make` and with `rackup rebuild` (contract C5). | S2 |
| S4  | State left by main's rackup (keyed-only roots in config.rktd, version-less keyed dir): upgrade rackup in place, use the shim, bump, rebuild. | own clone |
| S4c | Control: main's rackup, bump, plain `make`. Expected to fail the way Matthias reported; shows the harness detects it. | own clone |
| S5  | Build that fails after the binary is rebuilt; state in between; successful retry. | S2 |
| S6  | Downgrade V2 to V1 with `rackup rebuild`. | S2 |
| S7  | Two linked checkouts at different versions plus an installed release toolchain sharing scratch files and a link package. | own clones |
| S8  | `rackup link --force`, `rackup remove`, `rackup remove --clean-compiled`: nothing in the sources or native addon dir is deleted. | S7 |

Package combinations (all base-only catalog packages with git sources):

| Scope        | Mode   | Installed by | Package |
|--------------|--------|--------------|---------|
| user         | normal | shim         | threading-lib |
| user         | normal | direct       | memoize-lib |
| installation | normal | shim         | syntax-classes-lib |
| installation | normal | direct       | try-catch-finally-lib |
| user         | clone  | shim         | static-rename-lib |
| user         | clone  | direct       | box-extra-lib |
| installation | clone  | shim         | namespaced-transformer-lib |
| installation | clone  | direct       | srfi-lite-lib |
| user         | link   | shim         | labu (local, two modules) |
| installation | link   | direct       | labi (local, two modules) |

| S9  | One version throughout: no-op `make` with a package that has only keyed `.zo`; what does and does not trigger a sync; eight concurrent shim commands when a sync is due; direct `raco make` mixed with shim compiles (known limit); `rackup rebuild` at the same version; remove and relink. | S0 tree |

Each scenario builds its own clone at the path where it is used.  A built
tree embeds its absolute path: `make` in a `cp -a` copy at another path
installs the binary and runs setup in the original tree.

## Results (2026-11-15)

1436 journaled steps and probes.  Every scenario ran on the code of #99 +
#100 + #111; S1, S2 (with S3, S5, S6), S4, S7/S8 and S9 ran again on that
code plus the fix below.

What held on the PR code:

- S0: the build is idempotent; no rackup involvement.
- S1, S2: link changes nothing in the tree; shim, `rackup run` and the
  direct binary agree on the native addon dir; all ten package installs
  put `.zo` where predicted (shim: keyed root, direct: default root);
  after a bump by either path every actor loads the tree and every
  package from new-version `.zo`.
- S4: on main's rackup the control fails as reported (`make` exits 2 with
  a version mismatch in `collects/racket/compiled/cs-local-lab/compiled`,
  `rackup rebuild` cannot repair it, racket no longer starts).  After
  upgrading rackup in place, both the rebuild path and the plain-make
  path give a healthy tree.

Wrong predictions (the code was right, the expectation was not): the
in-place `make` recompiles every installed package, user scope included,
into the default root (only its first setup pass is `--no-user`).

Defects found:

1. Contract C5 failed (S3).  The user compiled `labi/main.rkt` through the
   shim, `dep.rkt` changed, plain `make` rebuilt the default root: the
   direct binary printed `(2 2)`, the shim and `rackup run` `(1 1)`.
   `rackup rebuild` had the same hole, because it kept the keyed dir of
   the current version.
2. The query that lists package directories held one scope's package lock
   while `pkg-directory` consulted another scope, so on an in-place build
   it failed with "lock mismatch" and returned nothing.  This also made
   `rackup remove --clean-compiled` clean nothing for linked toolchains.

Fix: a build removes every keyed dir of the code it recompiles (the tree
and every installed package); `rackup rebuild` does it directly, and the
shim runs a sync when the tree's `etc/config.rktd` is newer than the
toolchain's stamp, which covers plain `make`.  See "Keyed dirs that a
build supersedes" in `docs/IMPLEMENTATION.md`.  With the fix, S2 has no
mismatch, S3 prints the new value for every actor after plain `make` and
after `rackup rebuild`, and the remaining mismatches are the stock limit
above (3 in S1), main's own state before the upgrade (S4), and two
harness artifacts.

Known limit that remains (S9d, stock Racket behaviour for any two
compiled roots): compiling with the tree's own `raco make` after compiling
the same package through the shim, without `make`, leaves the shim on the
older keyed `.zo` until the next build or the next `raco make` through the
shim.

Tests added from these findings: `test/stale-zo.rkt` (same-version shadow
on a real racket; the package query on a real racket),
`test/compiled-roots-migration.rkt` (purge covers the tree and installed
packages and spares other dirs; sync), `test/env-consistency.rkt` (when
the shim does and does not ask for a sync).
