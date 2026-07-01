#lang racket/base

;; Single source of truth for the "rackup for agents" guide.
;;
;; `agent-guide-text` is printed verbatim by `rackup help agents`
;; (embedded in the compiled binary, so it works in the prebuilt exe)
;; and rendered to agents.html by the Pages build
;; (pages/build-pages-site.rkt).  `agent-snippet-text` is the short
;; paste-in block published at agents-snippet.md.
;;
;; The guide is Markdown: it reads fine as plain text in a terminal and
;; renders to HTML on the docs site.  Keep it in sync with the actual
;; command surface — test/agents-guide.rkt cross-checks
;; `agent-guide-referenced-commands` against commands-data.rkt so a
;; renamed/removed command cannot silently rot the guide.

(provide agent-guide-text
         agent-snippet-text
         agent-guide-referenced-commands)

(define agent-guide-text
  #<<RACKUP-AGENT-GUIDE-END
# Using rackup from an AI agent or automation

rackup is a toolchain manager for Racket: it installs Racket versions and
selects which one `racket`, `raco`, `scribble`, etc. resolve to. This is the
cheat sheet for driving rackup non-interactively — from CI, scripts, or a
coding agent. Print it any time with `rackup help agents`.

## TL;DR

    rackup install stable                  # install a toolchain (idempotent)
    rackup run stable -- racket --version  # run a tool under it, no shell setup
    rackup run stable -- raco test .       # run your project's tests
    rackup list --ids                      # installed toolchain IDs, one per line
    rackup which racket                    # real path of the active `racket`

The one rule that matters: to run a tool under a specific toolchain, use
`rackup run <toolchain> -- <command>`. It configures everything for that one
subprocess and needs no shell integration. Do not rely on `rackup switch` in
scripts (see Gotchas).

## Why `rackup run`, not `rackup switch`

`rackup switch` only takes effect through the shell function that `rackup init`
installs into an interactive `.bashrc`/`.zshrc`. A non-interactive shell
(`bash -c`, a CI step, an agent tool call) never loads that function, so

    rackup switch 8.18 && raco test .      # WRONG: runs the *default* toolchain

silently runs whatever the default toolchain is, not 8.18. `rackup run` has no
such dependency:

    rackup run 8.18 -- raco test .         # RIGHT: always 8.18

`rackup run` scopes `PLTHOME`, `PLTADDONDIR`, `PATH`, and `RACKUP_TOOLCHAIN` to
the subprocess only, and passes through any Racket env vars you already set.

## Machine-readable commands

Parse these line-oriented outputs; do not scrape the human-formatted tables:

- `rackup list --ids` — installed toolchain IDs, one per line
- `rackup current id` — the active toolchain ID, or blank if none
- `rackup current line` — the active ID, a TAB, then `env` or `default`
- `rackup default status` — `set`, a TAB, then the ID; or just `unset`
- `rackup which racket` — absolute path of a tool in the active toolchain
- `rackup which raco --toolchain 8.18` — absolute path in a specific toolchain
- `rackup available` — installable versions and channels

## Toolchain specs

A `<toolchain>` is either an installed ID (see `rackup list --ids`) or, for
`rackup install`, one of:

- a release number: `8.18`, `7.9`, `4.2.5`
- `stable` — the current stable release
- `pre-release` — the latest pre-release build
- `snapshot`, `snapshot:utah`, `snapshot:northwestern` — the latest snapshot

Pin an explicit version when you need reproducibility; use `stable` when you
just want a working Racket.

## Recipes

Install and test under a specific version:

    rackup install 8.18
    rackup run 8.18 -- raco test .

Read the Racket version string programmatically:

    rackup run stable -- racket -e '(display (version))'

Install packages into a toolchain's addon dir:

    rackup run stable -- raco pkg install --auto gregor

Use a locally built Racket checkout:

    rackup link dev ~/src/racket
    rackup run dev -- racket --version

Find the real binary (e.g. to hand an absolute path to another tool):

    rackup which racket
    rackup which raco --toolchain 8.18

Check what is installed / active before acting:

    rackup list --ids
    rackup current line

## Non-interactive behavior

- rackup does not hang waiting for input when there is no terminal. Asking to
  `run`/`default`/`switch` a toolchain that is not installed errors
  immediately, hinting that you should run `rackup install <spec>` first,
  rather than blocking on a prompt. So always install before you use.
- `rackup install` is idempotent: re-running with an already-installed spec is
  a no-op (add `--force` to reinstall), so it is safe to run unconditionally.
- Quiet a noisy install with `rackup install <spec> --quiet`.
- The only destructive command that prompts is `rackup uninstall`; it refuses
  to run without a terminal unless you pass
  `--dangerously-delete-without-prompting`. Do not run it in automation unless
  that is the explicit goal.

## Exit codes

- `0` — success
- `1` — runtime error (network, filesystem, internal)
- `2` — usage error (unknown command or bad flags) or "toolchain not installed"

Branch on the exit status; do not match on stderr text.

## Anti-patterns

- Avoid `rackup switch X && raco ...` in a script — it runs the default
  toolchain. Use `rackup run X -- raco ...` instead.
- Avoid assuming a toolchain exists. Install it first: `rackup install X`.
- Avoid parsing `rackup list` or `rackup doctor` for state. Use
  `rackup list --ids`, `rackup current line`, `rackup default status`, and
  `rackup which` instead.
- Avoid editing `~/.rackup` by hand. Use rackup commands; the on-disk layout is
  internal and may change.

## Drop this into your project's AGENTS.md / CLAUDE.md

A short version of the above, suitable for pasting into a project so other
agents know how to run its Racket toolchain, is published at
<https://samth.github.io/rackup/agents-snippet.md>.
RACKUP-AGENT-GUIDE-END
  )

(define agent-snippet-text
  #<<RACKUP-AGENT-SNIPPET-END
## Racket via rackup

This project's Racket toolchain is managed by
[rackup](https://samth.github.io/rackup/).

- Run Racket tools through the toolchain with `rackup run <toolchain> -- <cmd>`,
  e.g. `rackup run stable -- raco test .`. Do NOT use `rackup switch` in
  scripts — it only takes effect in interactive shells.
- Install the toolchain first if needed: `rackup install stable` (idempotent).
- Machine-readable state: `rackup list --ids`, `rackup current line`,
  `rackup which racket`.
- Full agent guide: `rackup help agents`.
RACKUP-AGENT-SNIPPET-END
  )

;; Commands the guide teaches.  test/agents-guide.rkt asserts each is a
;; real subcommand (present in commands-data.rkt) and is actually
;; mentioned in the guide text, so the guide cannot reference a command
;; that has been renamed or removed.
(define agent-guide-referenced-commands
  '("install" "run"
              "list"
              "which"
              "current"
              "default"
              "available"
              "link"
              "switch"
              "uninstall"
              "help"))
