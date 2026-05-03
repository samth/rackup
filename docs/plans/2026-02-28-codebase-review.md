# AI Code Review: rackup

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Executive Summary

Rackup is a well-architected Racket toolchain manager with a clean Bash/Racket hybrid design. The codebase is mature, thoroughly tested, and handles an impressively wide range of Racket versions spanning 40+ years. The code is production-quality with thoughtful error handling, good separation of concerns, and comprehensive CI/E2E test coverage.

The most significant issues are a potential command injection vulnerability in the uninstall path, a race condition in state file writes, and the use of `read` on untrusted network data. There are also a handful of logic edge cases and minor robustness concerns. Overall, the codebase is in good shape; remediation effort is low (a few hours for the critical items, a day or two for the full list).

## Critical Issues (Must Fix)

### 1. Unsafe `read` on untrusted network data

- **Category**: Security Issues
- **Location**: `libexec/rackup/remote.rkt:108-110`
- **Problem**: `http-get-rktd` fetches data from remote servers and passes it to Racket's `read`, which can evaluate arbitrary code via `#lang` lines, reader extensions, and other Racket reader features. A compromised or MITM'd server could serve a malicious `.rktd` payload that executes code during deserialization.
- **Fix**: Use a restricted reader. Replace:
  ```racket
  (define (http-get-rktd url-str)
    (define s (http-get-string url-str))
    (define in (open-input-string s))
    (begin0 (read in)
      (close-input-port in)))
  ```
  with a call that disables reader extensions:
  ```racket
  (define (http-get-rktd url-str)
    (define s (http-get-string url-str))
    (define in (open-input-string s))
    (parameterize ([read-accept-reader #f]
                   [read-accept-lang #f])
      (begin0 (read in)
        (close-input-port in))))
  ```
  The same concern applies to `read-rktd-file` in `rktd-io.rkt:20` (local files), though that's lower risk since the user controls local files.

### 2. Command injection in `cmd-uninstall` cleanup

