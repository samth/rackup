# Windows support: what we know, and a first prototype

Issue: #2 (Windows host support), #13 (non-Linux install flows).

## What was already recorded

- `docs/plans/2026-03-06-windows-support-research.md`, mirrored as four
  comments on #2 (2026-03-06): a survey of rustup, GHCup, Volta, juliaup,
  nvm-windows, pyenv-win, mise, Scoop and SDKMAN; a ranking of shim
  strategies (native `.exe` shims first, `.cmd` shims last); a code audit
  of every Unix-only spot in rackup; and a three-phase plan (core
  compatibility, PowerShell bootstrap, polish and CI).
- #2, 2026-03-15: uninstall cannot delete `RACKUP_HOME` from the running
  rackup process on Windows (open files cannot be deleted); it needs a
  helper that runs after rackup exits.
- #2, 2026-03-28 (ndykman): assume Windows 10 or later and long-path
  support rather than working around `MAX_PATH`.
- #13 (2026-03-17): macOS is done; Windows is the remaining gap.
- No pull request has touched Windows support.

## New findings (2026-11-17)

- **Racket publishes no full-distribution `.tgz` for Windows.**
  `table.rktd` for 8.18 lists `racket-8.18-x86_64-win32-cs.exe` (NSIS)
  for the full distribution, and both `.exe` and `.tgz` only for Minimal
  Racket. The research doc assumed `.tgz` archives for everything.
- **Running the NSIS installer is a poor fit**, even silently
  (`/S /D=dir`). The generator
  (`racket/distro-build`, `distro-build-client/installer-exe.rkt`) uses
  `SetShellVarContext all`, writes `HKLM` keys, `HKCR` file associations
  and Start-menu shortcuts, and NSIS 3 defaults to asking for admin. Side
  by side versions would fight over the associations.
- **7-Zip unpacks the NSIS payload exactly.** `7z x installer.exe
  -x!$PLUGINSDIR` produces the same tree the installer would copy
  (`Racket.exe`, `raco.exe`, `collects`, `share`, ... at the top), and
  that tree runs in place: `typed/racket` loads without recompiling and
  `raco pkg show -i` lists `main-distribution`.
- **Windows Racket can run rackup today.** `rackup-core.rkt` loads on
  Windows Racket 8.18 once `scribble-text-lib` is installed (as the Unix
  bootstrap already does).
- Racket on Windows reports `execute` for every file, rejects Unix
  permission bits like `#o755`, describes the OS in
  `(system-type 'machine)` (use `'arch`), and separates
  `PLTCOMPILEDROOTS`/`PATH` entries with `;`.
- `make-file-or-directory-link` asks Windows for an unprivileged symlink,
  which works only in Developer Mode.

## The prototype

The "obvious approach" from the research doc, with two changes the new
findings forced: the full distribution is unpacked with 7-Zip, and no
links of any kind are used (not even junctions), so nothing needs
Developer Mode or admin.

- **Platform** (`platform.rkt`, `versioning.rkt`, `remote.rkt`): host
  platform token `win32`, arch from `(system-type 'arch)`, installer
  preference `.tgz` then `.exe`.
- **Installers** (`installer-backend.rkt`): `.tgz` is unpacked in-process
  with `file/untgz` (no `tar.exe` needed); `.exe` is unpacked with 7-Zip,
  found on `PATH` or in Program Files, with an error that suggests
  `winget install 7zip.7zip` or `--distribution minimal`. The bin dir of a
  Windows tree is its top (or `racket/`).
- **No links** (`fs.rkt`, `paths.rkt`, `runtime.rkt`, `install.rkt`): a
  "directory pointer" is a symlink on Unix and, on Windows, a small file
  holding the target path. `toolchains/<id>/bin`, `runtime/current` and
  `runtime/versions/<id>/bin` use it, and readers go through
  `follow-dir-pointer` (`rackup-toolchain-bin-dir`).
- **Shims** (`libexec/rackup/windows/rackup-shim.c`, `shims.rkt`): one
  native dispatcher, about 450 lines of C that call only kernel32 (no C
  runtime), so the binary is 12 KB. Every shim (`racket.exe`,
  `raco.exe`, `drracket.exe`, ...) is a copy; the shim picks the tool
  from its own file name, resolves `RACKUP_TOOLCHAIN` or the default,
  applies the toolchain's `env.txt` (NAME=VALUE; same `PLTADDONDIR` and
  `PLTCOMPILEDROOTS` rules as `env.sh`), falls back to user-scope
  launchers in the addon dir, and passes its own command line through
  verbatim. It ignores Ctrl+C (the tool gets it) and puts the tool in a
  kill-on-close job object. The copy named `rackup.exe` runs rackup
  itself with the hidden runtime, saving and clearing the Racket env vars
  like `bin/rackup`, and on a confirmed uninstall deletes `RACKUP_HOME`
  from a detached `cmd` after it exits. A reshim skips shims that
  already match; a stale shim that is running (`rackup.exe` always is
  during a reshim) cannot be deleted or overwritten, so it is renamed to
  `.rackup-stale-*` and removed by a later reshim. Shims from any rackup
  version are recognized by a string in the binary, so a shim for a
  removed tool is cleaned up even after the dispatcher changed.
