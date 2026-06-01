# macOS GUI app wrappers (`--mac-apps`)

Date: 2026-05-31
Issue: #10 (comment from otherjoel requesting a `DrRacket.app` wrapper in
`~/Applications`, opt-in via `rackup install --mac-apps` / `rackup reshim
--mac-apps`)

## Problem

GUI tools managed by rackup (DrRacket) live under `~/.rackup/toolchains/<id>/`
and are launched via shims from the command line. macOS users expect to open
GUI apps from Finder / Spotlight / Dock, but rackup's tools are not
discoverable there.

## Decision

Add an opt-in `mac-apps` feature that writes wrapper `.app` bundles into
`~/Applications`, mirroring the existing `short-aliases` opt-in mechanism:

- Flag `mac-apps` in `state/config`, set via `rackup install --mac-apps` /
  `rackup reshim --mac-apps`, cleared via `rackup reshim --no-mac-apps`.
- `reshim!` (re)generates the bundles via `regenerate-mac-apps!`.

### Key design choice: exec the shim, not the GUI binary

Each wrapper's `Contents/MacOS/<Name>` is a shell script that `exec`s the
rackup shim (`~/.rackup/shims/drracket`), rather than pointing at the
toolchain's GUI binary or symlinking the real `DrRacket.app`. Reasons:

1. **#37 crash avoidance.** A GUI Racket binary launched through a symlinked
   parent dir crashes on aarch64 macOS (`invalid memory reference` in
   `cocoa/queue.rkt`). The shim's `cd -P` bin-symlink resolution (commit
   b6476dd) gives the binary a canonical `argv[0]`. A wrapper that pointed at
   a symlinked path directly would reintroduce the crash. Going through the
   shim reuses the already-confirmed-good launch path.
2. **Tracks the default toolchain.** The shim re-resolves the default at
   launch, so `DrRacket.app` follows `rackup default <id>` like the CLI.
3. **Toolchain env.** The shim sets `PLTADDONDIR`/`PLTCOMPILEDROOTS`.

### Safety

- Wrappers carry a `Contents/Resources/.rackup-managed` marker. rackup only
  overwrites/removes bundles with the marker, so a user's own
  `~/Applications/DrRacket.app` is never clobbered (generation warns and
  skips if a non-managed bundle is in the way).
- `cmd-uninstall` removes the wrappers (they exec shims under `RACKUP_HOME`,
  which is about to be deleted).
- macOS-gated: `regenerate-mac-apps!`/`remove-mac-apps!` no-op off macOS.

## Implementation

- `libexec/rackup/mac-apps.rkt`: flag get/set, `find-gui-apps` (discovers
  `*.app` bundles in the default toolchain's install tree and maps each to a
  shim launcher), `regenerate-mac-apps!`, `remove-mac-apps!`, `write-mac-app!`
  (Info.plist + launcher script + marker + `.icns`), non-clobber check. Test
  seams: `current-mac-apps-os?`, `current-user-applications-dir`.
- `shims.rkt`: `reshim!` calls `regenerate-mac-apps!` at the end.
- `main.rkt`: `--mac-apps`/`--no-mac-apps` on `reshim`; `--mac-apps` on
  `install`; `remove-mac-apps!` in `cmd-uninstall`.
- `test/mac-apps.rkt`: discovery (`find-gui-apps`, launcher resolution, icon),
  bundle structure, launcher contents, non-clobber, regenerate/prune/remove
  integration, marker-based removal.
- `ci.yml` macOS E2E: after the full-distribution DMG install, enable
  `--mac-apps`, assert a wrapper exists for every shipped GUI `.app` that has a
  launcher, launch DrRacket *through the wrapper*, and verify `--no-mac-apps`
  removes them.

## Handling all GUI apps

The set of wrappers is discovered at reshim time rather than hardcoded:
`find-gui-apps` scans `<toolchain>/install/` (and `lib/`) for `*.app` bundles
and wraps each one whose lowercased name resolves to a `bin/` launcher with a
shim. So whatever GUI apps a distribution ships (DrRacket and any others) are
handled automatically, present and future.

## Testing what couldn't be run locally

This was developed on Linux, so two layers of tests cover the macOS-specific
behavior:

- **Unit tests (run on every host, including Linux CI):** the OS gate and
  `~/Applications` location are parameters, so `find-gui-apps`,
  `regenerate-mac-apps!`, pruning, and `remove-mac-apps!` are exercised
  end-to-end against fake install trees.
- **macOS E2E (runs on the real macos-15 / macos-15-intel runners):** the
  feature is exercised against a real full Racket install — including
  *launching DrRacket through the generated wrapper*, which is the only way to
  confirm the wrapper→shim→`bin/drracket` path avoids the #37 aarch64 crash.
