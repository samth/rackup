# `rackup` V1 Plan (Linux-first Racket Toolchain Manager)

## Summary

Build a Linux-first `rackup` toolchain manager in Bash + Racket with:

- `curl | sh` bootstrap (interactive by default, `-y` supported)
- install of official Racket binary toolchains across releases, pre-release, and snapshot
- rustup-style executable shims for all discovered executables
- bash/zsh shell integration with per-shell activation and global default
- per-toolchain `PLTADDONDIR` isolation
- dynamic reshim generation and canonical toolchain IDs behind friendly aliases

Key research-driven design choices:

- Use `setup-racket` ideas for platform/variant defaults, snapshot-site probing, and installer compatibility rules.
- Use `raco-cross` ideas (and formats) for machine-readable installer discovery (`table.rktd`, `version.rktd`) and workspace metadata patterns.
- Do **not** depend on shelling out to `raco cross` in v1 (observed local fragility in dev-tree environments makes a hard runtime dependency risky).
- Prefer table-driven filename discovery over hardcoded URL patterns to support older releases more broadly (confirmed `table.rktd` exists at least as far back as `4.2.5`).

## V1 Scope

- Host support: Linux first.
- Shells: bash and zsh configuration support.
- Install sources: official binary installers only (release, pre-release, snapshot).
- Activation model: per-shell activation + global default.
- Project pin files: out of scope for v1 (document as future feature).
- GUI handling: PATH shims only (no `.desktop` integration).
- Verification: HTTPS + metadata checks only (no mandatory checksums/signatures in v1).
- Existing `PLTHOME` setup: ignored by tooling (README note only).

## Architecture (Bash + Racket split)

### Bash responsibilities

- Bootstrap installer (`install.sh`)
- Top-level launcher script (`~/.rackup/bin/rackup`)
- Shim dispatcher (`~/.rackup/libexec/rackup-shim`)
- Shell hook scripts for bash/zsh (`~/.rackup/shell/rackup.{bash,zsh}`)
- Minimal file/rc-file edits in `rackup init`

### Racket responsibilities

- Version spec parsing and canonicalization
- Remote metadata fetch/parsing (`version.txt`, `all-versions.html`, `table.rktd`, `version.rktd`, `stamp.txt`)
- Installer selection (release/pre-release/snapshot)
- Snapshot site probing (`utah` / `northwestern`)
- Toolchain manifest/index read/write (`.rktd`)
- Install orchestration and toolchain registration
- Executable enumeration + reshim list generation
- `doctor` diagnostics and CLI subcommand logic

### Runtime execution model

- `rackup` shell wrapper execs the Racket CLI core.
- Shims are Bash scripts/symlinks to a common Bash dispatcher for low overhead.
- Shims resolve toolchain from `RACKUP_TOOLCHAIN` (per-shell) or global default file.

## Filesystem Layout (`~/.rackup`)

- `~/.rackup/bin/rackup` (user-facing entrypoint)
- `~/.rackup/libexec/rackup-core.rkt` (Racket CLI core)
- `~/.rackup/libexec/rackup-shim` (common shim dispatcher)
- `~/.rackup/shims/` (symlinks for `racket`, `raco`, `scribble`, `drracket`, etc.)
- `~/.rackup/toolchains/<canonical-id>/install/` (actual installed Racket tree)
- `~/.rackup/toolchains/<canonical-id>/bin` (symlink to real bin dir, normalizes `bin` vs `racket/bin`)
- `~/.rackup/toolchains/<canonical-id>/meta.rktd`
- `~/.rackup/addons/<canonical-id>/` (per-toolchain `PLTADDONDIR`)
- `~/.rackup/cache/downloads/` (installer cache)
- `~/.rackup/state/default-toolchain` (plain text canonical ID)
- `~/.rackup/state/index.rktd` (installed toolchain index + aliases)
- `~/.rackup/state/config.rktd` (global config defaults)
- `~/.rackup/shell/rackup.bash`
- `~/.rackup/shell/rackup.zsh`

## Public CLI / Interfaces (V1)

## CLI Commands

