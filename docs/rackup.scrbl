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

@section[#:tag "remove" #:style 'unnumbered]{@tt{rackup remove}}

Remove one installed or linked toolchain and its per-toolchain addon
directory.  For linked toolchains, only the rackup metadata and symlink
are removed; the original source tree is untouched.  Shims are rebuilt
automatically afterward.

@shell-block{rackup remove <toolchain>}

Also removes orphan/partial toolchain directories that were left behind
by interrupted installs.

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

@shell-block{rackup self-upgrade [--with-init] [--exe | --source]}

@opt-table[
  @list[@exec{--with-init}
        "Allow the installer to run shell init updates."]
  @list[@exec{--exe}
        "Require a prebuilt binary (error if unavailable for this platform)."]
  @list[@exec{--source}
        "Force source installation, even if a prebuilt binary is available."]
]

@subsection[#:style sub-style]{Advanced}

Set @tt{RACKUP_SELF_UPGRADE_INSTALL_SH} to a path or URL to override
the install script source (useful for testing dev branches).

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

@shell-block{rackup uninstall [--yes]}

@opt-table[
  @list[@exec{--yes}
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

@subsection[#:style sub-style]{Set by rackup when activating a toolchain}

@opt-table[
  @list[@tt{PLTHOME}     "Root of the active Racket installation."]
  @list[@tt{PLTADDONDIR} "Per-toolchain addon directory (packages, compiled files)."]
  @list[@tt{PATH}        "Prepended with the shims directory."]
]

Rackup saves and restores any user-set values of @tt{PLTHOME},
@tt{PLTCOLLECTS}, @tt{PLTADDONDIR}, @tt{PLTCOMPILEDROOTS},
@tt{PLTUSERHOME}, @tt{RACKET_XPATCH}, and @tt{PLT_COMPILED_FILE_CHECK}
before overriding them, so @tt{rackup run} passes through your original
settings to the subprocess.

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
]