- **Default home**: `%LOCALAPPDATA%\rackup` on Windows.
- **Bootstrap** (`scripts/install.ps1`): downloads `rackup-src.tar.gz`
  and `rackup-shim-x86_64-win32.exe` from the Pages site (checksums
  filled in by the Pages build), unpacks Minimal Racket as the hidden
  runtime, installs `scribble-text-lib`, runs `rackup runtime install`
  and `rackup reshim`, and prepends the shims dir to the user `Path` in
  `HKCU\Environment` (keeping `REG_EXPAND_SZ`). `-SourceDir`, `-ShimExe`,
  `-RackupHome` and `-NoModifyPath` let CI install from a checkout.
- **Build and CI**: the Pages build compiles the shim with mingw-w64 and
  emits `install.ps1`; both Pages workflows install
  `gcc-mingw-w64-x86-64`, and the CI Pages job checks the files exist.
  A new `windows-e2e` job (windows-latest, which has gcc and 7-Zip)
  installs from the checkout with `install.ps1`, installs Minimal and
  full stable, runs `racket`/`raco` through the shims, installs a user
  package, checks exit codes, removes a toolchain and uninstalls.

## Shim design: one binary or stub + DLL

Two ways to keep the per-tool shims small were prototyped (2026-11-17)
and run through the same checks under Wine (no toolchain configured,
runtime install, toolchain install, arguments with spaces, quotes and
trailing backslashes, `PLTADDONDIR`/`PLTCOMPILEDROOTS`, exit codes, a
missing tool, stderr to a file, uninstall):

| | per-tool shim | shared file | 25 shims |
|---|---|---|---|
| A: one no-CRT shim, copied | 12 KB | none | ~300 KB |
| B: no-CRT stub, loads `libexec\rackup-shim.dll` | 4.6 KB | 12.8 KB DLL | ~130 KB |
| (first prototype, with the mingw C runtime) | 49 KB | none | ~1.2 MB |

Both passed every check, and startup was the same (10 runs of
`racket -n -e ''` through the shim: about 0.2 s over running Racket
directly, for both, under Wine).

**Chosen: A.** Most of the original 49 KB was the C runtime, so
dropping it gets nearly all of the size win without a second binary.
B's advantage is that shim fixes ship by replacing one DLL, but a reshim
already rewrites any shim whose bytes differ (renaming a running one
aside), so A gets the same effect. B adds a second artifact to build,
publish and checksum, a stub/DLL interface to keep compatible, and a
DLL that is locked while any tool runs, which needs the same rename
dance anyway. The B stub source is kept outside the repo for reference.

Hardlinks (`CreateHardLinkW` through the FFI) would shrink A further,
but they need a copy fallback off NTFS and make every shim share one
locked file; at 12 KB a copy, not worth it now.

## How it was tested

There is no Windows machine in the dev container, so the prototype ran
under Wine 9.0 with the real Windows Racket 8.18 builds and the shim
cross-compiled with mingw-w64:

- `rackup version`, `runtime install` (adopting a runtime laid out like
  `install.ps1` does), `install 8.18 --distribution minimal`,
  `install 8.18` (full), `list`, `which`, `current`, `default`, `run`,
  `doctor`, `reshim`, `remove`, and `uninstall` all work.
- Through the shims: `racket -e` with arguments containing spaces,
  quotes and trailing backslashes arrives intact; exit codes pass
  through; `PLTADDONDIR` and `PLTCOMPILEDROOTS` (`compiled/8.18-cs;.`)
  are set; `raco pkg install -u gregor-lib` lands in rackup's addon dir
  and loads afterwards; `typed/racket` runs from the full install.
- Wine's 7-Zip could not be installed here, so the full install used a
  stand-in `7z.exe` that copied a tree unpacked by the real (Linux)
  7-Zip; `extract-nsis-installer!` itself was run with Linux 7-Zip on the
  real installer and produced an identical tree.
- Not tested: `install.ps1` (no PowerShell here), real Windows (Wine has
  no symlink or junction support and is permissive in other ways), ARM64.
  The `windows-e2e` CI job covers the first two once the branch runs.