- `rackup install <spec> [flags]`
- `rackup list`
- `rackup default [<toolchain>]`
- `rackup shell <toolchain>`
- `rackup shell --deactivate`
- `rackup run <toolchain> -- <command> [args...]`
- `rackup which <exe> [--toolchain <toolchain>]`
- `rackup current`
- `rackup remove <toolchain>`
- `rackup reshim`
- `rackup init [--shell bash|zsh]`
- `rackup doctor`

## Install flags (V1)

- `--variant cs|bc`
- `--distribution full|minimal`
- `--snapshot-site auto|utah|northwestern`
- `--arch <host-arch-only for v1 default; optional override allowed if table supports it>`
- `--set-default`
- `--force` (reinstall same canonical ID)
- `--no-cache` (skip cached installer reuse)

## Version spec grammar (user-facing)

- `stable`
- `pre-release`
- `snapshot` (alias for current snapshot)
- `snapshot:utah`
- `snapshot:northwestern`
- `<numeric>` like `8.18`, `8.16.0.4`, `4.2.5`

## Canonical toolchain ID format (stored/displayed)

- Release: `release-<version>-<variant>-<arch>-linux-<distribution>`
- Pre-release: `pre-<resolved-version>-<variant>-<arch>-linux-<distribution>`
- Snapshot: `snapshot-<site>-<stamp>-<resolved-version>-<variant>-<arch>-linux-<distribution>`

Examples:

- `release-8.18-cs-x86_64-linux-full`
- `pre-8.18.0.7-cs-x86_64-linux-full`
- `snapshot-utah-20260225-...-8.19.0.1-cs-x86_64-linux-full`

## Shell hook interface

- `rackup shell <toolchain>` emits shell code and is wrapped by a shell function installed by `rackup init`.
- `rackup shell --deactivate` clears `RACKUP_TOOLCHAIN` and `PLTADDONDIR`.
- Shell hook ensures `~/.rackup/shims` is in `PATH`.

## Important changes or additions to public APIs/interfaces/types

## Racket manifest types (`meta.rktd` / `index.rktd`)

Define stable `.rktd` schemas in v1.

`meta.rktd` fields:

- `id` (string)
- `kind` (`'release | 'pre-release | 'snapshot`)
- `requested-spec` (string)
- `resolved-version` (string)
- `variant` (`'cs | 'bc`)
- `distribution` (`'full | 'minimal`)
- `arch` (string; normalized, e.g. `x86_64`, `aarch64`)
- `platform` (string; `linux`)
- `snapshot-site` (`#f | 'utah | 'northwestern`)
- `snapshot-stamp` (`#f | string`)
- `installer-url` (string)
- `installer-filename` (string)
- `install-root` (path/string)
- `bin-link` (path/string)
- `executables` (list of strings)
- `installed-at` (ISO-8601 string)

`index.rktd` fields:

- `installed-toolchains` (hash: canonical-id -> summary hash)
- `aliases` (hash: alias -> canonical-id) for optional convenience names
- `default-toolchain` (string or `#f`) mirrored to text file for shim speed

## Shell env contract (public behavior)

When active:

- `RACKUP_TOOLCHAIN=<canonical-id>`
- `PLTADDONDIR=~/.rackup/addons/<canonical-id>`
- `PATH` contains `~/.rackup/shims` early

Not set in v1 by default:

- `PLTHOME`
- `PLTCOLLECTS`

## Version Discovery and Install Resolution

## Release (`stable` / numeric versions)

- `stable` resolves via `https://download.racket-lang.org/version.txt` (`stable` entry).
- Numeric versions resolve directly.
- For actual installer filename selection, fetch `table.rktd` from `https://download.racket-lang.org/installers/<version>/table.rktd`.
- Select exact filename from table using requested platform/arch/variant/distribution.
- If table missing or malformed, fallback to `setup-racket`-style URL construction logic.
- Use `all-versions.html` only for future `ls-remote`/docs and doctor hints, not as install-time hard dependency.

## Pre-release

- Resolve metadata from `https://pre-release.racket-lang.org/installers/version.txt`.
- Fetch pre-release `table.rktd` and `version.rktd`.
- Filename selection uses `current`-style names in table, but canonical ID stores resolved pre-release version from `version.rktd`.
- Canonical ID is pinned on install.

## Snapshot (`snapshot` / `current`)

