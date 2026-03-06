## Comment 3: Code Audit -- Unix-Only Dependencies

Every file and pattern that needs Windows-specific handling:

### Critical Path (must change for Windows to work at all)

**1. Shim Dispatcher (`shims.rkt:24-219`)**
The `dispatcher-script` function generates a 200-line Bash script. Uses `#!/usr/bin/env bash`, `BASH_SOURCE[0]`, `od` (ELF headers), `uname -m`, `grep`, `/proc/sys/fs/binfmt_misc`. Must be replaced with a native `.exe` on Windows.

**2. Shell Executable (`util.rkt:69-70`)**
```racket
(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))
```
Used by `install.rkt:155,161` to run Racket's `.sh` installer and by `main.rkt:981` for self-upgrade. On Windows, Racket's `.exe` installer or `.tgz` extraction must be used instead.

**3. Bootstrap (`scripts/install.sh`, `libexec/rackup-bootstrap.sh`)**
300+ lines of POSIX `sh` using `curl`/`wget`, `tar`, `chmod`, `mktemp`, `sha256sum`. Plus ~420 lines of bootstrap helper functions. Need PowerShell equivalents.

**4. Entry Point (`bin/rackup`)**
Bash wrapper script. Needs `rackup.cmd` or `rackup.exe` equivalent.

### Important (functionality gaps without these)

**5. Symlinks (12 call sites across 4 files)**
- `install.rkt`: toolchain bin link, overlay links (lines 224-297)
- `shims.rkt`: shim creation (lines 232-284)
- `runtime.rkt`: runtime `current` link (lines 51-211)

Windows alternatives: directory junctions for directory links, hardlinks or shim file pairs for file links. `link-exists?` and `resolve-path` work on Windows for junctions.

**6. File Permissions (13 call sites)**
`file-or-directory-permissions` with `#o755`/`#o644` in `install.rkt`, `shims.rkt`, `rktd-io.rkt`, `runtime.rkt`, `legacy.rkt`, `main.rkt`, `util.rkt`. Windows doesn't support Unix octal permissions. Need conditional behavior.

**7. Shell Integration (`shell.rkt` -- entire file)**
Bash/Zsh only: completion scripts, RC file block management. Need PowerShell equivalents: `rackup init --shell powershell`, `Register-ArgumentCompleter`.

### Lower Priority (needed for full parity)

**8. Subprocess Commands**
- `tar` -- used for `.tgz` extraction. Available on Windows 10+ natively.
- `rm -rf` -- used for uninstall (`main.rkt:905`). Need `Remove-Item -Recurse -Force` or Racket's `delete-directory/files`.
- `sha256sum`/`shasum`/`openssl` -- for checksums. Could use Racket's `file/sha1` instead (partially done).
- `git` -- for source builds. Works on Windows.

**9. Racket `.exe` Installer Limitations**
Racket's Windows NSIS installer does NOT support `--in-place` or `--create-dir` CLI flags. These are Unix `.sh` installer only. The `.tgz` archive extraction approach is likely the best path for rackup on Windows, bypassing the GUI installer entirely. Key finding: Racket's Windows installer also does NOT modify PATH, meaning rackup adds genuine value for Windows Racket users.

**10. Platform Detection (`versioning.rkt:131`, `install.rkt:663`)**
`(system-type 'machine)` and `(system-type 'os)` are already used and would correctly return Windows values. The `table.rktd` metadata already includes Windows installer filenames. Version resolution should work with minimal changes.