- **Category**: Security Issues
- **Location**: `libexec/rackup/main.rkt:832`
- **Problem**: The `cleanup-cmd` string is constructed with `sh-single-quote` but then passed to `sh -c` with ` &` appended. While `sh-single-quote` is implemented correctly, the pattern of constructing shell commands by string concatenation is fragile. If `RACKUP_HOME` were set to a value containing a quote character followed by shell metacharacters (unlikely but possible), it could break the quoting. More importantly, this deferred `sleep 1; rm -rf ...` cleanup approach means the deletion happens in an unmonitored background process with no error reporting.
- **Fix**: Instead of background shell command construction, use `delete-directory/files` directly and handle the "deleting own code" problem by copying critical files to a temp location first, or accept that the process may fail partway through deletion (which is fine since it's an uninstall). If the background approach is kept, add validation that `home-path` looks reasonable before deletion.

### 3. Non-atomic state file writes risk corruption

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/rktd-io.rkt:31-37`
- **Problem**: `write-rktd-file` and `write-string-file` use `truncate/replace`, which overwrites the file in place. If the process is interrupted (crash, SIGKILL, disk full) during the write, the file will be corrupted (truncated or partially written). The index file (`index.rktd`) is critical state; corruption means losing the list of installed toolchains.
- **Fix**: Write to a temporary file in the same directory, then atomically rename:
  ```racket
  (define (write-rktd-file path v)
    (make-directory* (or (path-only path) "."))
    (define tmp (make-temporary-file "rktd-~a" #f (path-only path)))
    (call-with-output-file* tmp #:exists 'truncate/replace
      (lambda (out) (write v out) (newline out)))
    (rename-file-or-directory tmp path #t))
  ```

## Serious Issues (Should Fix)

### 4. `rackup_warn_missing_loader` suppresses its own output

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/shims.rkt:129-131`
- **Problem**: `rackup_warn_missing_loader` redirects stdout to `/dev/null`, but `rackup_print_missing_loader_message` writes its diagnostic messages to stderr. The function does nothing useful because it calls `rackup_print_missing_loader_message` but discards stdout (which was already empty since the function writes to stderr). The intent appears to be calling the function only for its exit code side-effect, but the `>/dev/null` redirect is misleading and the function is called on line 142 where it would be more useful to actually print the warning.
- **Fix**: On line 142, call `rackup_print_missing_loader_message` directly instead of `rackup_warn_missing_loader`, or fix the wrapper to actually do something useful.

### 5. `capture-program-output` doesn't restore unset env vars correctly

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/install.rkt:534-536`
- **Problem**: When restoring environment variables, if the original value was `#f` (not set), the code calls `(putenv k "")` instead of unsetting the variable. Racket's `putenv` with an empty string sets the variable to empty, which is different from unsetting it. This can affect programs that check whether a variable is set vs. empty (e.g., `PLTHOME`). The same issue exists in `test/state-shims.rkt:29`.
- **Fix**: There's no `unsetenv` in `racket/base`, but the current behavior can be documented as a known limitation, or use FFI to call `unsetenv`. At minimum, add a comment explaining the limitation.

### 6. Missing validation of toolchain ID in filesystem paths

- **Category**: Security Issues
- **Location**: `libexec/rackup/paths.rkt:96-106`
- **Problem**: Toolchain IDs are used directly in path construction (`build-path (rackup-toolchains-dir) id`). While `sanitize-id-part` exists in `versioning.rkt` and is used for local toolchain names, remote-derived canonical IDs are built by string concatenation without full sanitization. A malicious `table.rktd` or version string containing `..` or `/` could theoretically cause path traversal.
- **Fix**: Add validation in `canonical-toolchain-id` or at the point where IDs are used in path construction, ensuring they don't contain path separators or `..` sequences:
  ```racket
  (define (safe-toolchain-id? id)
    (and (string? id)
         (not (string-contains? id "/"))
         (not (string-contains? id ".."))
         (not (string-blank? id))))
  ```

### 7. Duplicate `capture-program-output` and `shell-exe` definitions

- **Category**: Architecture and Design Problems
- **Location**: `libexec/rackup/install.rkt:515`, `libexec/rackup/runtime.rkt:151`, `libexec/rackup/install.rkt:132`, `libexec/rackup/runtime.rkt:20`
- **Problem**: `capture-program-output` is defined in both `install.rkt` (with env var support) and `runtime.rkt` (without). `shell-exe` is defined identically in both files. This is a copy-paste duplication that could lead to behavioral divergence.
- **Fix**: Move the more capable version of `capture-program-output` and `shell-exe` to `util.rkt` and use it from both modules.

### 8. HTTP connections are not closed on error paths

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/remote.rkt:70-99`
- **Problem**: In `http-open/input`, when `status-code` returns `#f` (unparseable status line), the input port `in` is never closed, leaking the connection. The `close-input-port` call only happens on redirect or non-200 status paths that were explicitly handled.
- **Fix**: Add a catch-all to close the port when `code` is `#f`:
  ```racket
  [(not code)
   (close-input-port in)
   (rackup-error "could not parse HTTP status line: ~a" (url->string u))]
  ```

### 9. `link-toolchain!` recursive call with same `opts` on `--force`

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/install.rkt:756-761`
- **Problem**: When `--force` is specified and the toolchain already exists, `link-toolchain!` deletes the directory and calls itself recursively with the same `opts` (which still contains `--force`). If the second call somehow also finds the directory exists (e.g., a race with another process), this could loop. The same pattern exists in `install-toolchain!` at line 824-828.
- **Fix**: After deleting the directory, fall through to the `else` branch rather than recursing. Or pass modified opts without `--force` on the recursive call.

## Minor Issues (Nice to Fix)

### 10. Dead code: `rackup_warn_missing_loader` function

- **Category**: Dead Code and Phantom Features
- **Location**: `libexec/rackup/shims.rkt:129-131` (in the heredoc Bash script)
- **Problem**: The `rackup_warn_missing_loader` function redirects stdout to `/dev/null` while the inner function writes to stderr. This makes it functionally a no-op wrapper. It's used on line 142 but doesn't add value over calling `rackup_print_missing_loader_message` directly.
- **Fix**: Remove `rackup_warn_missing_loader` and call `rackup_print_missing_loader_message` directly on line 142.

### 11. Legacy PLT Scheme URLs use HTTP, not HTTPS

- **Category**: Security Issues
- **Location**: `libexec/rackup/remote.rkt:35`, `libexec/rackup/legacy-plt-catalog.rkt` (all URLs)
- **Problem**: The PLT Scheme download URLs use `http://download.plt-scheme.org/` without TLS. Installers are fetched over unencrypted HTTP, making them vulnerable to MITM attacks. The SHA256 checksums in the catalog mitigate this for versions that have them, but the initial page fetch and older versions without checksums are unprotected.
- **Fix**: Check whether `https://download.plt-scheme.org/` works and prefer it. If the domain doesn't support HTTPS, document the risk and ensure SHA256 verification is mandatory for HTTP downloads.

### 12. `path-basename-string` crashes on paths without a filename component

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/util.rkt:68-69`
- **Problem**: `file-name-from-path` returns `#f` for root paths or paths ending in `/`. Calling `path->string` on `#f` will raise an error. This is called from several places including `installer-cache-file` in `install.rkt:71`.
- **Fix**: Add a guard:
  ```racket
  (define (path-basename-string p)
    (define name (file-name-from-path p))
    (if name (path->string name) (path->string p)))
  ```

### 13. Unused function `maybe-string->symbol`

- **Category**: Dead Code and Phantom Features
- **Location**: `libexec/rackup/util.rkt:71-75`
- **Problem**: `maybe-string->symbol` is defined and exported by `util.rkt` but is never used anywhere in the codebase.
- **Fix**: Remove the function and its `provide` entry.

### 14. `installed-toolchain-metas/safe` silently returns partial results

- **Category**: Fake or Shallow Error Handling
- **Location**: `libexec/rackup/main.rkt:768-771`
- **Problem**: The function catches all exceptions and returns an empty list on any failure, even partial failures where some metas were read successfully. The `for/list` with `and` means broken meta files return `#f` entries that are then treated as valid list elements, though most consumers filter them.
- **Fix**: Not necessarily wrong for a "safe" variant, but the `#f` entries should be filtered out:
  ```racket
  (filter hash? (for/list ...))
  ```

### 15. `IFS` save/restore in `rackup_find_system_racket` may not handle unset IFS

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `libexec/rackup/rackup-bootstrap.sh:432`
- **Problem**: `oldifs="${IFS:- }"` defaults to a space if IFS is unset, but `IFS` being unset is semantically different from IFS being set to a space in POSIX sh (unset IFS causes word splitting on space, tab, and newline; IFS=" " causes splitting only on space). This is a subtle distinction that rarely matters in practice but could cause issues in unusual environments.
- **Fix**: Save whether IFS was set and restore appropriately, or note this as an acceptable approximation.

### 16. Copy button SVG innerHTML replacement loses SVG content

- **Category**: Logic Errors and Incorrect Implementations
- **Location**: `pages/site.rkt:353-360`
- **Problem**: The clipboard copy handler sets `copyBtn.textContent = "Copied"`, which replaces the SVG icon with plain text. When the timeout fires and restores `old`, `textContent` was saved from the text content which is empty (SVG has no text content), so the button becomes empty.
- **Fix**: Use `innerHTML` instead of `textContent` for the save/restore, or toggle a CSS class.

### 17. Overlapping `or` in `parse-install-spec`

- **Category**: AI-Specific Code Smells
- **Location**: `libexec/rackup/versioning.rkt:75-76`
- **Problem**: `(or (equal? spec "stable"))` uses `or` with a single argument, which works but is misleading. It looks like a leftover from when there were multiple alternatives. Same on line 77 and 82.
- **Fix**: Remove the unnecessary `or` wrappers:
  ```racket
  [(equal? spec "stable") ...]
  ```

### 18. `string-blank?` uses regex where `string-trim` + `string=?` would suffice

- **Category**: AI-Specific Code Smells
- **Location**: `libexec/rackup/util.rkt:34-35`
- **Problem**: `string-blank?` uses a regex `#px"^\\s*$"` for what's essentially checking if a string is empty after trimming. This compiles and matches a regex on every call. Minor performance concern given how often it's called (every shim resolution checks environment variables).
- **Fix**: Replace with `(string=? "" (string-trim s))` for clarity, or keep as-is since the performance impact is negligible.

## Positive Observations

- **Clean architecture**: The Bash/Racket split is well-chosen. Bash handles low-latency operations (prompt, shim dispatch) while Racket handles complex logic (version parsing, network, install orchestration). This avoids Racket startup overhead for the hot path.

- **Comprehensive legacy support**: The `legacy-plt-catalog.rkt` with hardcoded SHA256 checksums for PLT Scheme versions going back to v053 is an impressive feat of historical preservation. The fallback chain in `resolve-release-request/fallback` handles 4 different installer discovery methods gracefully.

- **Thorough testing**: The test suite covers version parsing, installer filename parsing, shell integration (managed block insertion/removal), state management, platform target selection, and legacy format handling. The E2E Docker tests cover 10+ scenarios including cross-architecture QEMU probes.

- **Defensive error handling**: Errors are specific and actionable (e.g., suggesting `--arch i386` when only i386 installers are available). The `doctor` command provides useful diagnostics. The `preflight-request-install!` check for missing 32-bit loader is a nice touch.

- **Safe state management**: The dual default storage (file + index) provides robustness. The orphan toolchain detection and cleanup in `cmd-remove` handles partially-installed state gracefully.

- **Shell integration**: The managed RC block approach with start/end markers is clean and idempotent. The shell helper function correctly handles the `eval` pattern for `switch`/`shell` commands with proper error status propagation.

- **No external runtime dependencies**: The bootstrap works with only curl/wget and tar, and the Racket code uses the built-in `net/http-client` rather than shelling out. This is a deliberate and good design choice.

## Recommended Next Steps

1. **Fix unsafe `read` on network data** (Issue 1) - Highest priority. Add `read-accept-reader` and `read-accept-lang` guards.
2. **Fix non-atomic file writes** (Issue 3) - Use rename-based atomic writes for state files.
3. **Review uninstall cleanup approach** (Issue 2) - Consider simpler deletion strategies.
4. **Add toolchain ID path validation** (Issue 6) - Prevent path traversal from malicious metadata.
5. **Fix HTTP connection leak** (Issue 8) - Close port on unparseable status lines.
6. **Deduplicate `capture-program-output` and `shell-exe`** (Issue 7) - Move to `util.rkt`.
7. **Evaluate HTTPS for PLT Scheme URLs** (Issue 11) - Check if the domain supports TLS.
8. **Clean up minor dead code and style issues** (Issues 10, 13, 17) - Quick cleanup pass.
