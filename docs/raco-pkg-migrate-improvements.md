# Proposed Improvements to `raco pkg migrate`

## Problem

`raco pkg migrate <version>` migrates user-scoped packages from an older
Racket version to the current one.  Internally it locates the old
version's package database by constructing a path from the version
number: typically `~/.local/share/racket/<version>/pkgs/` on Linux.

This path computation assumes that every Racket installation uses the
standard, version-scoped addon directory layout.  When `PLTADDONDIR` is
set (as it is with toolchain managers like rackup, or with custom
installation prefixes), the addon directory is a flat path that does not
contain a version component.  In this situation `raco pkg migrate` cannot
locate the old version's packages because it looks in the wrong place.

### Concrete example with rackup

rackup stores per-toolchain addon directories at:

    ~/.rackup/addons/<toolchain-id>/

When upgrading stable from 9.1 to 9.2:

- Old packages are at `~/.rackup/addons/release-9.1-cs-x86_64-linux-full/`
- New addon dir is `~/.rackup/addons/release-9.2-cs-x86_64-linux-full/`
- Running `PLTADDONDIR=<new> raco pkg migrate 9.1` fails because it
  looks for `~/.local/share/racket/9.1/pkgs/`, which does not contain
  the user's rackup-managed packages.

Currently rackup works around this by listing packages from the old
toolchain via `raco pkg show --user` and reinstalling them in the new
toolchain via `raco pkg install`.  This achieves the same result but
loses metadata that `raco pkg migrate` would preserve (e.g. auto vs.
manual installation scope).

## Proposed improvement: `--from-dir`

Add a `--from-dir <path>` flag to `raco pkg migrate` that accepts an
explicit addon directory as the source for migration, bypassing the
version-based path computation.

### Usage

```
raco pkg migrate --from-dir <old-addon-dir>
```

With rackup, this becomes:

```
PLTADDONDIR=~/.rackup/addons/release-9.2-cs-x86_64-linux-full/ \
  raco pkg migrate --from-dir ~/.rackup/addons/release-9.1-cs-x86_64-linux-full/
```

### Semantics

- `--from-dir <path>` tells `raco pkg migrate` to read the package
  database from `<path>` instead of computing it from a version number.
- The `<version>` positional argument becomes optional when `--from-dir`
  is given.
- All other behavior (installing packages in the current scope,
  respecting `--scope`, `--catalog`, etc.) remains unchanged.

### Implementation sketch

In `pkgs/racket-index/raco/pkg/migrate.rkt` (or wherever `raco pkg
migrate` is implemented), the change is:

1. Accept `--from-dir` via `command-line`.
2. When `--from-dir` is given, use it directly as the source pkgs
   directory instead of calling `(get-pkgs-dir #:user? #t #:version v)`.
3. Read `installed-pkg-table` from that directory.
4. Proceed with the existing installation logic.

## Additional considerations

### Preserving auto/manual scope

`raco pkg migrate` preserves whether a package was explicitly installed
vs. auto-installed as a dependency.  The list + reinstall workaround
currently used by rackup does not preserve this distinction.  Adding
`--from-dir` would allow rackup to use the official migration path and
preserve this metadata.

### `raco pkg show --scope-dir`

`raco pkg show` already supports `--scope-dir <dir>` to read package
information from an arbitrary directory.  A corresponding `--from-dir`
on `raco pkg migrate` would be consistent with this existing pattern.

### Who benefits

Any tool or workflow that manages multiple Racket installations with
non-standard addon directories would benefit: toolchain managers (rackup,
potentially others), CI systems that maintain isolated environments, and
users with custom `PLTADDONDIR` configurations.
