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
  `rackup reshim --mac-apps`, cleared via `rackup reshim --remove-mac-apps`.
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
- `main.rkt`: `--mac-apps`/`--remove-mac-apps` on `reshim`; `--mac-apps` on
  `install`; `remove-mac-apps!` in `cmd-uninstall`.
- `test/mac-apps.rkt`: discovery (`find-gui-apps`, launcher resolution, icon),
  bundle structure, launcher contents, non-clobber, regenerate/prune/remove
  integration, marker-based removal.
- `ci.yml` macOS E2E: after the full-distribution DMG install, enable
  `--mac-apps`, assert a wrapper exists for every shipped GUI `.app` that has a
  launcher, launch DrRacket *through the wrapper*, and verify
  `--remove-mac-apps` deletes them.

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
  confirm the wrapper→shim→`bin/drracket` path avoids the #37 aarch64 crash,
  and asserting the DrRacket wrapper carries a copied `.icns` referenced from
  its `Info.plist` (the icon path could not be verified on Linux because it
  depends on the real bundle's contents).

## 2026-06-09 update: drag-and-drop + double-click parity (AppleScript droplets)

Follow-up to a further #10 comment from otherjoel: the wrappers should also be
**drag-and-drop targets** for `.rkt` files (and, by extension, double-click
file handlers), matching what the standard DrRacket DMG install does.

### Why the shell-script launcher could not do this

A plain shell-script `CFBundleExecutable` never receives the files. When macOS
opens a document with an app it sends an `odoc` Apple Event, not `argv`; a
POSIX executable with no run loop ignores it. Getting the dropped/opened paths
requires something that handles `odoc` and re-emits them as a command line.

### Decision: AppleScript droplet via `osacompile`

Replace the shell-script launcher with an **AppleScript droplet** compiled by
`osacompile`. Its `on open theItems` handler turns each file into a
shell-quoted argument and runs the shim (`drracket file.rkt …`); `on run`
launches with none. The shim-routing rationale above is unchanged — the droplet
still calls the shim, so #37's `cd -P` fix still applies.

`osacompile` was chosen over the alternatives because it is **always present**
on macOS (a compiled Cocoa/Swift handler would need the Xcode command-line
tools, which many Macs lack) and because the bundle is **generated locally**, so
it carries no quarantine attribute and needs no codesigning/notarization to
launch under Gatekeeper (a prebuilt shipped binary would). `osacompile` has no
flags for bundle identity/types/icon, so those are patched afterward with
`PlistBuddy` — that is the cost of declaring file associations with any tool,
not an AppleScript tax.

### Double-click parity by mirroring, not hardcoding

The standard `DrRacket.app` registers as the **Editor** for
`rkt rktl rktd scrbl scm ss rhm` (and Viewer for `plt`), via the `drracket`
collection's `drracket.filetypes`. Only DrRacket among the shipped GUI apps
declares any types. So instead of hardcoding extensions, `mirror-document-types!`
copies the source bundle's `CFBundleDocumentTypes` (and its document `.icns`)
straight into the wrapper, replacing `osacompile`'s accept-all default. Apps
with no declared types keep the accept-all droplet behavior, so they remain
plain drop targets.

### Testing changes

- The bundle builder is now a parameter (`current-build-bundle!`) so unit tests
  stub the macOS-only `osacompile`/`plutil`/`PlistBuddy` step while still
  exercising discovery/prune/removal and verifying `write-mac-app!` forwards the
  right shim path (asserted via the generated droplet source), icon, and source
  bundle. `droplet-applescript` is a pure function tested directly.
- macOS E2E now asserts the wrapper is a droplet (`on open` in its compiled
  script), registers the Racket-source document types, and — via a recorder
  shim — that `open -a DrRacket.app file.rkt` forwards the file to the shim as
  an argument. The shim→`bin/drracket` launch / #37 crash stays covered by the
  direct-shim smoke test in the same step.
