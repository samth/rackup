# Windows Support for rackup: Research and Considerations

This document captures research into how other toolchain managers handle Windows
support, and what considerations apply to bringing rackup to Windows.

## Current State

rackup v1 is Linux-only (PLAN.md line 348: "V1 is Linux-host only, but code is
structured for future macOS/Windows support"). The architecture is
platform-agnostic in many areas, but several components are deeply Unix-specific:

- **Bootstrap installer** (`scripts/install.sh`): POSIX shell script using
  `curl`/`wget`, `tar`, `chmod`, `mktemp`
- **Shim dispatcher** (`libexec/rackup/shims.rkt`): Generates a Bash script
  that resolves the active toolchain and `exec`s the real binary
- **Shell integration** (`libexec/rackup/shell.rkt`): Manages blocks in
  `.bashrc`/`.zshrc`
- **Symlinks**: Used extensively for shims (symlinks to dispatcher), toolchain
  `bin` directories, and the runtime `current` link
- **Installer execution**: Runs Racket's `.sh` installers with
  `--create-dir --in-place --dest`
- **Path handling**: Uses `/` separators, `~/.rackup` default home

## Survey of Toolchain Managers on Windows

### 1. rustup (Rust)

**The most mature reference implementation for Windows toolchain management.**

- **Bootstrap**: Standalone `rustup-init.exe` (native Windows console
  executable). No MSI, no PowerShell script. Downloaded from rustup.rs and run
  directly. Supports `-y` for noninteractive mode.
- **PATH management**: Modifies the Windows **registry**
  (`HKCU\Environment\PATH`) rather than shell profile files. Uses
  `REG_EXPAND_SZ` type (not `REG_SZ`) to preserve `%VARIABLE%` expansions.
  Broadcasts `WM_SETTINGCHANGE` after modification so new terminal windows pick
  up the change without a logoff/reboot.
- **Shims**: All proxy executables (`cargo.exe`, `rustc.exe`, etc.) are
  **hardlinks** to `rustup.exe`. When invoked, rustup inspects `argv[0]` to
  determine which tool was called, resolves the appropriate toolchain, then
  delegates. Falls back from symlinks to hardlinks because Windows symlinks
  require Developer Mode or `SeCreateSymbolicLinkPrivilege`.
- **Shell integration**: None on Windows (no profile file editing). Tab
  completions available for PowerShell via
  `rustup completions powershell >> $PROFILE`.
- **Self-update**: Multi-stage process because a running `.exe` cannot be
  deleted on Windows. Downloads new binary, spawns it with `--self-replace`,
  waits for parent to exit, then replaces.
- **Self-uninstall**: Three-process trick using `FILE_FLAG_DELETE_ON_CLOSE` to
  clean up after itself.
- **Registry**: Creates uninstall entry at
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Rustup` for
  Add/Remove Programs.
- **Key Windows issues**: File locking (running processes prevent
  deletion/update of `.exe` files), Windows Defender SmartScreen warnings on
  unsigned binaries, `MAX_PATH` (260 char) limit, junction points vs symlinks.

### 2. GHCup (Haskell)

- **Bootstrap**: PowerShell script (`bootstrap-haskell.ps1`) run via
  `Invoke-WebRequest | Invoke-Command`. Temporarily bypasses execution policy,
  enforces TLS 1.2.
- **PATH management**: Registry-based (`HKCU\Environment`). Also sets
  `GHCUP_INSTALL_BASE_PREFIX`, `GHCUP_MSYS2`, `CABAL_DIR` as persistent
  user-level environment variables.
- **Shims**: Uses a **shim .exe** forked from Scoop's "better shimexe"
  (`shim-2.exe`, ~113KB compiled C binary). For each tool, creates two files:
  `tool.exe` (copy of generic shim binary) and `tool.shim` (text file with
  `path = C:\ghcup\ghc\9.6.6\bin\ghc.exe`). The shim reads the `.shim` file,
  calls `CreateProcessW()`, handles GUI vs console app detection, and forwards
  Ctrl+C signals.
- **MSYS2**: Installs a full MSYS2 environment under `C:\ghcup\msys64` for
  build toolchain support (gcc, make, autoconf, etc.).
- **Default location**: `C:\ghcup` (short path; avoids spaces which break MSYS2
  bash).
- **Desktop shortcuts**: Creates Start Menu/Desktop shortcuts for MSYS2 shell,
  uninstaller, and dev dependencies installer.

### 3. Volta (JavaScript)

- **Bootstrap**: MSI installer that puts binaries in `C:\Program Files\Volta`.
  Requires admin privileges.
- **PATH management**: Adds a single system PATH entry. All shims live in the
  same directory.
- **Shims**: **Native `.exe` shims** (written in Rust). When invoked, walks up
  the directory tree looking for `package.json` with a `volta` key to determine
  the version. Downloads missing versions transparently.
- **Shell integration**: None needed -- works in cmd.exe, PowerShell, Git Bash
  uniformly.
- **Key insight**: No shell hooks, no activation step. Version resolution is
  entirely filesystem-based (project config files), making it work identically
  in interactive and non-interactive contexts.

### 4. juliaup (Julia)

- **Bootstrap**: Distributed via **Windows Store** and `winget`. Uses Windows
  **App Execution Aliases** -- stubs placed in
  `%LOCALAPPDATA%\Microsoft\WindowsApps` (already on PATH by default). No PATH
  modification needed.
- **Shims**: Native Rust binary (`julialauncher`) that reads juliaup config to
  resolve the correct Julia version. Supports channel specifiers
  (`julia +release`), per-directory overrides, and auto-detection.
- **Shell integration**: None needed -- App Execution Aliases are OS-level.
- **Key insight**: Leveraging the Windows Store for distribution provides
  auto-updates, trusted publisher status, and no admin requirements.

### 5. nvm-windows (Node.js)

- **Bootstrap**: Standard Windows installer (`.exe` setup wizard). Written in
  Go.
- **PATH management**: Uses a **directory junction** (`mklink /J`) at a fixed
  location (e.g., `C:\Program Files\nodejs`). `nvm use` updates the junction
  target. A single PATH entry is added once during installation.
- **Shims**: None -- executables are accessed directly through the junction.
- **Key issues**: Requires admin privileges for junction creation. Cannot
  coexist with a standalone Node.js installation at the junction path.

### 6. pyenv-win (Python)

- **Bootstrap**: PowerShell, pip, Chocolatey, or git clone. Installs to
  `%USERPROFILE%\.pyenv\pyenv-win`.
- **Shims**: `.bat` file shims that temporarily modify PATH and delegate.
  Requires `pyenv rehash` after pip installs.
- **Key issues**: `.bat` shims are the most fragile approach -- invisible to
  tools scanning for `.exe`, cause script termination bugs when called from
  other batch files without `call`.

### 7. mise (polyglot runtime manager)

- **Bootstrap**: Scoop, winget, or Chocolatey.
- **Shims**: Configurable via `windows_shim_mode`:
  - `exe` (default): Native shim binary, hardlinked for each tool.
  - `file`: `.cmd` script shims (known serious bugs -- script termination).
  - `hardlink`/`symlink`: Direct links to tool binaries.
- **Shell integration**: PowerShell only for `activate` mode. cmd.exe limited
  to shim-only usage.
- **Key lesson**: The evolution from `.cmd` to native `.exe` shims was driven
  by the `.cmd` script termination bug, where a calling batch script stops
  after executing a `.cmd` shim without using `call`.

### 8. Scoop (Windows package manager)

- **Shims**: The most well-documented reference implementation. Three files per
  tool: `tool.exe` (native C binary), `tool.shim` (config file with
  `path = ...`), `tool.ps1` (PowerShell wrapper). The shim exe was rewritten
  from C# to C to eliminate .NET runtime overhead, fix Ctrl+C handling, and
  prevent orphaned child processes. Open source at ScoopInstaller/Shim.
- **No admin required**: Entirely user-scoped installation.

### 9. SDKMAN (JVM)

- **No native Windows support.** Bash-only, requires WSL2 on Windows. A
  Microsoft-backed native port (`microsoft/java-wdb`) was archived in 2025.

## Shim Strategies Ranked by Windows Robustness

1. **Native `.exe` shims** (rustup, Volta, juliaup, Scoop, mise `exe` mode,
   GHCup): Works in all shells, supports signal forwarding, can be code-signed,
   no script termination bugs.
2. **Directory junctions** (nvm-windows): Simple, works everywhere, but requires
   admin and changes are global.
3. **PATH manipulation** (uru): Session-scoped, no per-directory switching.
4. **PowerShell script shims** (rbenv-for-windows): Works in PowerShell only.
5. **`.bat`/`.cmd` script shims** (pyenv-win, mise `file` mode): Most fragile.
   Script termination bugs, not discoverable as `.exe`, cannot be code-signed.

## Key Windows Considerations for rackup

### 1. Shim Dispatcher (Critical)

The current shim dispatcher is a Bash script embedded in `shims.rkt`. On
Windows, this must be replaced with one of:

**Option A: Native `.exe` shim (recommended by ecosystem precedent)**
- A small compiled program (C or Rust) that reads its own filename, resolves the
  active toolchain, and delegates via `CreateProcessW()`.
- Could follow the Scoop model: `tool.exe` + `tool.shim` config file.
- Could follow the rustup model: all shims are hardlinks to a single
  `rackup-shim.exe` binary that inspects `argv[0]`.
- Pros: Works in all shells (cmd, PowerShell, bash), proper signal handling, can
  be code-signed.
- Cons: Requires compiling and distributing a native binary for Windows.

**Option B: PowerShell script shims**
- Each shim is a `.ps1` file that resolves the toolchain and invokes the real
  binary.
- Pros: No compilation needed, easy to generate.
- Cons: PowerShell-only (excludes cmd.exe users), execution policy issues, may
  need `.cmd` wrapper for cmd.exe compatibility.

**Option C: `.cmd` batch file shims**
- Simplest to implement.
- Cons: Known script termination bugs, fragile, not recommended by any mature
  toolchain manager.

**Recommendation**: Option A (native `.exe` shim). The rustup hardlink-to-single-binary
approach is the cleanest and most proven. Since rackup already has a Racket
runtime, an alternative is writing the shim dispatcher in Racket and compiling
it to a standalone `.exe` using `raco exe` -- this would keep the implementation
in a single language.

### 2. Bootstrap Installer

The current `install.sh` cannot run on Windows. Options:

**Option A: PowerShell bootstrap script (`install.ps1`)**
- Follows the GHCup model.
- `Invoke-WebRequest` replaces `curl`.
- Direct file operations replace `tar`, `chmod`.
- Modifies `HKCU\Environment\PATH` via the registry.
- Pros: Ships with all modern Windows, no external dependencies.
- Cons: Execution policy may need bypassing, separate script to maintain.

**Option B: Standalone `.exe` installer (like rustup-init.exe)**
- A compiled binary that handles everything.
- Pros: No script execution policy issues, can handle self-update elegantly.
- Cons: Requires compilation infrastructure, heavier to maintain.

**Option C: Distribution via Scoop/winget/Chocolatey**
- Package managers handle installation, PATH, and updates.
- Pros: Familiar to Windows users, handles updates.
- Cons: Less control over the install process, dependency on third-party infra.

**Recommendation**: PowerShell bootstrap script (Option A) as the primary
method, with Scoop/winget formulae as secondary distribution channels. The
PowerShell script should handle downloading the rackup source, setting up the
hidden runtime, and configuring PATH via the registry.

### 3. PATH Management

On Unix, rackup modifies `.bashrc`/`.zshrc` to add `$RACKUP_HOME/shims` to
PATH. On Windows:

- Modify `HKCU\Environment\PATH` in the registry (user-level, no admin needed).
- Use `REG_EXPAND_SZ` type to preserve `%VARIABLE%` references.
- Broadcast `WM_SETTINGCHANGE` to notify running applications.
- Also set `RACKUP_HOME` as a persistent user environment variable.

### 4. Shell Integration

On Unix, rackup provides shell functions for `rackup switch` (which sets
`RACKUP_TOOLCHAIN` in the current session). On Windows:

- **PowerShell**: Can provide a function via a script that users source in their
  `$PROFILE`. The `rackup init --shell powershell` command would generate/install
  this.
- **cmd.exe**: Very limited. Can only set `RACKUP_TOOLCHAIN` via
  `set RACKUP_TOOLCHAIN=...`. Could provide a `rackup.cmd` wrapper, but no
  equivalent to shell functions.
- **Windows Terminal**: Consider providing a Terminal profile (like juliaup
  does).

### 5. Symlinks

rackup uses symlinks extensively:
- Shims in `~/.rackup/shims/` -> dispatcher
- `toolchain/bin` -> `toolchain/install/bin` or `toolchain/install/racket/bin`
- `runtime/current` -> `runtime/versions/<id>`

On Windows:
- **User symlinks** require Developer Mode or `SeCreateSymbolicLinkPrivilege`.
  Most casual users do not have this enabled.
- **Directory junctions** work without admin but are always absolute paths.
- **Hardlinks** work for files but not directories, and only within the same
  volume.

**Options**:
- For file shims: Use hardlinks (like rustup) or shim `.exe` + `.shim` file
  pairs (like GHCup/Scoop).
- For directory links (toolchain `bin`, runtime `current`): Use directory
  junctions. Since rackup installs are not portable (they don't move between
  machines), absolute paths are acceptable.
- Alternatively, avoid symlinks entirely by using computed paths at runtime
  (the shim reads config to find the real binary path, no symlink needed).

### 6. Racket Windows Installers

Racket provides Windows installers in `.exe` format (NSIS-based GUI installer).
Key considerations:

- The `--in-place` and `--create-dir` flags work on Windows `.exe` installers
  when run from the command line (not just the GUI).
- Racket also provides `.tgz` archives for Windows that can be extracted
  directly.
- The installer's directory layout on Windows uses backslashes and may differ
  slightly from Linux (e.g., `racket\bin\racket.exe` vs `racket/bin/racket`).
- Racket CS versions on Windows produce `.exe` files for all tools.
- The `table.rktd` metadata already includes Windows installer filenames, so
  rackup's version resolution and installer selection code should work with
  minimal changes.

### 7. File Locking

Windows locks running executables, preventing deletion or replacement. This
affects:

- **Self-update** of rackup itself (if rackup is running, it can't replace its
  own binary). Rustup solves this with a multi-stage self-replace process.
- **Toolchain updates** if a shim process is running. If rackup uses hardlinks
  to a single shim binary, any running shim blocks updates to that binary.
- **Antivirus** software may hold additional locks during real-time scanning.

### 8. Long Paths

Windows `MAX_PATH` is 260 characters. With deeply nested toolchain paths like
`C:\Users\username\.rackup\toolchains\release-8.18-cs-x86_64-windows-full\install\racket\bin\racket.exe`,
this could be a concern. The registry setting `LongPathsEnabled` lifts this
limit on Windows 10+, but it's off by default.

**Mitigation**: Use a short default home directory (e.g., `C:\rackup` or
`%LOCALAPPDATA%\rackup` rather than `%USERPROFILE%\.rackup`). GHCup uses
`C:\ghcup` for this reason.

### 9. Hidden Runtime

rackup needs a Racket runtime to run its own Racket code. On Windows:

- The hidden runtime would be a Windows Racket installation.
- Racket provides both `.exe` installers and `.tgz` archives for Windows.
- The `.tgz` approach (download and extract) is simpler for programmatic
  installation and avoids GUI installer popups.
- The runtime's `racket.exe` would be used to run `rackup-core.rkt`.

### 10. CI/Testing

- Need Windows CI runners (GitHub Actions `windows-latest` or similar).
- No Docker-based E2E testing (Docker on Windows is more complex and less
  common in CI).
- Test both PowerShell and cmd.exe scenarios.
- Test with and without Developer Mode (affects symlink availability).

## Proposed Implementation Strategy

### Phase 1: Core Windows Compatibility
1. Make `paths.rkt` aware of the Windows filesystem (already partially done via
   `find-system-path`).
2. Create a native shim dispatcher for Windows (either compiled C/Rust binary or
   Racket-compiled `.exe`).
3. Add Windows installer execution support (run `.exe` installers with
   `--in-place --create-dir --dest` flags).
4. Handle symlink alternatives (junctions for directories, hardlinks or shim
   pairs for files).

### Phase 2: Windows Bootstrap
1. Write `install.ps1` PowerShell bootstrap script.
2. Implement registry-based PATH management.
3. Add PowerShell shell integration (equivalent to bash/zsh `rackup init`).
4. Handle hidden runtime installation on Windows.

### Phase 3: Polish and Testing
1. Add Windows CI jobs.
2. Handle edge cases: file locking, long paths, antivirus interference.
3. Add Scoop/winget distribution formulae.
4. Documentation and migration guides.

## Code Audit: Unix-Only Dependencies in rackup

This section catalogs every file and pattern that would need Windows-specific
handling.

### 1. Shim Dispatcher (shims.rkt:24-219) -- CRITICAL

The entire `dispatcher-script` function generates a Bash script that is the
core of how rackup dispatches shim invocations. This is the single most
important thing to replace. It uses: `#!/usr/bin/env bash`, `set -euo pipefail`,
`BASH_SOURCE[0]`, `basename`, `tr`, `od` (for ELF header inspection), `uname`,
`grep`, `/proc/sys/fs/binfmt_misc`, and `exec`.

On Windows, needs: a native `.exe` dispatcher or a compiled Racket executable.

### 2. Symlink Usage (12 call sites)

Files using `make-file-or-directory-link`:
- `install.rkt:227` -- toolchain bin directory link
- `install.rkt:237` -- overlay links for env.sh
- `shims.rkt:234` -- core rackup shim link
- `shims.rkt:284` -- all tool shims -> dispatcher
- `runtime.rkt:121` -- runtime `current` link

Files using `link-exists?` / `resolve-path`:
- `install.rkt:224,234,243,255,297` -- link management
- `shims.rkt:232,258,259,282` -- shim detection
- `runtime.rkt:51,53,115,211` -- runtime link management

On Windows: Need to use directory junctions (for directory links) or hardlinks/
shim file pairs (for file shims). `link-exists?` works on Windows for junctions.

### 3. File Permissions (13 call sites)

`file-or-directory-permissions` with octal modes (`#o755`, `#o644`):
- `install.rkt:126,213,286,310`
- `shims.rkt:226`
- `rktd-io.rkt:39,51`
- `runtime.rkt:73`
- `legacy.rkt:244`
- `main.rkt:962`
- `util.rkt:48`

On Windows: Octal permission modes are not supported. Racket's
`file-or-directory-permissions` on Windows returns a limited set. These calls
need platform-conditional behavior.

### 4. Shell Executable (util.rkt:69-70)

```racket
(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))
```

Used by: `install.rkt:155,161` (running Racket's `.sh` installer),
`main.rkt:981` (running install.sh for self-upgrade).

On Windows: Racket's Windows `.exe` installer is not run via a shell. Need
platform-specific installer execution logic.

### 5. Shell Integration (shell.rkt) -- Bash/Zsh Only

The entire `shell.rkt` module is bash/zsh specific:
- `bash-completion-script` (line 47)
- `zsh-completion-script` (line 194)
- RC file management for `.bashrc`/`.zshrc` (lines 350-430)
- Shell detection defaults to "bash" (line 333)

On Windows: Need PowerShell equivalents (`rackup.ps1` profile script,
PowerShell tab completions via `Register-ArgumentCompleter`).

### 6. Bootstrap Script (scripts/install.sh) -- POSIX Shell

The entire 303-line script is POSIX `sh`. Uses: `curl`/`wget`, `tar`, `chmod`,
`mktemp`, `find`, `sha256sum`/`shasum`, shell config editing.

On Windows: Need `install.ps1` PowerShell equivalent using
`Invoke-WebRequest`, `Expand-Archive`, registry PATH management.

### 7. Bootstrap Helper (libexec/rackup-bootstrap.sh) -- POSIX Shell

~420 lines of POSIX shell functions for: runtime selection, architecture
detection (`uname -m`), stable version lookup, installer candidate selection,
installer execution, lock file management.

On Windows: Need Racket or PowerShell equivalents for all of these.

### 8. Entry Point (bin/rackup) -- Bash Script

The `bin/rackup` wrapper is a Bash script that sanitizes environment variables
and invokes the Racket runtime.

On Windows: Need `rackup.cmd` or `rackup.exe` wrapper.

### 9. Subprocess Commands

External commands invoked via `system*`:
- `tar` -- for `.tgz` extraction (`runtime.rkt:96`, `install.rkt:191`)
- `rm -rf` -- for uninstall (`main.rkt:905`)
- `/bin/sh installer.sh` -- for Racket installer (`install.rkt:155`)
- `sha256sum`/`shasum`/`openssl` -- for checksum verification (`install.rkt:94-98`)
- `git` -- for source builds (`main.rkt:997`)

On Windows: `tar` is available on modern Windows 10+, `rm -rf` needs
`Remove-Item -Recurse -Force` or similar, SHA256 can use Racket's built-in
`file/sha1` module (already partially done per commit history).

### 10. Racket Windows Installer Considerations

Key finding from research: **Racket's Windows `.exe` installer does NOT support
`--in-place` or `--create-dir` flags.** These are Unix `.sh` installer only.
The Windows NSIS installer is GUI-based with no equivalent CLI automation flags.

However, Racket also provides `.tgz` archives for Windows which can be extracted
with `tar`. The `.tgz` approach is likely the best path for rackup on Windows,
avoiding the NSIS GUI entirely.

Additionally: **Racket's Windows installer does NOT modify PATH.** This means
rackup would be providing a genuinely useful improvement for Windows Racket
users by managing PATH automatically.

## Summary Comparison Table

| Aspect | rustup | GHCup | Volta | juliaup | Recommendation for rackup |
|--------|--------|-------|-------|---------|--------------------------|
| Bootstrap | `.exe` | PowerShell | MSI | Windows Store | PowerShell script |
| PATH | Registry | Registry | System PATH | App Aliases | Registry (user) |
| Shims | Hardlinks to `.exe` | `.exe` + `.shim` | Native `.exe` | Native `.exe` | Hardlinks or `.exe` + `.shim` |
| Shell support | cmd + PS + bash | cmd + PS + MSYS2 | cmd + PS + bash | All | cmd + PS minimum |
| Admin needed | No | No | Yes | No | No (goal) |
| Self-update | Multi-stage `.exe` | Binary replace | MSI update | Store update | TBD |
