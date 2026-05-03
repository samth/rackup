# Plan: Issue #9 — Add shell completion support

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Context

rackup has no shell completion. Issue #9 requests bash and zsh completions. The shell init system (`shell.rkt`) already writes helper scripts to `~/.rackup/shell/rackup.bash` and `~/.rackup/shell/rackup.zsh` and sources them from managed blocks in rc files. Currently both files get identical POSIX content. This plan adds completion code to those scripts.

Fish is deferred — the init system only supports bash/zsh today.

## Approach: Static completions embedded in shell helper scripts

Completions are generated at `rackup init` time as part of the shell helper scripts. Dynamic data (installed toolchain IDs) is resolved at completion time via filesystem listing. No new subcommand needed.

## Changes

### `libexec/rackup/shell.rkt`

1. **Add `bash-completion-script` function** — returns bash completion code string:
   - `_rackup_toolchains()` helper: lists dirs under `$RACKUP_HOME/toolchains/`
   - `_rackup()` completion function using `COMP_WORDS`/`COMP_CWORD` (no dependency on `bash-completion` package)
   - First-word completion: all 20 commands
   - Per-command completions: flags, subcommands, dynamic toolchain IDs where appropriate
   - `complete -F _rackup rackup`

2. **Add `zsh-completion-script` function** — returns zsh completion code string:
   - `_rackup_toolchains()` helper (same logic)
   - `_rackup()` using `_arguments`/`_describe` for structured completions with descriptions
   - `compdef _rackup rackup`

3. **Modify `shell-helper-script`** — take a `shell-name` parameter, append shell-specific completion code:
   - `(define (shell-helper-script shell-name)` instead of `(define (shell-helper-script)`
   - Append `(bash-completion-script)` or `(zsh-completion-script)` based on shell-name

4. **Update `init-shell!`** — pass shell name to `shell-helper-script`:
   - Change `(write-string-file p (shell-helper-script))` to `(write-string-file p (shell-helper-script s))`

### Command tree for completions

| Command | Completions |
|---|---|
| `available` | `--all --limit` |
| `install` | specs: `stable pre-release snapshot snapshot:utah snapshot:northwestern`; flags: `--variant --distribution --snapshot-site --arch --set-default --force --no-cache --quiet --verbose` |
| `link` | `--set-default --force` (+ directory completion for path) |
| `list` | (none) |
| `default` | `id status set clear --unset` + toolchain IDs |
| `current` | `id source line` |
| `which` | `--toolchain` |
| `switch` | `--unset` + toolchain IDs |
| `shell` | `--deactivate` + toolchain IDs |
| `run` | toolchain IDs |
| `prompt` | `--long --short --raw --source` |
| `remove` | toolchain IDs |
| `reshim` | (none) |
| `init` | `--shell` |
| `uninstall` | `--yes` |
| `self-upgrade` | `--with-init` |
| `runtime` | `status install upgrade` |
| `doctor` | (none) |
| `version` | (none) |
| `help` | command names |

### `test/shell-completion.rkt` (new)

- Test that `shell-helper-script "bash"` output contains `complete -F _rackup rackup`
- Test that `shell-helper-script "zsh"` output contains `compdef _rackup rackup`
- Test that both contain all command names
- Test that `shell-helper-script "bash"` differs from `shell-helper-script "zsh"`

### `test/all.rkt`

- Add `require` for `"shell-completion.rkt"`

## Verification

```bash
raco test -y test/shell-completion.rkt
raco test -y test/all.rkt
# Manual: run `rackup init`, start new shell, type `rackup <TAB>`
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/a59bc2ec-709d-4921-aadd-3323e397a829.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
