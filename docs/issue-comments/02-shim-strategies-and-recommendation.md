## Comment 2: Shim Strategies Ranked and Recommendation

### Ranking by Windows Robustness

1. **Native `.exe` shims** (rustup, Volta, juliaup, Scoop, mise, GHCup) -- Works in all shells (cmd.exe, PowerShell, Git Bash), supports signal forwarding, can be code-signed, no script termination bugs. The gold standard.
2. **Directory junctions** (nvm-windows) -- Simple, works everywhere via filesystem redirection, but requires admin and changes are global (all shells see same version).
3. **PATH manipulation** (uru, SDKMAN) -- Session-scoped, no per-directory version switching without shell hooks.
4. **PowerShell script shims** (rbenv-for-windows) -- Works within PowerShell only; excludes cmd.exe users entirely.
5. **`.bat`/`.cmd` script shims** (pyenv-win, mise legacy) -- Most fragile. Known script termination bugs, not discoverable as `.exe` by PATH scanning tools, cannot be code-signed.

### Recommendation for rackup

**Use the rustup hardlink-to-single-binary model.** Rationale:

- rackup already uses a single dispatcher script that all shim symlinks point to. The Windows equivalent is a single `rackup-shim.exe` that all shim hardlinks point to.
- The shim inspects `argv[0]` to determine the tool name, reads `%RACKUP_HOME%\state\default-toolchain` to resolve the active toolchain, then delegates to `%RACKUP_HOME%\toolchains\<id>\bin\<tool>.exe`.
- Hardlinks don't require admin privileges, Developer Mode, or special permissions.
- All shims share one binary, so updates only need to replace one file (plus recreate hardlinks).

**Implementation options for the shim binary**:

A. **Compiled Racket executable** via `raco exe`: Keep everything in one language. The shim would be a small Racket program that reads the default-toolchain file, constructs the target path, and uses `subprocess` to delegate. Downside: `raco exe` produces relatively large binaries (~10-20MB) and has non-trivial startup time due to Racket runtime initialization.

B. **Small C program** (~200 lines): Following the Scoop model. Fast startup, tiny binary. Reads its own filename, opens `default-toolchain` file, constructs path, calls `CreateProcessW()`. Downside: introduces a C build dependency.

C. **Rust binary** (~100 lines): Similar to C but with better ergonomics. Following Volta/juliaup. Downside: introduces a Rust build dependency.

**Tentative recommendation**: Option A (compiled Racket) for initial implementation since it avoids new language dependencies and rackup already needs Racket to build. If startup latency proves problematic, migrate to Option B (C) later. The Scoop shim C code is open source and could be adapted.
