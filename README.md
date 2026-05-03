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

Install a toolchain:

```bash
rackup install stable
```

Set up shell integration:

```bash
rackup init --shell bash   # or zsh
```

## Usage

### Install toolchains

```bash
rackup install stable
rackup install 8.18
rackup install pre-release
rackup install snapshot
rackup install snapshot:utah
rackup install 4.2.5
```

### Switch between toolchains

```bash
rackup default stable
rackup switch 8.18
rackup run snapshot -- raco test .
```

### Link local source trees

```bash
rackup link dev ~/src/racket
rackup link dev ~/src/racket --set-default
```

### Other commands

```bash
rackup list
rackup available
rackup current
rackup which racket
rackup remove 8.18
rackup prompt
rackup doctor
rackup self-upgrade
```

## Documentation

- User guide and command reference: **[samth.github.io/rackup/docs.html](https://samth.github.io/rackup/docs.html)**
- Contributor architecture and implementation details: [docs/IMPLEMENTATION.md](./docs/IMPLEMENTATION.md)