- If `--snapshot-site auto`, probe Utah and Northwestern:
  - fetch `stamp.txt`
  - check installer existence (HEAD/GET for selected filename)
  - choose newest live site by stamp (same behavior class as `setup-racket`)
- Fetch `table.rktd` and `version.rktd` from selected snapshot site.
- Install from `.../snapshots/current/installers/...`.
- Record `snapshot-site`, `stamp`, and resolved version in canonical ID (pin-on-install semantics).

## Variant and distribution defaults

- Default `distribution`: `full`
- Default `variant`: `cs` for versions `>= 8.0`, otherwise `bc`
- Validation:
  - reject `cs` for versions before CS support
  - reject unsupported arch/platform/variant combos if no installer exists in table
- For `stable`, `pre-release`, `snapshot`, default to `cs` unless table selection proves unavailable and user explicitly requested fallback behavior (v1 default: fail with clear message, suggest `--variant bc` if applicable)

## Install and Registration Flow (Linux)

1. Resolve spec to canonical toolchain metadata.
2. Download installer `.sh` to cache.
3. Create staging toolchain dir under `~/.rackup/toolchains/<id>/`.
4. Run official installer in noninteractive mode into `install/` using Linux installer flags (same approach family as `setup-racket` custom-dest install).
5. Detect actual bin dir (`install/bin` vs `install/racket/bin`) and create normalized `bin` symlink.
6. Enumerate executable files in normalized `bin`.
7. Create/add per-toolchain addon dir `~/.rackup/addons/<id>/`.
8. Write `meta.rktd`, update `index.rktd`.
9. Auto-run `rackup reshim`.
10. Optionally set default if `--set-default` or if no default exists yet.

## Shim and Activation Behavior

## Shim dispatcher behavior (`rackup-shim`)

- Determine invoked name via `basename "$0"`.
- Resolve active toolchain:
  - first `RACKUP_TOOLCHAIN`
  - then `~/.rackup/state/default-toolchain`
- If none, print actionable error with `rackup list` / `rackup default`.
- Exec `~/.rackup/toolchains/<id>/bin/<exe>` if executable exists.
- If missing in active toolchain, print error and suggest:
  - `rackup which <exe> --toolchain <id>`
  - `rackup reshim`
  - switching toolchain

## Reshim policy

- `rackup reshim` generates shim symlinks for the union of executables across installed toolchains plus `rackup`.
- Auto-run after `install`, `remove`, and possibly `doctor --fix`.
- Prevent overwrite of non-rackup-managed files in `~/.rackup/shims` (manage only files in a manifest list or with expected symlink target).

## Shell integration (`rackup init`)

- `rackup init` writes a managed block to `.bashrc` / `.zshrc` (user-selected or inferred).
- Managed block:
  - prepends `~/.rackup/shims` to `PATH` if absent
  - sources `~/.rackup/shell/rackup.<shell>`
- Shell helper defines a `rackup` function wrapper that intercepts `shell` and `shell --deactivate` to `eval` emitted shell code, and delegates all other commands to the installed `rackup` binary.

## `raco-cross` Integration Strategy (Hybrid, no hard dependency)

- Reuse concepts and formats:
  - `table.rktd` / `version.rktd` discovery
  - workspace metadata recording pattern
  - snapshot pinning philosophy (workspace/version/site association)
- Do not shell out to `raco cross` for installs in v1.
- Do not require `raco-cross` package to be installed.
- Add a small internal Racket module for table parsing and filename selection inspired by `raco-cross` browse logic.
- Optional future work: `rackup import-raco-cross-workspace` (not v1).

## Error Handling and Edge Cases

- No default and no shell activation: clear error on shim invocation.
- Snapshot site unavailable: fail and list both sites/status.
- Requested variant/arch combo missing from table: fail with nearest available suggestions from table.
- Installer runs but bin dir not found: preserve logs, mark install failed, do not register toolchain.
- Partial installs: cleanup staging dir on failure.
- Duplicate install same canonical ID: skip unless `--force`.
- RC file already contains managed block: idempotent update.
- User modified managed block: detect hash marker mismatch and refuse overwrite unless `--force`.
- Missing zsh on machine: still allow writing `.zshrc` hook; local tests may skip execution.
- Legacy versions with unusual filenames: table-driven selection first, URL-template fallback second.

