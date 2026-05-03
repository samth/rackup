# Plan: Add flag-argument completions to bash and zsh

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Context

The shell completion currently lists flags as completable words, but when a flag takes an argument (e.g., `rackup install --distribution <TAB>`), no values are offered. The completion should detect when the previous word is a flag that takes an argument and complete the valid values.

## Changes

### `libexec/rackup/shell.rkt` — `bash-completion-script`

Add a `prev`-based dispatch **before** the existing `cmd`-based case in `_rackup()`. When `prev` matches a flag that takes an argument, complete the argument values and return early:

| `prev` | Values |
|--------|--------|
| `--variant` | `cs bc` |
| `--distribution` | `full minimal` |
| `--snapshot-site` | `auto utah northwestern` |
| `--arch` | `x86_64 aarch64 i386 arm riscv64 ppc` |
| `--shell` | `bash zsh` |
| `--toolchain` | `$(_rackup_toolchains)` |

Structure in the generated bash:

```bash
# flag argument completion
case "$prev" in
  --variant)      COMPREPLY=($(compgen -W "cs bc" -- "$cur")); return ;;
  --distribution) COMPREPLY=($(compgen -W "full minimal" -- "$cur")); return ;;
  --snapshot-site) COMPREPLY=($(compgen -W "auto utah northwestern" -- "$cur")); return ;;
  --arch)         COMPREPLY=($(compgen -W "x86_64 aarch64 i386 arm riscv64 ppc" -- "$cur")); return ;;
  --shell)        COMPREPLY=($(compgen -W "bash zsh" -- "$cur")); return ;;
  --toolchain)    COMPREPLY=($(compgen -W "$(_rackup_toolchains)" -- "$cur")); return ;;
esac
```

### `libexec/rackup/shell.rkt` — `zsh-completion-script`

Update the `install` case to use structured `_arguments` specs with value completions:

```zsh
install)
  _arguments \
    '::spec:(stable pre-release snapshot snapshot\:utah snapshot\:northwestern)' \
    '--variant[VM variant]:variant:(cs bc)' \
    '--distribution[Distribution type]:distribution:(full minimal)' \
    '--snapshot-site[Snapshot mirror]:site:(auto utah northwestern)' \
    '--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)' \
    '--set-default[Set as default]' \
    '--force[Force reinstall]' \
    '--no-cache[Skip download cache]' \
    '--quiet[Quiet output]' \
    '--verbose[Verbose output]'
  ;;
```

Similarly for `init` (`--shell`) and `which` (`--toolchain`).

### `test/shell-completion.rkt`

Add tests verifying the generated bash output contains flag-argument values (e.g., `"full minimal"`, `"cs bc"`).

## Verification

```bash
raco test -y test/shell-completion.rkt
raco test -y test/all.rkt
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/28f4869e-a661-477e-b3e6-e358047cdc02.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
