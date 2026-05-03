# Plan: Issue #22 (version command) and Issue #20 (refactor pre-6.1.1 handling)

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Issue #22: Add `version` command

### Context
rackup has no way to report its own version. Issue #22 requests a `version` command that prints build info (commit hash, build date, possibly a version number).

### Approach
Since there's no build system or release versioning yet, the version command will report the git commit hash and date at runtime by shelling out to `git`. For non-git installs (where git info isn't available), it will report "unknown". This avoids needing a build step to embed version info.

### Changes

**`libexec/rackup/main.rkt`:**
1. Add `cmd-version` function that prints version info:
   - Runs `git -C <repo-dir> rev-parse --short HEAD` and `git -C <repo-dir log -1 --format=%ci HEAD` to get commit and date
   - Falls back to "unknown" if git isn't available or fails
   - Prints `rackup <commit> (<date>)` or similar
2. Add `"version"` match clause in the `main` dispatch (line ~1014, before the catch-all)
3. Add `version` to the `usage` function help text
4. Add `version` case to `show-command-help`

**`test/version.rkt`** (new file):
- Test that `cmd-version` produces output containing a git commit hash pattern
- Test that the version output format is reasonable

**`test/all.rkt`:**
- Add `require` for `"version.rkt"`

---

## Issue #20: Refactor pre-6.1.1 handling to a separate file

### Context
Legacy/pre-6.1.1 code is spread across `remote.rkt` and `install.rkt`. Issue #20 asks to consolidate it into a separate file to reduce clutter. `legacy-plt-catalog.rkt` already exists as a standalone legacy module.

### Legacy code locations

**In `remote.rkt` (~260 lines to move):**
- `plt-scheme-download-base` constant (line 36)
- `legacy-installer-rx` regex (line 200-201)
- `parse-legacy-installer-filename` (lines 252-295)
- `parse-legacy-installers-index-html` (lines 297-305)
- `parse-plt-version-page-html` (lines 307-314)
- `select-legacy-installer-filename` (lines 340-363)
- `plt-version->hyphenated` (lines 365-366)
- `select-plt-generated-page-url` (lines 368-404)
- `plt-generated-page-url->installer-filename` (lines 406-411)
- `fetch-plt-scheme-installer-filename` (lines 413-424)
- `fetch-legacy-installer-filename` (lines 426-439)
- `version-maybe-plt-scheme?` (line 479-480)
- Legacy branch in `resolve-release-request/fallback` (lines 489-510, the PLT Scheme case)
- Legacy fallback branch (lines 538-556, the Apache index listing case)
- `legacy-installers-base-url-for-release` (lines 179-185)
- `plt-version-page-url` (lines 187-188)

**In `install.rkt` (~35 lines to move):**
- `legacy-interactive-linux-installer?` (lines 133-135)
- `legacy-installer-input-script` (lines 160-167)
- `detect-shell-installer-mode` (lines 142-158) — used for legacy detection
- `maybe-modernize-legacy-archsys!` (lines 594-605)

### Approach

Create a new file `libexec/rackup/legacy.rkt` that consolidates legacy functions from `remote.rkt` and `install.rkt`. The functions that are only used internally within `remote.rkt` and `install.rkt` will be required from `legacy.rkt` instead.

**`libexec/rackup/legacy.rkt`** (new file):
- Move all the legacy functions listed above from `remote.rkt` and `install.rkt`
- `provide` them for use by `remote.rkt` and `install.rkt`
- Keep `require` of `legacy-plt-catalog.rkt` (re-export what's needed)
- Also need `http-get-string` — this stays in `remote.rkt`, so the fetch functions that call it (`fetch-legacy-installer-filename`, `fetch-plt-scheme-installer-filename`) should stay in `remote.rkt` or take the HTTP function as a parameter

**Refined approach for the fetch functions:** Functions that depend on `http-get-string` (which depends on the HTTP stack in `remote.rkt`) will stay in `remote.rkt`. Only the pure parsing/selection functions move. This keeps the module boundary clean.

Functions to move to `legacy.rkt`:
- From `remote.rkt`: `plt-scheme-download-base`, `legacy-installers-base-url-for-release`, `plt-version-page-url`, `legacy-installer-rx`, `parse-legacy-installer-filename`, `parse-legacy-installers-index-html`, `parse-plt-version-page-html`, `select-legacy-installer-filename`, `plt-version->hyphenated`, `select-plt-generated-page-url`, `plt-generated-page-url->installer-filename`, `version-maybe-plt-scheme?`
- From `install.rkt`: `legacy-interactive-linux-installer?`, `detect-shell-installer-mode`, `legacy-installer-input-script`, `maybe-modernize-legacy-archsys!`

Functions that stay in `remote.rkt` (depend on HTTP):
- `fetch-legacy-installer-filename`, `fetch-plt-scheme-installer-filename`
- The legacy branches in `resolve-release-request/fallback` (they call the above)

**`remote.rkt`:** Remove moved functions, add `require "legacy.rkt"`, keep fetch functions.

**`install.rkt`:** Remove moved functions, add `require "legacy.rkt"`.

**`test/remote.rkt`:** Update imports if needed (tests already import from `remote.rkt` and `legacy-plt-catalog.rkt`).

**`test/all.rkt`:** No changes needed (legacy functions are tested through existing tests in `test/remote.rkt`).

---

## Verification

### Issue #22:
```bash
raco test -y test/version.rkt
raco test -y test/all.rkt
bin/rackup version
```

### Issue #20:
```bash
raco test -y test/all.rkt
# Verify that all existing tests still pass after the refactor
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/2603d122-f33e-4caf-afe3-ccd47e778cec.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
