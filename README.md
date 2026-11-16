# rackup

A toolchain manager for [Racket](https://racket-lang.org). Install and switch between stable releases, pre-releases, snapshots, old PLT Scheme builds, and local source trees.

## Install

```bash
curl -fsSL https://samth.github.io/rackup/install.sh | sh
```

For non-interactive mode (no prompts):

```bash
curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y
```

This installs `rackup` itself. Then install a Racket toolchain:

```bash
rackup install stable
```

Set up shell integration so that `racket`, `raco`, etc. resolve through rackup shims:

```bash
rackup init --shell bash   # or zsh
```

## Usage

### Install toolchains

```bash
rackup install stable                    # current stable release
rackup install 8.18                      # specific version
rackup install pre-release               # latest pre-release build
rackup install snapshot                  # latest snapshot build
rackup install snapshot:utah             # snapshot from a specific mirror
rackup install 4.2.5                     # historical PLT Scheme release
```

### Switch between toolchains

```bash
rackup default stable                    # set the global default
rackup switch 8.18                       # switch in the current shell only
rackup run snapshot -- raco test .       # run a command under a specific toolchain
```

### Link local source trees

```bash
rackup link dev ~/src/racket             # link a local Racket build
rackup link dev ~/src/racket --set-default
```

A linked checkout uses its own `compiled/` directories and its own user-scope
packages, exactly as when you run its `bin/racket` and `raco` directly, so
`make` in the checkout and the shims always agree. See
[Upgrading linked checkouts](#upgrading-linked-checkouts) if you linked one
with an earlier rackup.

### Other commands

```bash
rackup list                              # list installed toolchains
rackup available                         # list installable versions
rackup current                           # show active toolchain and source
rackup which racket                      # show real executable path
rackup remove 8.18                       # remove a toolchain
rackup prompt                            # toolchain info for shell prompt
rackup doctor                            # print diagnostics
rackup self-upgrade                      # upgrade rackup itself
```

## Platforms

rackup supports Linux (x86_64, aarch64, i386, arm32) and macOS (x86_64, aarch64). It works with both bash and zsh.

Prebuilt binaries are available for all supported platforms. On platforms without a prebuilt binary, the installer bootstraps from source using a hidden internal Racket runtime.

## Shell integration

After running `rackup init`, your shell gets:

- Shims on `PATH` so `racket`, `raco`, `scribble`, `drracket`, etc. resolve to the active toolchain
- A `rackup` shell function so `rackup switch` takes effect immediately in the current shell
- Per-toolchain `PLTHOME` and `PLTADDONDIR` management

Add toolchain info to your prompt:

```bash
PS1='$(rackup prompt) '$PS1
```

## macOS: GUI apps in Finder (opt-in)

rackup launches GUI tools like DrRacket through shims from the command line,
so by default they don't show up in Finder, Spotlight, or the Dock. Opt in to
wrapper apps in `~/Applications`:

```bash
rackup install stable --mac-apps   # at install time
rackup reshim --mac-apps            # or enable any time afterward
```

This creates a wrapper `.app` in `~/Applications` for each GUI app the
toolchain ships (DrRacket, GRacket, Slideshow, …). The wrappers launch the
**default** toolchain's tools, so they follow `rackup default`. They also work
as drag-and-drop targets and file handlers: drop a `.rkt` on the DrRacket
wrapper, or double-click one in Finder, and it opens in DrRacket — the same
file associations the standard DrRacket install registers. rackup only manages
bundles it created (marked internally); your own apps are never touched. To
delete the wrappers rackup created:

```bash
rackup reshim --remove-mac-apps
```

This is off by default and macOS-only; `rackup uninstall` removes the wrappers
along with everything else.

## Upgrading linked checkouts

Earlier rackup versions gave a linked source checkout (`rackup link`) its own
compiled directory, such as `compiled/cs-local-dev`, and `rackup run` and
`rackup rebuild` used a separate addon dir, `~/.rackup/addons/local-<name>`.
rackup now uses the checkout's plain `compiled/` directories and its own addon
dir everywhere. `rackup self-upgrade` does the switch for you: it removes the
`compiled-file-roots` entry that rackup wrote into the checkout's
`racket/etc/config.rktd`, and it deletes nothing.

After upgrading:

- **Run `make` (or `rackup rebuild <name>`) once in each linked checkout.**
  Packages that were compiled only through rackup have their `.zo` files in
  the old keyed directories, which nothing reads any more. Until they are
  compiled again they load from source (slowly), or fail with
  `version mismatch` if an older `.zo` sits in plain `compiled/`. The build
  only compiles what is missing.
- **Run `raco make` on your own projects** if they fail with
  `version mismatch` or start slowly. The same applies after any version
  bump in the checkout, as it would without rackup.
- **Check for stranded packages.** If you installed packages with
  `rackup run <name> -- raco pkg install`, they went into
  `~/.rackup/addons/local-<name>`, which rackup no longer uses for a linked
  checkout. `rackup self-upgrade` (and every later `rackup reshim`) prints a
  warning that lists them:

  ```
  rackup: warning: linked toolchain dev now uses the checkout's own addon dir
    (...), but these user packages are still in ~/.rackup/addons/local-dev,
  ```

  You can also check directly: this lists them, and prints nothing when you
  are not affected.

  ```bash
  ls ~/.rackup/addons/local-*/*/pkgs/pkgs.rktd 2>/dev/null
  ```

  To fix it, reinstall the packages you need with
  `rackup run <name> -- raco pkg install -u <pkg>` (pass the directory for a
  package you installed from one), then delete `~/.rackup/addons/local-<name>`.
- **Optionally reclaim disk space.** The old keyed directories are unused.
  This lists them; delete them once you are sure:

  ```bash
  find ~/src/racket -type d -path '*/compiled/cs-local-*' -prune
  ```

## Migrating from racket-dev-goodies

If you previously used [racket-dev-goodies](https://github.com/takikawa/racket-dev-goodies)
(the `plt` shell function and `plt-bin` symlinks), rackup replaces it entirely.

**Remove the old setup.** Delete the `plt-alias.bash` source line from your
`.bashrc`/`.zshrc` and remove any `plt-bin` symlinks from your `PATH`. The `plt`
function sets `PLTHOME` globally, which conflicts with rackup's per-toolchain
environment management.

**Re-register your Racket builds.** Use `rackup link` to register existing
installations that you previously switched between with `plt`:

```bash
rackup link dev ~/src/racket
rackup link 8.15 /usr/local/racket-8.15
rackup default set dev
```

For the short `r` and `dr` aliases from racket-dev-goodies:

```bash
rackup reshim --short-aliases
```

| racket-dev-goodies | rackup |
|---|---|
| `plt ~/src/racket` | `rackup link dev ~/src/racket && rackup default set dev` |
| `plt` (show current) | `rackup current` |
| `plt-make-links.sh` | `rackup reshim` (automatic on install/link) |
| `plt-fresh-build` | Build manually, then `rackup link` |
| `r` / `dr` aliases | `rackup reshim --short-aliases` |

## For AI agents and automation

Driving rackup from CI, a script, or an AI coding agent? Run `rackup help agents`
for a cheat sheet (also published at
**[samth.github.io/rackup/agents.html](https://samth.github.io/rackup/agents.html)**).

The one rule that matters: to run a tool under a specific toolchain
non-interactively, use `rackup run <toolchain> -- <command>` (e.g.
`rackup run stable -- raco test .`). It needs no shell integration, unlike
`rackup switch`, which only takes effect in an interactive shell. State is
available in line-oriented form via `rackup list --ids`, `rackup current line`,
`rackup default status`, and `rackup which`.

A short snippet to drop into your project's `AGENTS.md`/`CLAUDE.md` is published at
**[agents-snippet.md](https://samth.github.io/rackup/agents-snippet.md)**.

## Documentation

Full command reference and usage guide: **[samth.github.io/rackup/docs.html](https://samth.github.io/rackup/docs.html)**
