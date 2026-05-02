#lang scribble/manual

@(require scribble/core
         scribble/html-properties
         racket/runtime-path)

@; ── Style plumbing ─────────────────────────────────────────────────
@; define-runtime-path ensures files resolve relative to this module.

@(define-runtime-path css-path "rackup.css")
@(define-runtime-path js-path  "rackup-navbar.js")

@(define doc-style
   (make-style #f
     (list (css-addition css-path)
           (js-addition js-path)
           (head-extra
            '(link ((rel "icon") (type "image/svg+xml") (href "../favicon.svg")))))))

@(define sub-style
   (make-style #f '(unnumbered toc-hidden)))

@(define (shell-block . strs)
   (nested #:style (make-style "rackup-shell" '())
     (apply verbatim strs)))

@(define (opt-table . rows)
   (tabular #:style "rackup-opt-table" rows))

@(define (cmd-table . rows)
   (tabular #:style "rackup-cmd-table" rows))

@; ── Document ───────────────────────────────────────────────────────

@title[#:style doc-style #:version "" #:tag-prefix "rackup"]{Documentation}

Comprehensive command reference and usage guide.
See the @hyperlink["https://samth.github.io/rackup/"]{main page} for
installation and an overview.

@table-of-contents[]

@; ════════════════════════════════════════════════════════════════════
@;  COMMAND REFERENCE
@; ════════════════════════════════════════════════════════════════════

@section[#:tag "install" #:style 'unnumbered]{@tt{rackup install}}

Install a Racket toolchain from official release, pre-release, or
snapshot installers.

@shell-block{rackup install <spec> [flags]}

@subsection[#:style sub-style]{Install specs}

The @tt{<spec>} argument selects which toolchain to install:

@itemlist[
  @item{@tt{stable} — the current stable Racket release}
  @item{@tt{pre-release} — the latest pre-release build}
  @item{@tt{snapshot} — the latest snapshot build (auto-selects a mirror)}
  @item{@tt{snapshot:utah} or @tt{snapshot:northwestern} — snapshot from
        a specific mirror}
  @item{A numeric version like @tt{8.18}, @tt{7.9}, @tt{5.2},
        @tt{4.2.5}, or @tt{372}}
]

@subsection[#:style sub-style]{Flags}

@opt-table[
  @list[@exec{--variant cs|bc}
        "Override VM variant (default depends on version)."]
  @list[@exec{--distribution full|minimal}
        "Install full or minimal distribution (default: full)."]
  @list[@exec{--snapshot-site auto|utah|northwestern}
        "Choose snapshot mirror (default: auto)."]
  @list[@exec{--arch <arch>}
        "Override target architecture (default: host arch)."]
  @list[@exec{--set-default}
        "Set installed toolchain as the global default."]
  @list[@exec{--force}
        "Reinstall if the same canonical toolchain is already installed."]
  @list[@exec{--no-cache}
        "Redownload installer instead of using cache."]
  @list[@exec{--installer-ext sh|tgz|dmg}
        "Force installer extension (default: platform-dependent)."]
  @list[@exec{--prefix <path>}
        @elem{Install the toolchain under @tt{<path>/<id>/} on disk
              and create @tt{~/.rackup/toolchains/<id>} as a symlink
              to it.  Useful when @tt{~/.rackup} lives on slow or
              networked storage; point @tt{--prefix} at a local
              filesystem (e.g.@literal{ }@tt{/tmp/rackup-tc}) to keep
              compilation fast.  Falls back to the
              @tt{RACKUP_TOOLCHAIN_PREFIX} environment variable when
              the flag is omitted.  The choice is persisted in the
              toolchain's metadata so @tt{rackup upgrade} reinstalls
              under the same prefix.}]
  @list[@exec{--quiet}
        "Show minimal output (errors + final result lines)."]
  @list[@exec{--verbose}
        "Show detailed installer URL/path output."]
]

@subsection[#:tag "install-examples" #:style sub-style]{Examples}

@shell-block|{
rackup install stable
rackup install 8.18 --variant cs
rackup install snapshot --snapshot-site utah
rackup install pre-release --distribution minimal --set-default
rackup install stable --prefix /tmp/rackup-tc
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "list" #:style 'unnumbered]{@tt{rackup list}}

List installed toolchains and show default/active tags.

@shell-block{rackup list [--ids]}

@opt-table[
  @list[@exec{--ids}
        "Print only toolchain IDs, one per line (for scripting)."]
]

Output shows each toolchain's ID, resolved version, variant, and
distribution.  Tags like @tt{[default]} and @tt{[active]} indicate the
global default and the currently active toolchain (set via
@tt{rackup switch} or @tt{RACKUP_TOOLCHAIN}).

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "available" #:style 'unnumbered]{@tt{rackup available}}

List install aliases (stable, pre-release, snapshot) and numeric
release versions.  This queries the Racket download server for the full
list of published releases.

@shell-block{rackup available [--all|--limit N]}

@opt-table[
  @list[@exec{--all}   "Show all parsed release versions."]
  @list[@exec{--limit N} "Show at most N release versions (default: 20)."]
]

@subsection[#:tag "available-examples" #:style sub-style]{Examples}

@shell-block|{
rackup available
rackup available --limit 50
rackup available --all
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "default" #:style 'unnumbered]{@tt{rackup default}}

Show, set, or clear the global default toolchain.  The default
determines which toolchain the shims use when no per-shell override
(@tt{RACKUP_TOOLCHAIN}) is active.  If the requested toolchain spec is
not installed, interactive shells are prompted to install it.

@shell-block{rackup default [id|status|set <toolchain>|clear|<toolchain>|--unset]}

@subsection[#:style sub-style]{Subcommands}

@opt-table[
  @list[@tt{(no argument)} "Print the default toolchain ID (blank if none)."]
  @list[@tt{id}            "Same as no argument."]
  @list[@tt{status}        "Print set<TAB><id> or unset."]
  @list[@tt{set <toolchain>} "Set the given toolchain as the default."]
  @list[@tt{<toolchain>}   "Shorthand for set <toolchain>."]
  @list[@tt{clear}         "Clear the default toolchain."]
  @list[@exec{--unset}       "Same as clear."]
]

@subsection[#:tag "default-examples" #:style sub-style]{Examples}

@shell-block|{
rackup default              # show current default
rackup default stable       # set default to stable
rackup default set 8.18     # set default to 8.18
rackup default status       # print set/unset and id
rackup default clear        # clear the default
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "current" #:style 'unnumbered]{@tt{rackup current}}

Show the active toolchain and whether it comes from shell activation
(@tt{RACKUP_TOOLCHAIN}) or the global default.

@shell-block{rackup current [id|source|line]}

@opt-table[
  @list[@tt{(no argument)} "Print the active ID and source."]
  @list[@tt{id}            "Print only the active toolchain ID (blank if none)."]
  @list[@tt{source}        "Print env, default, or none."]
  @list[@tt{line}          "Print <id><TAB><source>."]
]

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "which" #:style 'unnumbered]{@tt{rackup which}}

Show the real executable path for a tool in a toolchain.  Without
@exec{--toolchain}, uses the active toolchain.

@shell-block{rackup which <exe> [--toolchain <toolchain>]}

@subsection[#:tag "which-examples" #:style sub-style]{Examples}

@shell-block|{
rackup which racket
rackup which raco --toolchain 8.18
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "switch" #:style 'unnumbered]{@tt{rackup switch}}

Switch the active toolchain in the current shell without changing the
global default.  When run via the shell integration installed by
@tt{rackup init}, this updates the current shell's environment
immediately.  Otherwise, it emits shell code that you can @tt{eval}.

@shell-block{rackup switch <toolchain> | rackup switch --unset}

If the requested toolchain is not installed, you are prompted to
install it.

@subsection[#:tag "switch-examples" #:style sub-style]{Examples}

@shell-block|{
rackup switch stable
rackup switch 8.18
rackup switch --unset       # deactivate per-shell override
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "shell" #:style 'unnumbered]{@tt{rackup shell}}

Emit shell code to activate or deactivate a toolchain in the current
shell.  This is the low-level primitive used by @tt{rackup switch} and
the shell wrapper function.  Most users should use @tt{rackup switch}
instead.

@shell-block{rackup shell <toolchain> | rackup shell --deactivate}

@subsection[#:tag "shell-examples" #:style sub-style]{Example}

@shell-block|{
eval "$(rackup shell 8.18)"
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "run" #:style 'unnumbered]{@tt{rackup run}}

Run a command under a specific toolchain without changing defaults or
the shell environment.  Sets @tt{PLTHOME}, @tt{PLTADDONDIR},
@tt{PATH}, and @tt{RACKUP_TOOLCHAIN} for the subprocess only.

@shell-block{rackup run <toolchain> -- <command> [args...]}

The @exec{--} separator is required between the toolchain spec and the
command to run.

@subsection[#:tag "run-examples" #:style sub-style]{Examples}

@shell-block|{
rackup run 8.18 -- racket -e '(displayln (version))'
rackup run stable -- raco pkg install gregor
rackup run snapshot -- raco test .
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "link" #:style 'unnumbered]{@tt{rackup link}}

Link an in-place or locally built Racket tree as a managed toolchain.
The linked directory is not copied; rackup creates a symlink and
metadata so that shims and @tt{rackup switch} work with it.

@shell-block{rackup link <name> <path> [--set-default] [--force]}

@subsection[#:style sub-style]{Accepted paths}

@itemlist[
  @item{A Racket source checkout root (containing @tt{racket/bin} and
        @tt{racket/collects}).}
  @item{A @tt{PLTHOME} directory (containing @tt{bin} and
        @tt{collects} directly).}
]

@opt-table[
  @list[@exec{--set-default}
        "Set the linked toolchain as the global default."]
  @list[@exec{--force}
        "Replace an existing link with the same local name."]
]

@subsection[#:tag "link-examples" #:style sub-style]{Examples}

@shell-block|{
rackup link dev ~/src/racket
rackup link dev ~/src/racket --set-default
rackup link cs-head ~/src/racket --force
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "rebuild" #:style 'unnumbered]{@tt{rackup rebuild}}

Rebuild a linked source toolchain in place by running @tt{make} against
its source tree.  Useful after pulling upstream changes or editing
collects: rackup re-probes the version, refreshes the toolchain's
@tt{env.sh}, and updates @tt{meta.rktd} with a @tt{last-rebuilt-at}
timestamp.

The @tt{build/} directory is @emph{not} deleted; @tt{make} runs
incrementally.  Pulling is opt-in and never automatic.

@shell-block{rackup rebuild [<name>] [flags] [-- <make-args>...]}

If @tt{<name>} is omitted, the active toolchain (from
@tt{RACKUP_TOOLCHAIN} or the default) is used.  Anything after
@tt{--} is appended verbatim to the @tt{make} argv.

@subsection[#:tag "rebuild-flags" #:style sub-style]{Flags}

@opt-table[
  @list[@exec{--pull}
        "Run `git pull --ff-only` in the source tree before building.
         Errors out if the source is not a git work tree."]
  @list[@exec{-j N, --jobs N}
        "Parallelism for make.  rackup passes both `-jN` and `CPUS=N`
         (the Racket build's recursive variable).  Defaults to the
         number of available processors."]
  @list[@exec{--dry-run}
        "Print the planned commands and exit without running anything."]
  @list[@exec{--no-update-meta}
        "Skip the post-build version reprobe and `env.sh` regeneration.
         Escape hatch when the source tree is in a transient state."]
]

@subsection[#:tag "rebuild-layouts" #:style sub-style]{Supported layouts}

@itemlist[
  @item{Package-based source checkout (with a top-level @tt{Makefile}):
        @tt{make} runs at the source root.}
  @item{Plain in-place build (no @tt{pkgs/}, but a @tt{Makefile} at
        @tt{PLTHOME}): @tt{make} runs at @tt{PLTHOME}.}
  @item{Installed-prefix layouts (no @tt{Makefile}) are not supported;
        @tt{rackup rebuild} reports a clear error and does nothing.}
]

@subsection[#:tag "rebuild-examples" #:style sub-style]{Examples}

@shell-block|{
rackup rebuild dev
rackup rebuild dev -- CPUS=8 PKGS="main-distribution"
rackup rebuild dev --pull -j 4
rackup rebuild --dry-run
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "remove" #:style 'unnumbered]{@tt{rackup remove}}

Remove one installed or linked toolchain and its per-toolchain addon
directory.  For linked toolchains, only the rackup metadata and symlink
are removed; the original source tree is untouched.  Shims are rebuilt
automatically afterward.

@shell-block{rackup remove [--clean-compiled] <toolchain>}

Also removes orphan/partial toolchain directories that were left behind
by interrupted installs.

@subsection[#:tag "remove-flags" #:style sub-style]{Flags}

@opt-table[
  @list[@exec{--clean-compiled}
        @elem{Before removing the toolchain, delete any
              @tt{compiled/<version>-<variant>/} subdirectories found in
              the source trees of user-scope and linked packages.  This
              cleans up stale @tt{.zo} files written under rackup's
              per-toolchain @tt{PLTCOMPILEDROOTS} (see
              @secref["environment-variables"]) that would otherwise persist after
              the toolchain is removed.  Requires the toolchain's
              @tt{racket} to be operational, since package source
              directories are enumerated via the toolchain's own
              @tt{pkg/lib}.}]
]

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "upgrade" #:style 'unnumbered]{@tt{rackup upgrade}}

Upgrade channel-based toolchains to the latest available version.
Only toolchains installed via a channel (@tt{stable}, @tt{pre-release},
or @tt{snapshot}) are eligible.  Version-pinned installs (e.g.
@tt{rackup install 8.18}) are never upgraded.

@shell-block{rackup upgrade [<spec>] [--force] [--no-cache]}

With no arguments, upgrades all channel-based toolchains.  When
@tt{<spec>} is given, only toolchains matching that channel are
upgraded.  Valid specs are @tt{stable}, @tt{pre-release},
@tt{snapshot}, and @tt{pre}.

@subsection[#:tag "upgrade-flags" #:style sub-style]{Flags}

@opt-table[
  @list[@exec{--force}
        "Reinstall even if the installed version matches the latest."]
  @list[@exec{--no-cache}
        "Re-download the installer instead of using the cache."]
]

@subsection[#:tag "upgrade-how" #:style sub-style]{How upgrade works}

For each upgradeable toolchain, rackup:

@itemlist[#:style 'ordered
  @item{Resolves the latest available version for the toolchain's
        channel, using the same variant, distribution, and architecture
        as the existing installation.}
  @item{Compares the installed version against the latest.  For stable
        and pre-release toolchains, this uses numeric version
        comparison.  For snapshots, it compares the snapshot timestamp.}
  @item{If a newer version is available (or @exec{--force} is set),
        installs the new version as a new toolchain.  Because canonical
        IDs include the version number (e.g.
        @tt{release-9.1-cs-x86_64-linux-full}), the new version gets a
        different ID from the old one.}
  @item{Migrates user-scoped packages from the old toolchain to the new
        one.  This lists packages via @tt{raco pkg show --user} on the
        old toolchain and installs them via @tt{raco pkg install} on the
        new one.  If package migration fails, a warning is printed but
        the upgrade proceeds.}
  @item{If the old toolchain was the global default, transfers default
        status to the new toolchain.}
  @item{Removes the old toolchain and its addon directory.}
]

If the install step fails, the old toolchain is left untouched.

@subsection[#:tag "upgrade-examples" #:style sub-style]{Examples}

@shell-block|{
rackup upgrade                # upgrade all channels
rackup upgrade stable         # upgrade only stable
rackup upgrade snapshot       # upgrade only snapshot
rackup upgrade --force        # reinstall even if up to date
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "prompt" #:style 'unnumbered]{@tt{rackup prompt}}

Print prompt/status information for the active toolchain.  Designed to
be called from @tt{PS1} or a prompt function.  Prints nothing when no
active/default toolchain is configured.  When shell integration is
active, the shell wrapper handles this without starting Racket for
speed.

@shell-block{rackup prompt [--long|--short|--raw|--source]}

@opt-table[
  @list[@tt{(default)} "Print a compact label like racket-9.1."]
  @list[@exec{--long}    "Print the long bracketed form: [rk:<toolchain-id>]."]
  @list[@exec{--short}   "Same as default."]
  @list[@exec{--raw}     "Print only the active toolchain ID."]
  @list[@exec{--source}  "Print <id><TAB><env|default>."]
]

@subsection[#:style sub-style]{Shell prompt integration}

@shell-block|{
# Add to .bashrc / .zshrc:
PS1='$(rackup prompt) '$PS1
}|

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "reshim" #:style 'unnumbered]{@tt{rackup reshim}}

Rebuild shim executables from the union of all installed toolchain
executables.  This runs automatically on @tt{install}, @tt{link},
@tt{remove}, and @tt{default set}, but can be run manually if shims get
out of sync.

@shell-block{rackup reshim}

Shims are small scripts placed in @tt{~/.rackup/shims/} that delegate
to the active toolchain's real executable.  Common shims include
@tt{racket}, @tt{raco}, @tt{scribble}, @tt{drracket}, @tt{slideshow},
@tt{gracket}, @tt{mzscheme}, and @tt{mzc}.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "init" #:style 'unnumbered]{@tt{rackup init}}

Install or update shell integration in @tt{~/.bashrc} or
@tt{~/.zshrc}.  Writes a managed block that sources
@tt{~/.rackup/shell/rackup.<shell>}.  The managed block adds the shims
directory to @tt{PATH} and defines the @tt{rackup} shell function that
wraps @tt{rackup switch} so it takes effect in the current shell.

@shell-block{rackup init [--shell bash|zsh]}

If @exec{--shell} is omitted, the current shell is detected
automatically.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "self-upgrade" #:style 'unnumbered]{@tt{rackup self-upgrade}}

Upgrade rackup's own code by rerunning the bootstrap installer into the
current @tt{RACKUP_HOME}.  By default this skips shell init edits and
keeps your current shell config unchanged.  The installer picks the
best mode automatically (prebuilt binary if available for the current
platform, otherwise source).

@shell-block{rackup self-upgrade [--with-init] [--exe | --source] [--ref <ref> [--repo <owner>/<repo>]]}

@opt-table[
  @list[@exec{--with-init}
        "Allow the installer to run shell init updates."]
  @list[@exec{--exe}
        "Require a prebuilt binary (error if unavailable for this platform)."]
  @list[@exec{--source}
        "Force source installation, even if a prebuilt binary is available."]
  @list[@exec{--ref <ref>}
        @elem{Install rackup from the given git ref (branch, tag, or commit)
              instead of the published release.  Useful for testing a
              development branch or pull request.  Fetches @tt{install.sh}
              from the target ref so any installer changes on the branch
              are exercised too.  Custom refs do not publish prebuilt
              binaries, so the installer falls back to source.}]
  @list[@exec{--repo <owner>/<repo>}
        @elem{Install rackup from a different GitHub repository (default:
              @tt{samth/rackup}).  Combine with @tt{--ref} to test a PR
              from a fork.}]
]

@subsection[#:style sub-style]{Examples}

@shell-block|{
# Test the current branch of an open PR in samth/rackup
rackup self-upgrade --ref pltcompiledroots

# Test a PR from a fork
rackup self-upgrade --repo someuser/rackup --ref my-feature

# Pin to a specific commit
rackup self-upgrade --ref a1b2c3d
}|

After a successful update, rackup automatically runs @tt{rackup reshim}
in a subprocess so any per-toolchain migrations introduced by the new
version (e.g., backfilling @tt{PLTCOMPILEDROOTS}) take effect for
existing toolchains.

@subsection[#:style sub-style]{Advanced}

Set @tt{RACKUP_SELF_UPGRADE_INSTALL_SH} to a path or URL to override
the install script source (useful for local-only testing of an
unpushed branch).

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "runtime" #:style 'unnumbered]{@tt{rackup runtime}}

Manage rackup's internal Racket runtime.

When rackup is installed from @bold{source}, it uses a hidden minimal
Racket installation to run itself.  This runtime is separate from user
toolchains and is not exposed via shims or @tt{PATH}.

When rackup is installed as a @bold{prebuilt executable}, Racket is
embedded in the @tt{rackup-core} binary and no hidden runtime is
needed.  In this mode, @tt{runtime install} and @tt{runtime upgrade}
are no-ops; use @tt{rackup self-upgrade} to update the executable
instead.

@shell-block{rackup runtime status|install|upgrade}

@opt-table[
  @list[@tt{status}
        "Show runtime mode and metadata."]
  @list[@tt{install}
        "Install the hidden runtime if missing (source installs only)."]
  @list[@tt{upgrade}
        "Upgrade the hidden runtime if a newer version is available (source installs only)."]
]

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "uninstall" #:style 'unnumbered]{@tt{rackup uninstall}}

Remove all rackup-managed data and shell init blocks.  This is
destructive and cannot be undone.

@shell-block{rackup uninstall [--dangerously-delete-without-prompting]}

@opt-table[
  @list[@exec{--dangerously-delete-without-prompting}
        "Skip the interactive DELETE confirmation prompt."]
]

@subsection[#:style sub-style]{What gets deleted}

@itemlist[
  @item{The hidden runtime (source installs) or prebuilt executable
        and shared libraries (exe installs).}
  @item{All installed toolchains and linked-toolchain metadata/overlays.}
  @item{Shims, caches, downloaded installers, and per-toolchain addon
        dirs/packages.}
  @item{Rackup-managed init blocks from @tt{~/.bashrc} and
        @tt{~/.zshrc}.}
]

Linked local source trees are @emph{not} deleted — only rackup's links
to them.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "doctor" #:style 'unnumbered]{@tt{rackup doctor}}

Print diagnostics for rackup paths, hidden runtime, and installed
toolchains.  Useful when troubleshooting installation or shim issues.
Reports on:

@itemlist[
  @item{@tt{RACKUP_HOME} location and contents.}
  @item{Hidden runtime status and version.}
  @item{Installed toolchains, their metadata, and whether their
        directories exist.}
  @item{Shim directory contents and @tt{PATH} status.}
]

@shell-block{rackup doctor}

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "version" #:style 'unnumbered]{@tt{rackup version}}

Print rackup version information (git commit hash and date).

@shell-block{rackup version}

@; ════════════════════════════════════════════════════════════════════
@;  QUICK START GUIDES
@; ════════════════════════════════════════════════════════════════════

@section[#:tag "quick-start" #:style 'unnumbered]{Quick start guides}

Pick the guide that matches your situation.

@subsection[#:tag "qs-new-user" #:style sub-style]{New to Racket}

If you have never used Racket before, start here.

@shell-block|{
# 1. Install rackup
curl -fsSL https://samth.github.io/rackup/install.sh | sh

# 2. Install the latest stable Racket release
rackup install stable

# 3. Set up your shell so "racket" and "raco" are on PATH
rackup init --shell bash   # or zsh

# 4. Start a new shell (or source your rc file), then:
racket                     # interactive REPL
raco pkg install gregor    # install a package
}|

@subsection[#:tag "qs-existing-user" #:style sub-style]{Existing Racket user}

You already have Racket installed and want to manage multiple versions.

@shell-block|{
# 1. Install rackup
curl -fsSL https://samth.github.io/rackup/install.sh | sh
rackup init --shell bash   # or zsh

# 2. Install versions you need
rackup install 8.18
rackup install stable

# 3. Set a global default
rackup default stable

# 4. Switch in the current shell when needed
rackup switch 8.18
racket --version           # → 8.18
rackup switch stable
racket --version           # → latest stable
}|

Your existing system Racket is not affected.  Once the shims directory
is on your @tt{PATH}, the shimmed @tt{racket} takes precedence.  To
go back to your system Racket, run @tt{rackup default clear} and
remove the rackup init block from your shell rc.

@subsection[#:tag "qs-racket-dev" #:style sub-style]{Racket developer (source builds)}

You build Racket from source and want to switch between your
development tree and release builds.

@shell-block|{
# 1. Install rackup
curl -fsSL https://samth.github.io/rackup/install.sh | sh
rackup init --shell bash   # or zsh

# 2. Link your local source tree
rackup link dev ~/src/racket

# 3. Optionally install a release for comparison
rackup install stable

# 4. Switch between them
rackup default dev
rackup switch stable       # test against a release
rackup switch dev          # back to your build
}|

The linked directory is not copied — rackup creates a symlink and
metadata so shims and @tt{rackup switch} work with it.  After
editing your source tree, the changes are visible immediately
(no re-link needed).

If you previously used
@hyperlink["https://github.com/takikawa/racket-dev-goodies"]{racket-dev-goodies},
including the @tt{plt-bin} shell script, see @secref["migration"] for migration steps.

@subsection[#:tag "qs-pkg-dev" #:style sub-style]{Package developer}

You develop Racket packages and need to test against multiple Racket
versions.

@shell-block|{
# Install the versions you want to test against
rackup install stable
rackup install pre-release
rackup install 8.15

# Run your test suite under each version
rackup run stable -- raco test .
rackup run pre-release -- raco test .
rackup run 8.15 -- raco test .
}|

@tt{rackup run} sets @tt{PLTADDONDIR} and @tt{PATH}
for the subprocess only — your shell's active toolchain is unchanged.
Each toolchain gets its own addon directory, so installed packages
don't collide between versions.

@subsection[#:tag "qs-ci" #:style sub-style]{CI / Docker / automation}

Use non-interactive mode for scripts, CI pipelines, and containers.

@shell-block|{
# Non-interactive install (no prompts)
curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y

# Install a toolchain quietly
rackup install stable --quiet

# Run commands without shell integration
rackup run stable -- raco test .
rackup run stable -- raco pkg install --auto gregor
}|

In a Dockerfile:

@shell-block|{
RUN curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y \
 && ~/.rackup/bin/rackup install stable --quiet
ENV PATH="/root/.rackup/shims:/root/.rackup/bin:${PATH}"
}|

For scripting, @tt{rackup list --ids} prints one toolchain ID per
line and @tt{rackup current id} prints just the active ID — both are
easy to parse.

@; ════════════════════════════════════════════════════════════════════
@;  GUIDE SECTIONS
@; ════════════════════════════════════════════════════════════════════

@section[#:tag "shell-integration" #:style 'unnumbered]{Shell integration}

After the initial bootstrap, run @tt{rackup init} to set up your shell.
This adds a small managed block to your @tt{.bashrc} or @tt{.zshrc}
that:

@itemlist[
  @item{Adds @tt{~/.rackup/shims} to @tt{PATH} so @tt{racket},
        @tt{raco}, etc. resolve to rackup shims.}
  @item{Defines a @tt{rackup} shell function that wraps the real
        @tt{rackup} binary.  When you run @tt{rackup switch}, the
        wrapper evals the emitted shell code so the switch takes effect
        in the current shell, without starting a subshell.}
]

@shell-block{rackup init --shell bash   # or zsh}

Once initialized, switching toolchains takes effect immediately:

@shell-block|{
$ rackup switch 8.18
$ racket --version           # uses 8.18
$ rackup switch stable
$ racket --version           # back to stable
}|

The managed block is delimited by marker comments so that
@tt{rackup init} can update it idempotently and @tt{rackup uninstall}
can remove it cleanly.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "environment-variables" #:style 'unnumbered]{Environment variables}

@subsection[#:style sub-style]{User-facing}

@opt-table[
  @list[@tt{RACKUP_HOME}
        "Override the rackup state directory (default: ~/.rackup)."]
  @list[@tt{RACKUP_TOOLCHAIN}
        "Override the active toolchain for the current shell session. Set by rackup switch; can also be set manually."]
]

@subsection[#:style sub-style]{Set by rackup switch (in user's shell)}

@opt-table[
  @list[@tt{RACKUP_TOOLCHAIN}  "The active toolchain ID."]
  @list[@tt{PATH}              "Prepended with the shims directory."]
]

@subsection[#:style sub-style]{Set internally by the shim dispatcher (per invocation)}

@opt-table[
  @list[@tt{PLTHOME}           "Root of the active Racket installation (old PLT Scheme only)."]
  @list[@tt{PLTADDONDIR}       "Per-toolchain addon directory (packages, compiled files)."]
  @list[@tt{PLTCOMPILEDROOTS}  @elem{Version-variant-specific compiled root (e.g., @tt{compiled/9.1-cs:.}) so different toolchains do not share @tt{.zo} files.}]
]

Rackup saves and restores any user-set values of @tt{PLTHOME},
@tt{PLTCOLLECTS}, @tt{PLTADDONDIR}, @tt{PLTCOMPILEDROOTS},
@tt{PLTUSERHOME}, @tt{RACKET_XPATCH}, and @tt{PLT_COMPILED_FILE_CHECK}
before overriding them, so @tt{rackup run} passes through your original
settings to the subprocess.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "compiled-files" #:style 'unnumbered]{Per-toolchain compiled files}

Different Racket versions, and the Chez-based (@tt{cs}) and bytecode
(@tt{bc}) VMs within a single version, produce incompatible @tt{.zo}
files.  Without per-toolchain separation, compiling a collection under
Racket 9.1-cs and then switching to 8.18-bc would leave behind
@tt{.zo} files that the new toolchain cannot load, forcing a manual
@tt{raco setup} or a @tt{rm -rf compiled/} dance.

Rackup avoids this by setting @tt{PLTCOMPILEDROOTS} per toolchain so
each version+variant writes its compiled output to its own
subdirectory, while preserving the toolchain's existing compiled-file
roots so pre-existing @tt{.zo} files are still found.

At install or link time, rackup reads the toolchain's
@tt{config.rktd} to discover its existing @tt{compiled-file-roots}
and constructs a @tt{PLTCOMPILEDROOTS} value that prepends the
versioned root:

@shell-block|{
# In-place layout (rackup's default --in-place installs):
PLTCOMPILEDROOTS=compiled/9.1-cs:.

# FHS layout (e.g., system-packaged Racket):
PLTCOMPILEDROOTS=compiled/9.1-cs:/usr/lib/racket/compiled:.
}|

The first entry (@tt{compiled/9.1-cs}) is where new @tt{.zo} files
are written.  The remaining entries are the toolchain's native
compiled-file roots (preserved from its @tt{config.rktd}), plus
@tt{.} which resolves to the source directory itself so that user
code's @tt{compiled/} directories are always found.

For example, if you install Racket from a full installer (which ships
with pre-compiled @tt{.zo} files) and manage it via rackup, those
pre-compiled files are found through the fallback roots without
recompiling.  New compilations go into @tt{compiled/9.1-cs/}.

@subsection[#:style sub-style]{How the key is chosen}

The subdirectory name is @tt{<resolved-version>-<variant>}.  Full and
minimal distributions of the same version+variant share a directory
(they run the same compiler, so their @tt{.zo} files are compatible),
while CS and BC are separated because their bytecode formats are
incompatible.  Snapshots and development builds get their own keys
based on the probed version (e.g., @tt{9.1.0.3-cs}), which naturally
separates them from release builds.

For linked toolchains whose version or variant cannot be probed,
@tt{PLTCOMPILEDROOTS} is left unset so the toolchain uses the default
@tt{compiled/} directory.

Toolchains installed by an older version of rackup are migrated
automatically: the next time any rackup state-changing command runs
(e.g., @tt{rackup reshim}, @tt{rackup install}, @tt{rackup upgrade}),
any installed toolchain whose @tt{meta.rktd} predates per-toolchain
@tt{PLTCOMPILEDROOTS} has the entry backfilled in place.  No
reinstallation is required.

@subsection[#:style sub-style]{Environment scoping}

Racket-specific env vars (@tt{PLTCOMPILEDROOTS}, @tt{PLTADDONDIR},
@tt{PLTHOME}) are set internally by the shim dispatcher via
per-toolchain @tt{env.sh} files, scoped to each subprocess
invocation.  @tt{rackup switch} only sets @tt{RACKUP_TOOLCHAIN} and
@tt{PATH} in the user's shell.  This prevents rackup's env vars from
leaking into non-rackup commands (e.g., @tt{make install} in a
Racket source checkout).

For @tt{rackup run}, if the user had @tt{PLTCOMPILEDROOTS} set before
invoking rackup, the saved value is restored and takes precedence
over the toolchain's default.

@subsection[#:style sub-style]{Cleaning up}

New @tt{.zo} files written by a toolchain can end up outside
rackup's own state directories — specifically, in the source trees of
packages installed with @tt{raco pkg install --link}, or in any
directory where you run @tt{raco make} manually.  When you
@tt{rackup remove} a toolchain, the toolchain's own @tt{collects/}
and addon directory are deleted, but these user directories are not.

Passing @tt{--clean-compiled} to @tt{rackup remove} walks the source
directories of every user-scope package (catalog and linked) and
removes any @tt{compiled/<key>/} subdirectories before the toolchain
itself is removed:

@shell-block{rackup remove 9.1 --clean-compiled}

This enumerates packages via the toolchain's own @tt{racket} and
@tt{pkg/lib}, so it needs the outgoing toolchain to still be
operational.  Package source directories outside of rackup's
knowledge (projects you work on directly, collections under
@tt{raco link}, etc.) are not touched — you can clean those up
manually with @tt{rm -rf compiled/9.1-cs} in each directory.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "directory-layout" #:style 'unnumbered]{Directory layout}

All rackup state lives under @tt{RACKUP_HOME} (default @tt{~/.rackup}).
The layout differs slightly depending on how rackup was installed.

@subsection[#:style sub-style]{Source installation}

@shell-block|{
~/.rackup/
  bin/rackup              # the rackup shell wrapper
  libexec/                # rackup's Racket source code
  runtime/                # hidden internal Racket runtime
  toolchains/             # installed/linked toolchains
  addons/                 # per-toolchain addon directories
  shims/                  # executable shims (racket, raco, ...)
  shell/                  # generated shell integration scripts
  cache/                  # downloaded installer cache
  index.rktd              # toolchain registry
}|

@subsection[#:style sub-style]{Prebuilt executable installation}

@shell-block|{
~/.rackup/
  bin/rackup              # the rackup shell wrapper
  bin/rackup-core         # prebuilt executable (embeds Racket)
  lib/                    # shared libraries for the executable
  toolchains/             # installed/linked toolchains
  addons/                 # per-toolchain addon directories
  shims/                  # executable shims (racket, raco, ...)
  shell/                  # generated shell integration scripts
  cache/                  # downloaded installer cache
  index.rktd              # toolchain registry
}|

No @tt{runtime/} or @tt{libexec/} directories are needed in exe mode
because Racket is embedded in the @tt{rackup-core} binary.

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "toolchain-resolution" #:style 'unnumbered]{Toolchain resolution}

The active toolchain is resolved in this order:

@itemlist[#:style 'ordered
  @item{@tt{RACKUP_TOOLCHAIN} environment variable (set by
        @tt{rackup switch}).}
  @item{The global default (set by @tt{rackup default}).}
]

When you run a shimmed command like @tt{racket}, the shim looks up the
active toolchain, resolves its @tt{PLTHOME}, and @tt{exec}s the real
binary from the toolchain's @tt{bin/} directory.

@subsection[#:style sub-style]{Spec matching}

When specifying a toolchain for commands like @tt{default},
@tt{switch}, @tt{remove}, or @tt{run}, rackup matches against
installed toolchain IDs.  For @tt{install}, the spec is resolved
against the Racket download infrastructure:

@itemlist[
  @item{@tt{stable} → queries @tt{version.txt} from
        @tt{download.racket-lang.org}.}
  @item{@tt{pre-release} → queries the pre-release metadata endpoint.}
  @item{@tt{snapshot} / @tt{snapshot:utah} /
        @tt{snapshot:northwestern} → queries snapshot @tt{table.rktd}
        for the latest build.}
  @item{Numeric versions (e.g. @tt{8.18}) → mapped to the exact release
        installer URL.}
]

@; ────────────────────────────────────────────────────────────────────

@section[#:tag "migration" #:style 'unnumbered]{Migrating from racket-dev-goodies}

If you previously used
@hyperlink["https://github.com/takikawa/racket-dev-goodies"]{racket-dev-goodies}
(the @tt{plt} shell function and @tt{plt-bin} symlinks), rackup
replaces it entirely.

@itemlist[#:style 'ordered
  @item{Remove the @tt{plt-alias.bash} source line from your
        @tt{.bashrc}/@tt{.zshrc} and remove any @tt{plt-bin} symlinks
        from your @tt{PATH}.  The @tt{plt} function sets @tt{PLTHOME}
        globally, which conflicts with rackup's per-toolchain
        environment management.}
  @item{Install rackup and re-register your Racket builds:}
]

@shell-block|{
rackup link dev ~/src/racket
rackup link 8.15 /usr/local/racket-8.15
rackup default set dev
}|

For release versions you can also use @tt{rackup install}:

@shell-block|{
rackup install stable
rackup install 8.15
}|

If you used the short @tt{r} and @tt{dr} aliases from
racket-dev-goodies, enable them in rackup with:

@shell-block|{rackup reshim --short-aliases}|

This creates @tt{r} (for @tt{racket}) and @tt{dr} (for
@tt{drracket}) shims. You can also pass @tt{--short-aliases} to
@tt{rackup install}.

@subsection[#:style sub-style]{Equivalents at a glance}

@cmd-table[
  @list[@tt{plt ~/src/racket}
        @tt{rackup link dev ~/src/racket && rackup default set dev}]
  @list[@elem{@tt{plt} (show current)}
        @tt{rackup current}]
  @list[@tt{plt-make-links.sh}
        @elem{@tt{rackup reshim} (automatic on install/link)}]
  @list[@tt{plt-fresh-build}
        @elem{Build manually, then @tt{rackup link}}]
  @list[@elem{@tt{r} / @tt{dr} aliases}
        @tt{rackup reshim --short-aliases}]
]
