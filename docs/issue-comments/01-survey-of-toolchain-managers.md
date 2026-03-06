## Comment 1: Survey of Toolchain Managers on Windows

### rustup (Rust) -- The Gold Standard

rustup has the most mature Windows implementation. Key design choices:

- **Bootstrap**: Standalone `rustup-init.exe` (native console app). No MSI, no PowerShell script. User downloads and runs it directly.
- **Shims**: All proxy executables (`cargo.exe`, `rustc.exe`, etc.) are **hardlinks to `rustup.exe`**. When invoked, rustup inspects `argv[0]` to determine which tool to dispatch. Falls back from symlinks to hardlinks since Windows symlinks require Developer Mode.
- **PATH**: Modifies `HKCU\Environment\PATH` in the registry using `REG_EXPAND_SZ` type. Broadcasts `WM_SETTINGCHANGE` so new terminal windows pick up the change.
- **Self-update**: Multi-stage process because a running `.exe` can't be deleted on Windows. Downloads new binary, spawns with `--self-replace`, waits for parent to exit.
- **Uninstall**: Three-process trick using `FILE_FLAG_DELETE_ON_CLOSE` to clean up.
- **Registry**: Creates uninstall entry at `HKCU\...\Uninstall\Rustup` for Add/Remove Programs.
- **Key pain points**: File locking (running processes block updates), Windows Defender SmartScreen on unsigned binaries, `MAX_PATH` 260-char limit, junction points vs symlinks.

### GHCup (Haskell) -- Shim Architecture Reference

- **Bootstrap**: PowerShell script (`bootstrap-haskell.ps1`) run via `Invoke-WebRequest | Invoke-Command`.
- **Shims**: Forked from Scoop's "better shimexe" -- a compiled C binary (`shim-2.exe`, ~113KB). For each tool: `tool.exe` (copy of shim binary) + `tool.shim` (text file: `path = C:\ghcup\ghc\9.6.6\bin\ghc.exe`). Handles GUI vs console app detection, Ctrl+C forwarding.
- **MSYS2**: Installs a full MSYS2 environment for build toolchain support.
- **Install location**: `C:\ghcup` -- deliberately short to avoid path issues.

### Volta (JavaScript) -- Seamless Design

- **Bootstrap**: MSI installer. Requires admin.
- **Shims**: Native `.exe` shims (Rust). Walks directory tree looking for `package.json` to determine version. Downloads missing versions transparently.
- **Key insight**: No shell hooks, no activation step. Version resolution is filesystem-based (project config files), works identically in interactive and non-interactive contexts.

### juliaup (Julia) -- Platform Integration

- **Bootstrap**: Distributed via **Windows Store** and `winget`. Uses **App Execution Aliases** (stubs in `%LOCALAPPDATA%\Microsoft\WindowsApps`, already on PATH). No PATH modification needed.
- **Shims**: Native Rust binary that reads config to resolve Julia version.
- **Key insight**: Windows Store provides auto-updates, trusted publisher status, no admin requirements.

### nvm-windows (Node.js) -- Junction Approach

- **Bootstrap**: Standard Windows installer (Go binary).
- **Version switching**: Uses a **directory junction** (`mklink /J`) at a fixed PATH location. `nvm use` updates the junction target. No shims at all.
- **Key issues**: Requires admin for junction creation. Cannot coexist with standalone Node.js install.

### pyenv-win (Python) -- Cautionary Tale

- **Shims**: `.bat` file shims that temporarily modify PATH.
- **Key issues**: `.bat` shims are the most fragile approach -- invisible to tools scanning for `.exe`, cause script termination bugs when called from batch files without `call`. Users must also disable Windows App Execution Aliases for `python.exe`.

### mise (polyglot) -- Evolution Story

- **Shims**: Configurable `windows_shim_mode` with four options: `exe` (native binary, default), `hardlink`, `symlink`, `file` (`.cmd` scripts).
- **Key lesson**: The migration from `.cmd` to native `.exe` shims was driven by the **`.cmd` script termination bug** -- a calling batch script stops after executing a `.cmd` shim without `call`. This is a well-known Windows behavior that bit pyenv-win, mise, and Chocolatey.

### Scoop (Windows package manager) -- Shim Reference Implementation

- **Shims**: Three files per tool: `tool.exe` (native C binary), `tool.shim` (config with `path = ...`), `tool.ps1` (PowerShell wrapper). Shim exe was rewritten from C# to C to eliminate .NET runtime overhead, fix Ctrl+C handling, and prevent orphaned processes. Open source at ScoopInstaller/Shim.
- **No admin required**: Entirely user-scoped.

### SDKMAN (JVM) -- Non-Starter

- **No native Windows support.** Bash-only, requires WSL2. A Microsoft-backed native port was archived in 2025. Serves as a cautionary example of what happens when you're too deeply tied to Unix shell.
