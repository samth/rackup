## Comment 4: Platform-Specific Considerations and Proposed Plan

### Windows-Specific Concerns

**File Locking**: Windows locks running executables, preventing deletion/replacement. Affects self-update (rackup can't replace its own binary while running) and toolchain updates (running shims block binary replacement). Rustup solves this with a multi-stage self-replace + three-process uninstall trick. This is the single most complex Windows-specific issue.

**Symlinks**: User-level symlinks require Developer Mode or `SeCreateSymbolicLinkPrivilege`. Most users won't have this. Use directory junctions (work without privileges, but absolute paths only) for directory links and hardlinks for file shims. Or eliminate symlinks entirely by computing paths at runtime.

**Long Paths**: `MAX_PATH` is 260 characters. A path like `C:\Users\longusername\.rackup\toolchains\release-8.18-cs-x86_64-windows-full\install\racket\bin\racket.exe` could easily exceed this. Mitigation: use `%LOCALAPPDATA%\rackup` as default home (shorter than `%USERPROFILE%\.rackup`), or follow GHCup's lead with `C:\rackup`. Racket itself automatically converts long paths to `\\?\` form.

**Antivirus**: Windows Defender and other AV software may hold file locks during real-time scanning, interfere with binary execution, or flag unsigned executables. Code-signing rackup binaries is the long-term fix.

**PATH Management**: Modify `HKCU\Environment\PATH` via the registry. Must use `REG_EXPAND_SZ` type (not `REG_SZ`) to preserve `%VARIABLE%` references. Broadcast `WM_SETTINGCHANGE` to notify running applications. Racket's `ffi/winapi` or a small utility can do this.

**Atomic File Operations**: Racket's `call-with-atomic-output-file` is NOT atomic on Windows (documented limitation). `rktd-io.rkt`'s atomic write strategy may need adjustment.

### Proposed Phased Implementation

**Phase 1: Core Compatibility (minimal viable Windows support)**
1. Platform-conditional `paths.rkt`: Windows default home, path separators
2. Windows shim dispatcher: compiled Racket `.exe` or native binary using `argv[0]` dispatch
3. Installer execution: Use `.tgz` extraction on Windows instead of `.sh` installer execution
4. Replace symlinks with junctions (directories) and hardlinks (files)
5. Platform-conditional file permissions (no-op on Windows)

**Phase 2: Windows Bootstrap**
1. `install.ps1` PowerShell bootstrap script (equivalent to `install.sh`)
2. Registry-based PATH management (`HKCU\Environment`)
3. PowerShell shell integration (`rackup init --shell powershell`)
4. Hidden runtime installation on Windows (`.tgz` extraction)

**Phase 3: Polish and Ecosystem**
1. Windows CI jobs (GitHub Actions `windows-latest`)
2. File locking handling for self-update
3. Scoop manifest and/or winget package
4. cmd.exe `rackup.cmd` wrapper (limited -- no shell functions)
5. Documentation

### Shell Compatibility Target

| Shell | Version switching | Tab completion | Notes |
|-------|------------------|----------------|-------|
| PowerShell | Full (via profile function) | Yes (`Register-ArgumentCompleter`) | Primary Windows shell |
| cmd.exe | Shim-only (no `rackup switch`) | No (cmd has no completion API) | Basic support via `.exe` shims |
| Git Bash | Reuse existing bash integration | Reuse existing bash completions | Works if bash is installed |
| Windows Terminal | Works via any of the above | Depends on shell | Consider adding Terminal profile |

### What NOT to Do (lessons from other tools)

1. **Don't use `.bat`/`.cmd` script shims** -- the script termination bug is well-documented and affects pyenv-win, mise, and Chocolatey users regularly.
2. **Don't require admin privileges** -- rustup, GHCup, juliaup all work without admin. Volta requiring admin for MSI install is a friction point.
3. **Don't tie yourself to one Windows shell** -- SDKMAN's Bash-only approach left Windows users stranded. The `.exe` shim approach works in all shells.
4. **Don't ignore `MAX_PATH`** -- use short default paths and test with deeply nested toolchain directories.
5. **Don't assume symlinks work** -- they require Developer Mode on Windows. Always have a non-symlink fallback.
