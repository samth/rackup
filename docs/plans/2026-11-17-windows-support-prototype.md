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
  native dispatcher, about 400 lines of C. Every shim (`racket.exe`,
  `raco.exe`, `drracket.exe`, ...) is a copy; the shim picks the tool
  from its own file name, resolves `RACKUP_TOOLCHAIN` or the default,
  applies the toolchain's `env.txt` (NAME=VALUE; same `PLTADDONDIR` and
  `PLTCOMPILEDROOTS` rules as `env.sh`), falls back to user-scope
  launchers in the addon dir, and passes its own command line through
  verbatim. It ignores Ctrl+C (the tool gets it) and puts the tool in a
  kill-on-close job object. The copy named `rackup.exe` runs rackup
  itself with the hidden runtime, saving and clearing the Racket env vars
  like `bin/rackup`, and on a confirmed uninstall deletes `RACKUP_HOME`
  from a detached `cmd` after it exits. Copies, not hardlinks, because
  Racket has no hardlink primitive; a reshim skips shims that already
  match, so a running shim does not block it.
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

## Not done yet

- `rackup init` / `switch` / `shell` for PowerShell (a profile function
  that sets `$env:RACKUP_TOOLCHAIN`), and PowerShell completions. The
  shims work in cmd, PowerShell and Git Bash without them.
- Uninstall should also remove the shims dir from the user `Path`.
- `rackup self-upgrade` on Windows (re-run `install.ps1`; the running
  `rackup.exe` copy is locked, so replace it by rename).
- `rackup link`/`rebuild` for Windows source checkouts (bin overlays use
  per-file links).
- GUI tools (`drracket.exe`) launched through a console shim open a
  console window; the shim could detect GUI-subsystem targets and not
  wait, as Scoop's shim does.
- A prebuilt `rackup-core.exe` (`raco exe`) instead of the hidden
  runtime, as on Unix.
- An ARM64 shim build (the x86_64 shim runs emulated meanwhile).
- Upstream: ask distro-build to publish a full `.tgz` for Windows next
  to the Minimal one, which would remove the 7-Zip dependency.