## Second pass (2026-11-17): making the prototype real

- **PowerShell integration.** `rackup init --shell powershell` (the default
  on Windows) writes `shell\rackup.ps1` and dot-sources it from
  `Documents\WindowsPowerShell\profile.ps1` and, when PowerShell 7 is
  installed, `Documents\PowerShell\profile.ps1`. The helper puts the
  shims on PATH, defines a `rackup` function that evaluates `rackup
  switch` / `rackup shell` output (it sets `RACKUP_SHELL=powershell`, so
  rackup prints `$env:RACKUP_TOOLCHAIN = '...'` instead of `export`), and
  registers a native argument completer for commands and toolchain names.
  Profiles do not run under the Restricted default, so install.ps1 skips
  `init` there with a hint (`Set-ExecutionPolicy -Scope CurrentUser
  RemoteSigned`), and `rackup init` warns. The check ignores the Process
  scope, which `-ExecutionPolicy Bypass` sets and child shells inherit.
- **Uninstall** removes the profile blocks, the shims folder from the
  user `Path` and the `RACKUP_HOME` user variable (raw registry access
  through the FFI, keeping `REG_EXPAND_SZ`), then broadcasts
  `WM_SETTINGCHANGE`.
- **Self-upgrade** downloads `install.ps1`, checks it against the new
  `install.ps1.sha256`, and runs it with `-SelfUpgrade`. install.ps1 now
  replaces files one by one and renames any that are in use (the running
  `rackup.exe` shim, `rackup-core.exe` and its DLLs) to `.rackup-stale-*`;
  the next run deletes them. It writes `.installed-sha256` like
  install.sh, and `--exe`, `--source`, `--ref` and `--repo` map to
  `-Exe`, `-Source`, `-Ref` and `-Repo`.
- **Link and rebuild.** A Windows tree keeps `Racket.exe` at the top of
  plthome, so link detects that layout (in-place checkout or unpacked
  distribution), points the toolchain's `bin` at plthome, and lists its
  executables directly instead of syncing an overlay. `rebuild` runs
  `nmake win`. `install --prefix` is refused on Windows (it needs a link).
- **GUI tools.** The shim reads the target's PE header; a GUI-subsystem
  program (DrRacket, GRacket, Slideshow) is started outside the job object
  and the shim returns at once, so the terminal is not held.
- **Prebuilt `rackup-core.exe`.** `scripts/build-dist.ps1` runs `raco exe`
  and `raco distribute` on windows-latest (in `build-exe.yml`); the
  result is `rackup-x86_64-win32.tar.gz` holding `rackup\bin\rackup-core.exe`
  and `rackup\bin\lib\`. install.ps1 prefers it and falls back to
  source when none is published for the arch.
- **ARM64.** `scripts/build-windows-shim.sh aarch64` builds a native
  ARM64 shim with clang and lld; mingw-w64 has no ARM64 import libraries,
  so the script generates kernel32's from the functions the shim
  references. Racket publishes ARM64 Windows builds (`arm64-win32`, both
  full `.exe` and Minimal `.tgz`), so rackup itself needed no changes.
  There is no ARM64 prebuilt `rackup-core.exe` yet; ARM64 installs from
  source.
- **CI.** `windows-e2e` is a matrix: x86_64 from source (Minimal and
  full), x86_64 with the prebuilt exe, and native ARM64 on
  `windows-11-arm`. Each installs with install.ps1 using the shim from the
  Pages build, checks the user PATH, runs tools through the shims, tests
  `rackup switch` and completion in fresh `pwsh` and `powershell`
  sessions, runs `rackup self-upgrade` against the local files, and
  checks that uninstall cleans the PATH, `RACKUP_HOME` and the profile.

Tested under Wine before pushing: init and the PowerShell `switch`
output, uninstall's registry cleanup, linking an unpacked full
distribution (bin pointer, probe, `env.txt`), the DrRacket shim returning
at once while console tools still pass their exit codes, and a
Wine-built `rackup-core.exe` installing and running a toolchain. Not
testable here: install.ps1, self-upgrade, the ARM64 shim, and nmake.

## Still not done

- A GUI-subsystem shim variant, so launching a shim from Explorer or a
  shortcut does not flash a console window.
- An ARM64 prebuilt `rackup-core.exe` (needs Racket on `windows-11-arm`
  in `build-exe.yml`).
- Bash completion and `switch` for Git Bash on Windows.
- Code signing for the shim and `rackup-core.exe` (SmartScreen).
- Upstream: ask distro-build to publish a full `.tgz` for Windows next
  to the Minimal one, which would remove the 7-Zip dependency for new
  releases.
