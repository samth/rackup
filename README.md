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

## Documentation

Full command reference and usage guide: **[samth.github.io/rackup/docs.html](https://samth.github.io/rackup/docs.html)**