## Implementation Plan (build order)

1. Create core state/layout and Racket schema modules (`config`, `index`, `meta`, path helpers).
2. Implement metadata fetch/parsers:
   - `version.txt`
   - snapshot `stamp.txt`
   - `version.rktd`
   - `table.rktd`
3. Implement installer filename selector from table (Linux only).
4. Implement installer download/cache and Linux install orchestration into toolchain dir.
5. Implement executable enumeration + manifest registration.
6. Implement shim dispatcher + `reshim`.
7. Implement core commands:
   - `install`, `list`, `default`, `current`, `which`, `remove`, `reshim`
8. Implement shell activation emission + `init` for bash/zsh.
9. Implement `run` and `doctor`.
10. Implement `curl | sh` bootstrap and interactive shell-config prompt.
11. Write README docs, including note about existing `PLTHOME` setups being ignored in v1.

## Test Cases and Scenarios

## Unit tests (Racket)

- Parse `version.txt` stable and pre-release formats.
- Parse `table.rktd` across representative versions:
  - `4.2.5`
  - `5.3.6`
  - `6.0`
  - `8.x` CS/BC
  - snapshot/current tables
- Filename selection for:
  - release/full/minimal
  - `cs`/`bc`
  - x86_64 Linux
  - older pre-CS versions
- Snapshot site selection logic using mocked stamps and availability.
- Canonical ID generation for release/pre/snapshot.
- Manifest/index schema read/write roundtrip.

## Shell/shim tests

- Shim dispatch with `RACKUP_TOOLCHAIN` set.
- Shim dispatch using global default file.
- Missing executable in active toolchain gives helpful error.
- `reshim` creates union shims and is idempotent.
- `rackup shell <id>` emit code sets `RACKUP_TOOLCHAIN` and `PLTADDONDIR`.
- `rackup shell --deactivate` emit code unsets vars.

## Integration tests (Linux)

- Install latest stable default (`full+cs`) and run:
  - `racket --version`
  - `raco pkg config catalogs`
  - `scribble --help`
- Install an older BC-only version and validate default variant fallback.
- Install pre-release and snapshot, verify canonical IDs are pinned.
- Switch global default and verify shim behavior changes.
- Per-shell activation overrides global default.
- `drracket` shim resolves path (launch need not be exercised headlessly).
- `remove` deletes toolchain and reshims.
- `init` updates temp `.bashrc` / `.zshrc` with managed block idempotently.
- Bootstrap script in temp `HOME`:
  - interactive prompt flow (simulated input)
  - `-y` noninteractive flow

## Assumptions and Defaults (explicit)

- Command name is `rackup`.
- V1 uses `~/.rackup` (not XDG).
- V1 ignores existing `racket-dev-goodies`/`PLTHOME` setup except for README guidance.
- V1 manages `PATH` and `PLTADDONDIR`, not `PLTHOME`.
- V1 is Linux-host only, but code is structured for future macOS/Windows support.
- V1 defaults to host architecture, `full`, and `CS` when supported.
- Floating aliases (`stable`, `pre-release`, `snapshot`) are resolved and pinned at install time.
- `curl | sh` prompts about shell config; `-y`/env mode accepts defaults.
- HTTPS + existence/metadata checks are sufficient for v1 installer trust.
- `raco-cross` is a reference/inspiration source, not a required runtime dependency.

## References (researched inputs)

- `racket-dev-goodies`: https://github.com/takikawa/racket-dev-goodies
- `setup-racket` action: https://github.com/Bogdanp/setup-racket
- `raco-cross`: https://github.com/racket/raco-cross
- Racket installers stable metadata (`version.txt`, `table.rktd`, `version.rktd`): https://download.racket-lang.org/installers/
- Racket all versions listing: https://download.racket-lang.org/all-versions.html
- Pre-release installers metadata: https://pre-release.racket-lang.org/installers/
- Utah snapshots: https://users.cs.utah.edu/plt/snapshots/
- Northwestern snapshots: https://plt.cs.northwestern.edu/snapshots/
- Rustup book (proxy/override concepts): https://rust-lang.github.io/rustup/
- GHCup guide (bootstrap and shell integration patterns): https://www.haskell.org/ghcup/guide/
