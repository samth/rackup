#lang scribble/html

@; rackup documentation — comprehensive command reference and guide.
@; Complements the main site (samth.github.io/rackup/) which covers
@; installation, overview, and the command summary table.
@;
@; Generate with:  racket docs/rackup.scrbl > docs/rackup.html

@(define (shell-block . text)
   @pre[class: "rackup-shell"]{@code{@text}})

@(define (opt-row flag desc)
   @tr{@td{@code{@flag}} @td{@desc}})

@html[lang: "en"]{
 @head{
  @meta[charset: "utf-8"]
  @meta[name: "viewport" content: "width=device-width, initial-scale=1"]
  @title{rackup documentation}
  @style{
    html, body {
      background: white;
      color: #333;
      margin: 0;
      padding: 0;
    }
    body {
      font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
      font-size: 16px;
      line-height: 1.6;
    }
    a { color: #0679a7; text-decoration: none; }
    a:hover { color: #034b6b; text-decoration: underline; }

    /* Navbar */
    .navbar {
      background: white;
      border-bottom: 1px solid #ddd;
      padding: 0.6rem 1.5rem;
      display: flex;
      align-items: center;
      gap: 1.5rem;
    }
    .navbar .logo {
      font-size: 1.1rem;
      font-weight: 700;
      color: #333;
      text-decoration: none;
    }
    .navbar a {
      font-size: 0.9rem;
      font-weight: 600;
      color: #333;
    }
    .navbar a:hover { color: #0679a7; }

    /* Page container */
    .rackup-page {
      margin: 0 auto;
      max-width: 1050px;
      padding: 0 1.5rem 4rem;
    }

    /* Page header */
    .rackup-doc-header {
      border-bottom: 1px solid #ddd;
      padding: 2rem 0 1.5rem;
    }
    .rackup-doc-header h1 {
      color: #333;
      font-size: 2rem;
      font-weight: 600;
      margin: 0 0 0.3rem;
    }
    .rackup-doc-header p {
      color: #555;
      font-size: 1.1rem;
      margin: 0;
    }

    /* Shell blocks */
    pre.rackup-shell {
      background: #2d2d2d;
      border: none;
      border-radius: 6px;
      color: #f0f0f0;
      margin: 0;
      overflow-x: auto;
      padding: 0.8rem 1rem;
    }
    pre.rackup-shell code {
      background: transparent;
      color: #f0f0f0;
      display: block;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 1rem;
      line-height: 1.5;
      margin: 0;
      padding: 0;
      white-space: pre-wrap;
    }
    .rackup-shell + .rackup-shell { margin-top: 0.6rem; }
    code {
      background: #f0f0f0;
      border-radius: 3px;
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 1em;
      padding: 0.1rem 0.35rem;
    }

    /* Sections */
    .rackup-section {
      border-bottom: 1px solid #ddd;
      padding: 2rem 0;
    }
    .rackup-section:last-child { border-bottom: none; }
    .rackup-section h2 {
      color: #333;
      font-size: 1.4rem;
      font-weight: 600;
      margin: 0 0 0.75rem;
    }
    .rackup-section > p {
      color: #555;
      margin: 0 0 1rem;
      max-width: 50rem;
    }
    .rackup-section > ul,
    .rackup-section > ol {
      color: #555;
      max-width: 50rem;
      padding-left: 1.5rem;
    }
    .rackup-section > ul li,
    .rackup-section > ol li {
      margin-bottom: 0.4rem;
    }

    /* Subsection headings */
    .rackup-section h3 {
      color: #333;
      font-size: 1.15rem;
      font-weight: 600;
      margin: 1.5rem 0 0.5rem;
    }
    .rackup-section h3:first-child { margin-top: 0; }

    /* Option/flag tables */
    .rackup-opt-table {
      border: none;
      border-collapse: collapse;
      font-size: 0.95rem;
      margin-top: 0.5rem;
      width: 100%;
    }
    .rackup-opt-table tr { border: none; }
    .rackup-opt-table td {
      border: none;
      padding: 0.3rem 0.8rem 0.3rem 0;
      vertical-align: top;
    }
    .rackup-opt-table td:first-child { white-space: nowrap; }
    .rackup-opt-table td:last-child { color: #555; }

    /* Migration equivalence table */
    .rackup-cmd-table {
      border: none;
      border-collapse: collapse;
      font-size: 0.95rem;
      margin-top: 0.5rem;
      width: 100%;
    }
    .rackup-cmd-table tr { border: none; }
    .rackup-cmd-table td {
      border: none;
      padding: 0.4rem 0.8rem 0.4rem 0;
      vertical-align: top;
    }
    .rackup-cmd-table td:first-child { white-space: nowrap; }
    .rackup-cmd-table td:last-child { color: #555; }

    /* TOC */
    .rackup-toc {
      column-count: 3;
      column-gap: 2rem;
      list-style: none;
      margin: 0.5rem 0 0;
      padding: 0;
    }
    .rackup-toc li {
      margin-bottom: 0.3rem;
    }
    @"@"media (max-width: 700px) {
      .rackup-toc { column-count: 2; }
    }
  }}

 @body{
  @div[class: "navbar"]{
   @a[class: "logo" href: "https://samth.github.io/rackup/"]{rackup}
   @a[href: "https://samth.github.io/rackup/install.sh"]{install.sh}
   @a[href: "https://github.com/samth/rackup"]{GitHub}
   @a[href: "https://github.com/samth/rackup/blob/main/README.md"]{README}
  }

  @div[class: "rackup-page"]{

   @; ── Header ──────────────────────────────────────────────────────
   @div[class: "rackup-doc-header"]{
    @h1{Documentation}
    @p{Comprehensive command reference and usage guide.
       See the @a[href: "https://samth.github.io/rackup/"]{main page} for
       installation and an overview.}
   }

   @; ── Table of contents ───────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{Contents}
    @ul[class: "rackup-toc"]{
     @li{@a[href: "#install"]{install}}
     @li{@a[href: "#list"]{list}}
     @li{@a[href: "#available"]{available}}
     @li{@a[href: "#default"]{default}}
     @li{@a[href: "#current"]{current}}
     @li{@a[href: "#which"]{which}}
     @li{@a[href: "#switch"]{switch}}
     @li{@a[href: "#shell"]{shell}}
     @li{@a[href: "#run"]{run}}
     @li{@a[href: "#link"]{link}}
     @li{@a[href: "#remove"]{remove}}
     @li{@a[href: "#prompt"]{prompt}}
     @li{@a[href: "#reshim"]{reshim}}
     @li{@a[href: "#init"]{init}}
     @li{@a[href: "#self-upgrade"]{self-upgrade}}
     @li{@a[href: "#runtime"]{runtime}}
     @li{@a[href: "#uninstall"]{uninstall}}
     @li{@a[href: "#doctor"]{doctor}}
     @li{@a[href: "#version"]{version}}
     @li{@a[href: "#shell-integration"]{Shell integration}}
     @li{@a[href: "#environment-variables"]{Environment variables}}
     @li{@a[href: "#directory-layout"]{Directory layout}}
     @li{@a[href: "#toolchain-resolution"]{Toolchain resolution}}
     @li{@a[href: "#migration"]{Migration guide}}
    }}

   @; ── install ─────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "install"]{
    @h2{@code{rackup install}}
    @p{Install a Racket toolchain from official release, pre-release, or snapshot installers.}
    @(shell-block "rackup install <spec> [flags]")
    @h3{Install specs}
    @p{The @code{<spec>} argument selects which toolchain to install:}
    @ul{
     @li{@code{stable} — the current stable Racket release}
     @li{@code{pre-release} — the latest pre-release build}
     @li{@code{snapshot} — the latest snapshot build (auto-selects a mirror)}
     @li{@code{snapshot:utah} or @code{snapshot:northwestern} — snapshot from a specific mirror}
     @li{A numeric version like @code{8.18}, @code{7.9}, @code{5.2}, @code{4.2.5}, or @code{372}}
    }
    @h3{Flags}
    @table[class: "rackup-opt-table"]{
     @(opt-row "--variant cs|bc" "Override VM variant (default depends on version).")
     @(opt-row "--distribution full|minimal" "Install full or minimal distribution (default: full).")
     @(opt-row "--snapshot-site auto|utah|northwestern" "Choose snapshot mirror (default: auto).")
     @(opt-row "--arch <arch>" "Override target architecture (default: host arch).")
     @(opt-row "--set-default" "Set installed toolchain as the global default.")
     @(opt-row "--force" "Reinstall if the same canonical toolchain is already installed.")
     @(opt-row "--no-cache" "Redownload installer instead of using cache.")
     @(opt-row "--installer-ext sh|tgz|dmg" "Force installer extension (default: platform-dependent).")
     @(opt-row "--quiet" "Show minimal output (errors + final result lines).")
     @(opt-row "--verbose" "Show detailed installer URL/path output.")
    }
    @h3{Examples}
    @(shell-block
      "rackup install stable\n"
      "rackup install 8.18 --variant cs\n"
      "rackup install snapshot --snapshot-site utah\n"
      "rackup install pre-release --distribution minimal --set-default")
   }

   @; ── list ────────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "list"]{
    @h2{@code{rackup list}}
    @p{List installed toolchains and show default/active tags.}
    @(shell-block "rackup list [--ids]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "--ids" "Print only toolchain IDs, one per line (for scripting).")
    }
    @p{Output shows each toolchain's ID, resolved version, variant, and distribution.
       Tags like @code{[default]} and @code{[active]} indicate the global default
       and the currently active toolchain (set via @code{rackup switch} or
       @code{RACKUP_TOOLCHAIN}).}
   }

   @; ── available ───────────────────────────────────────────────────
   @div[class: "rackup-section" id: "available"]{
    @h2{@code{rackup available}}
    @p{List install aliases (stable, pre-release, snapshot) and numeric release versions.
       This queries the Racket download server for the full list of published releases.}
    @(shell-block "rackup available [--all|--limit N]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "--all" "Show all parsed release versions.")
     @(opt-row "--limit N" "Show at most N release versions (default: 20).")
    }
    @h3{Examples}
    @(shell-block
      "rackup available\n"
      "rackup available --limit 50\n"
      "rackup available --all")
   }

   @; ── default ─────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "default"]{
    @h2{@code{rackup default}}
    @p{Show, set, or clear the global default toolchain. The default determines
       which toolchain the shims use when no per-shell override
       (@code{RACKUP_TOOLCHAIN}) is active. If the requested toolchain spec is
       not installed, interactive shells are prompted to install it.}
    @(shell-block "rackup default [id|status|set <toolchain>|clear|<toolchain>|--unset]")
    @h3{Subcommands}
    @table[class: "rackup-opt-table"]{
     @(opt-row "(no argument)" "Print the default toolchain ID (blank if none).")
     @(opt-row "id" "Same as no argument.")
     @(opt-row "status" "Print set<TAB><id> or unset.")
     @(opt-row "set <toolchain>" "Set the given toolchain as the default.")
     @(opt-row "<toolchain>" "Shorthand for set <toolchain>.")
     @(opt-row "clear" "Clear the default toolchain.")
     @(opt-row "--unset" "Same as clear.")
    }
    @h3{Examples}
    @(shell-block
      "rackup default              # show current default\n"
      "rackup default stable       # set default to stable\n"
      "rackup default set 8.18     # set default to 8.18\n"
      "rackup default status       # print set/unset and id\n"
      "rackup default clear        # clear the default")
   }

   @; ── current ─────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "current"]{
    @h2{@code{rackup current}}
    @p{Show the active toolchain and whether it comes from shell activation
       (@code{RACKUP_TOOLCHAIN}) or the global default.}
    @(shell-block "rackup current [id|source|line]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "(no argument)" "Print the active ID and source.")
     @(opt-row "id" "Print only the active toolchain ID (blank if none).")
     @(opt-row "source" "Print env, default, or none.")
     @(opt-row "line" "Print <id><TAB><source>.")
    }
   }

   @; ── which ───────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "which"]{
    @h2{@code{rackup which}}
    @p{Show the real executable path for a tool in a toolchain. Without
       @code{--toolchain}, uses the active toolchain.}
    @(shell-block "rackup which <exe> [--toolchain <toolchain>]")
    @h3{Examples}
    @(shell-block
      "rackup which racket\n"
      "rackup which raco --toolchain 8.18")
   }

   @; ── switch ──────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "switch"]{
    @h2{@code{rackup switch}}
    @p{Switch the active toolchain in the current shell without changing the
       global default. When run via the shell integration installed by
       @code{rackup init}, this updates the current shell's environment
       immediately. Otherwise, it emits shell code that you can @code{eval}.}
    @(shell-block "rackup switch <toolchain> | rackup switch --unset")
    @p{If the requested toolchain is not installed, you are prompted to install it.}
    @h3{Examples}
    @(shell-block
      "rackup switch stable\n"
      "rackup switch 8.18\n"
      "rackup switch --unset       # deactivate per-shell override")
   }

   @; ── shell ───────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "shell"]{
    @h2{@code{rackup shell}}
    @p{Emit shell code to activate or deactivate a toolchain in the current
       shell. This is the low-level primitive used by @code{rackup switch} and
       the shell wrapper function. Most users should use @code{rackup switch}
       instead.}
    @(shell-block "rackup shell <toolchain> | rackup shell --deactivate")
    @h3{Example}
    @(shell-block "eval \"$(rackup shell 8.18)\"")
   }

   @; ── run ─────────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "run"]{
    @h2{@code{rackup run}}
    @p{Run a command under a specific toolchain without changing defaults or
       the shell environment. Sets @code{PLTHOME}, @code{PLTADDONDIR},
       @code{PATH}, and @code{RACKUP_TOOLCHAIN} for the subprocess only.}
    @(shell-block "rackup run <toolchain> -- <command> [args...]")
    @p{The @code{--} separator is required between the toolchain spec and the
       command to run.}
    @h3{Examples}
    @(shell-block
      "rackup run 8.18 -- racket -e '(displayln (version))'\n"
      "rackup run stable -- raco pkg install gregor\n"
      "rackup run snapshot -- raco test .")
   }

   @; ── link ────────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "link"]{
    @h2{@code{rackup link}}
    @p{Link an in-place or locally built Racket tree as a managed toolchain.
       The linked directory is not copied; rackup creates a symlink and
       metadata so that shims and @code{rackup switch} work with it.}
    @(shell-block "rackup link <name> <path> [--set-default] [--force]")
    @h3{Accepted paths}
    @ul{
     @li{A Racket source checkout root (containing @code{racket/bin} and @code{racket/collects}).}
     @li{A @code{PLTHOME} directory (containing @code{bin} and @code{collects} directly).}
    }
    @table[class: "rackup-opt-table"]{
     @(opt-row "--set-default" "Set the linked toolchain as the global default.")
     @(opt-row "--force" "Replace an existing link with the same local name.")
    }
    @h3{Examples}
    @(shell-block
      "rackup link dev ~/src/racket\n"
      "rackup link dev ~/src/racket --set-default\n"
      "rackup link cs-head ~/src/racket --force")
   }

   @; ── remove ──────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "remove"]{
    @h2{@code{rackup remove}}
    @p{Remove one installed or linked toolchain and its per-toolchain addon
       directory. For linked toolchains, only the rackup metadata and symlink
       are removed; the original source tree is untouched. Shims are rebuilt
       automatically afterward.}
    @(shell-block "rackup remove <toolchain>")
    @p{Also removes orphan/partial toolchain directories that were left behind
       by interrupted installs.}
   }

   @; ── prompt ──────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "prompt"]{
    @h2{@code{rackup prompt}}
    @p{Print prompt/status information for the active toolchain. Designed to be
       called from @code{PS1} or a prompt function. Prints nothing when no
       active/default toolchain is configured. When shell integration is active,
       the shell wrapper handles this without starting Racket for speed.}
    @(shell-block "rackup prompt [--long|--short|--raw|--source]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "(default)" "Print a compact label like racket-9.1.")
     @(opt-row "--long" "Print the long bracketed form: [rk:<toolchain-id>].")
     @(opt-row "--short" "Same as default.")
     @(opt-row "--raw" "Print only the active toolchain ID.")
     @(opt-row "--source" "Print <id><TAB><env|default>.")
    }
    @h3{Shell prompt integration}
    @(shell-block
      "# Add to .bashrc / .zshrc:\n"
      "PS1='$(rackup prompt) '$PS1")
   }

   @; ── reshim ──────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "reshim"]{
    @h2{@code{rackup reshim}}
    @p{Rebuild shim executables from the union of all installed toolchain
       executables. This runs automatically on @code{install}, @code{link},
       @code{remove}, and @code{default set}, but can be run manually if
       shims get out of sync.}
    @(shell-block "rackup reshim")
    @p{Shims are small scripts placed in @code{~/.rackup/shims/} that
       delegate to the active toolchain's real executable. Common shims
       include @code{racket}, @code{raco}, @code{scribble}, @code{drracket},
       @code{slideshow}, @code{gracket}, @code{mzscheme}, and @code{mzc}.}
   }

   @; ── init ────────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "init"]{
    @h2{@code{rackup init}}
    @p{Install or update shell integration in @code{~/.bashrc} or
       @code{~/.zshrc}. Writes a managed block that sources
       @code{~/.rackup/shell/rackup.<shell>}. The managed block adds the shims
       directory to @code{PATH} and defines the @code{rackup} shell function
       that wraps @code{rackup switch} so it takes effect in the current shell.}
    @(shell-block "rackup init [--shell bash|zsh]")
    @p{If @code{--shell} is omitted, the current shell is detected
       automatically.}
   }

   @; ── self-upgrade ────────────────────────────────────────────────
   @div[class: "rackup-section" id: "self-upgrade"]{
    @h2{@code{rackup self-upgrade}}
    @p{Upgrade rackup's own code by rerunning the bootstrap installer into the
       current @code{RACKUP_HOME}. By default this skips shell init edits and
       keeps your current shell config unchanged.}
    @(shell-block "rackup self-upgrade [--with-init]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "--with-init" "Allow the installer to run shell init updates.")
    }
    @h3{Advanced}
    @p{Set @code{RACKUP_SELF_UPGRADE_INSTALL_SH} to a path or URL to override
       the install script source (useful for testing dev branches).}
   }

   @; ── runtime ─────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "runtime"]{
    @h2{@code{rackup runtime}}
    @p{Manage rackup's hidden internal Racket runtime. This is a minimal
       Racket installation used to run rackup itself; it is separate from user
       toolchains and is not exposed via shims or @code{PATH}.}
    @(shell-block "rackup runtime status|install|upgrade")
    @table[class: "rackup-opt-table"]{
     @(opt-row "status" "Show whether the hidden runtime is present and its metadata.")
     @(opt-row "install" "Install the hidden runtime if missing (or adopt an existing Racket).")
     @(opt-row "upgrade" "Install a newer hidden runtime if one is available.")
    }
   }

   @; ── uninstall ───────────────────────────────────────────────────
   @div[class: "rackup-section" id: "uninstall"]{
    @h2{@code{rackup uninstall}}
    @p{Remove all rackup-managed data and shell init blocks. This is
       destructive and cannot be undone.}
    @(shell-block "rackup uninstall [--yes]")
    @table[class: "rackup-opt-table"]{
     @(opt-row "--yes" "Skip the interactive DELETE confirmation prompt.")
    }
    @h3{What gets deleted}
    @ul{
     @li{The hidden runtime used to run rackup.}
     @li{All installed toolchains and linked-toolchain metadata/overlays.}
     @li{Shims, caches, downloaded installers, and per-toolchain addon dirs/packages.}
     @li{Rackup-managed init blocks from @code{~/.bashrc} and @code{~/.zshrc}.}
    }
    @p{Linked local source trees are @em{not} deleted — only rackup's links
       to them.}
   }

   @; ── doctor ──────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "doctor"]{
    @h2{@code{rackup doctor}}
    @p{Print diagnostics for rackup paths, hidden runtime, and installed
       toolchains. Useful when troubleshooting installation or shim issues.
       Reports on:}
    @ul{
     @li{@code{RACKUP_HOME} location and contents.}
     @li{Hidden runtime status and version.}
     @li{Installed toolchains, their metadata, and whether their directories exist.}
     @li{Shim directory contents and @code{PATH} status.}
    }
    @(shell-block "rackup doctor")
   }

   @; ── version ─────────────────────────────────────────────────────
   @div[class: "rackup-section" id: "version"]{
    @h2{@code{rackup version}}
    @p{Print rackup version information (git commit hash and date).}
    @(shell-block "rackup version")
   }

   @; ── Shell integration ───────────────────────────────────────────
   @div[class: "rackup-section" id: "shell-integration"]{
    @h2{Shell integration}
    @p{After the initial bootstrap, run @code{rackup init} to set up your
       shell. This adds a small managed block to your @code{.bashrc} or
       @code{.zshrc} that:}
    @ul{
     @li{Adds @code{~/.rackup/shims} to @code{PATH} so @code{racket},
         @code{raco}, etc. resolve to rackup shims.}
     @li{Defines a @code{rackup} shell function that wraps the real
         @code{rackup} binary. When you run @code{rackup switch}, the wrapper
         evals the emitted shell code so the switch takes effect in the
         current shell, without starting a subshell.}
    }
    @(shell-block
      "rackup init --shell bash   # or zsh")
    @p{Once initialized, switching toolchains takes effect immediately:}
    @(shell-block
      "$ rackup switch 8.18\n"
      "$ racket --version           # uses 8.18\n"
      "$ rackup switch stable\n"
      "$ racket --version           # back to stable")
    @p{The managed block is delimited by marker comments so that
       @code{rackup init} can update it idempotently and
       @code{rackup uninstall} can remove it cleanly.}
   }

   @; ── Environment variables ───────────────────────────────────────
   @div[class: "rackup-section" id: "environment-variables"]{
    @h2{Environment variables}
    @h3{User-facing}
    @table[class: "rackup-opt-table"]{
     @(opt-row "RACKUP_HOME" "Override the rackup state directory (default: ~/.rackup).")
     @(opt-row "RACKUP_TOOLCHAIN" "Override the active toolchain for the current shell session. Set by rackup switch; can also be set manually.")
    }
    @h3{Set by rackup when activating a toolchain}
    @table[class: "rackup-opt-table"]{
     @(opt-row "PLTHOME" "Root of the active Racket installation.")
     @(opt-row "PLTADDONDIR" "Per-toolchain addon directory (packages, compiled files).")
     @(opt-row "PATH" "Prepended with the shims directory.")
    }
    @p{Rackup saves and restores any user-set values of @code{PLTHOME},
       @code{PLTCOLLECTS}, @code{PLTADDONDIR}, @code{PLTCOMPILEDROOTS},
       @code{PLTUSERHOME}, @code{RACKET_XPATCH}, and
       @code{PLT_COMPILED_FILE_CHECK} before overriding them, so
       @code{rackup run} passes through your original settings to the
       subprocess.}
   }

   @; ── Directory layout ────────────────────────────────────────────
   @div[class: "rackup-section" id: "directory-layout"]{
    @h2{Directory layout}
    @p{All rackup state lives under @code{RACKUP_HOME} (default @code{~/.rackup}):}
    @(shell-block
      "~/.rackup/\n"
      "  bin/rackup              # the rackup script\n"
      "  libexec/                # rackup's Racket source code\n"
      "  runtime/                # hidden internal Racket runtime\n"
      "  toolchains/             # installed/linked toolchains\n"
      "    racket-9.1-cs-full/   #   example installed toolchain\n"
      "    local-dev/            #   example linked toolchain (symlink)\n"
      "  addons/                 # per-toolchain addon directories\n"
      "    racket-9.1-cs-full/   #   packages, compiled files, etc.\n"
      "  shims/                  # executable shims (racket, raco, ...)\n"
      "  shell/                  # generated shell integration scripts\n"
      "  cache/                  # downloaded installer cache\n"
      "  index.rktd              # toolchain registry")
   }

   @; ── Toolchain resolution ────────────────────────────────────────
   @div[class: "rackup-section" id: "toolchain-resolution"]{
    @h2{Toolchain resolution}
    @p{The active toolchain is resolved in this order:}
    @ol{
     @li{@code{RACKUP_TOOLCHAIN} environment variable (set by
         @code{rackup switch}).}
     @li{The global default (set by @code{rackup default}).}
    }
    @p{When you run a shimmed command like @code{racket}, the shim looks up
       the active toolchain, resolves its @code{PLTHOME}, and @code{exec}s the
       real binary from the toolchain's @code{bin/} directory.}
    @h3{Spec matching}
    @p{When specifying a toolchain for commands like @code{default},
       @code{switch}, @code{remove}, or @code{run}, rackup matches against
       installed toolchain IDs. For @code{install}, the spec is resolved
       against the Racket download infrastructure:}
    @ul{
     @li{@code{stable} → queries @code{version.txt} from
         @code{download.racket-lang.org}.}
     @li{@code{pre-release} → queries the pre-release metadata endpoint.}
     @li{@code{snapshot} / @code{snapshot:utah} / @code{snapshot:northwestern}
         → queries snapshot @code{table.rktd} for the latest build.}
     @li{Numeric versions (e.g. @code{8.18}) → mapped to the exact release
         installer URL.}
    }
   }

   @; ── Migrating from racket-dev-goodies ───────────────────────────
   @div[class: "rackup-section" id: "migration"]{
    @h2{Migrating from racket-dev-goodies}
    @p{If you previously used
       @a[href: "https://github.com/takikawa/racket-dev-goodies"]{racket-dev-goodies}
       (the @code{plt} shell function and @code{plt-bin} symlinks), rackup
       replaces it entirely.}
    @ol{
     @li{Remove the @code{plt-alias.bash} source line from your
         @code{.bashrc}/@code{.zshrc} and remove any @code{plt-bin} symlinks
         from your @code{PATH}. The @code{plt} function sets @code{PLTHOME}
         globally, which conflicts with rackup's per-toolchain environment
         management.}
     @li{Install rackup and re-register your Racket builds:}
    }
    @(shell-block
      "rackup link dev ~/src/racket\n"
      "rackup link 8.15 /usr/local/racket-8.15\n"
      "rackup default set dev")
    @p{For release versions you can also use @code{rackup install}:}
    @(shell-block
      "rackup install stable\n"
      "rackup install 8.15")
    @h3{Equivalents at a glance}
    @table[class: "rackup-cmd-table"]{
     @tr{@td{@code{plt ~/src/racket}} @td{@code{rackup link dev ~/src/racket && rackup default set dev}}}
     @tr{@td{@code{plt} (show current)} @td{@code{rackup current}}}
     @tr{@td{@code{plt-make-links.sh}} @td{@code{rackup reshim} (automatic on install/link)}}
     @tr{@td{@code{plt-fresh-build}} @td{Build manually, then @code{rackup link}}}
    }
   }

  }
 }
}
