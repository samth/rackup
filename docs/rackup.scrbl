#lang scribble/html

@; rackup documentation — raw scribble/html, styled to match the GitHub Pages site.
@; Generate with:  scribble --html --dest docs docs/rackup.scrbl
@; or:             racket docs/rackup.scrbl > docs/rackup.html

@(define (shell-block . text)
   @pre[class: "rackup-shell"]{@code{@text}})

@(define (cmd-row cmd desc)
   @tr{@td{@code{@cmd}} @td{@desc}})

@html[lang: "en"]{
 @head{
  @meta[charset: "utf-8"]
  @meta[name: "viewport" content: "width=device-width, initial-scale=1"]
  @title{rackup — Racket toolchain manager}
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

    /* Top install section */
    .rackup-top {
      border-bottom: 1px solid #ddd;
      padding: 2.5rem 0 2rem;
    }
    .rackup-top h1 {
      color: #333;
      font-size: 3rem;
      font-weight: 600;
      margin: 0 0 0.5rem;
    }
    .rackup-top h1 code {
      background: none;
      font-size: inherit;
      padding: 0;
    }
    .rackup-top-desc {
      color: #555;
      font-size: 1.3rem;
      margin: 0 0 1.5rem;
      max-width: 50rem;
    }
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
    .rackup-top pre.rackup-shell code { font-size: 1.3rem; }
    .rackup-note {
      color: #666;
      font-size: 0.9rem;
      margin-top: 0.8rem;
    }
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

    /* Toolchain type grid */
    .rackup-grid {
      display: grid;
      gap: 1.5rem;
      grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
      margin-top: 1rem;
    }
    .rackup-grid h3 {
      color: #0679a7;
      font-size: 1.05rem;
      font-weight: 600;
      margin: 0 0 0.3rem;
    }
    .rackup-grid p {
      color: #555;
      font-size: 0.95rem;
      margin: 0 0 0.4rem;
    }
    .rackup-grid ul {
      color: #555;
      font-size: 0.9rem;
      list-style: none;
      margin: 0;
      padding: 0;
    }
    .rackup-grid ul li { margin-bottom: 0.2rem; }
    .rackup-grid ul li code { font-size: 0.95rem; }

    /* Two-column layout */
    .rackup-two-col {
      display: grid;
      gap: 2rem;
      grid-template-columns: 1fr 1fr;
      margin-top: 1rem;
    }
    @"@"media (max-width: 700px) {
      .rackup-two-col { grid-template-columns: 1fr; }
    }
    .rackup-two-col h3 {
      font-size: 1.05rem;
      font-weight: 600;
      margin: 0 0 0.5rem;
    }
    .rackup-two-col p {
      color: #555;
      margin: 0 0 0.5rem;
    }
    .rackup-two-col ul {
      color: #555;
      margin: 0;
      padding-left: 1.2rem;
    }
    .rackup-two-col ul li { margin-bottom: 0.3rem; }

    /* Command reference table */
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

    /* Option lists */
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

    /* Subsection headings inside sections */
    .rackup-section h3 {
      color: #333;
      font-size: 1.15rem;
      font-weight: 600;
      margin: 1.5rem 0 0.5rem;
    }
    .rackup-section h3:first-child { margin-top: 0; }

    /* Inline definition list style */
    dl.rackup-dl { margin: 0.5rem 0; }
    dl.rackup-dl dt {
      font-weight: 600;
      margin-top: 0.6rem;
    }
    dl.rackup-dl dd {
      color: #555;
      margin: 0.1rem 0 0 1.2rem;
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

   @; ── Hero / install ──────────────────────────────────────────────
   @div[class: "rackup-top"]{
    @h1{@code{rackup}}
    @p[class: "rackup-top-desc"]{
     A toolchain manager for Racket. Install and switch between stable releases,
     pre-releases, snapshots, old PLT Scheme builds, and local source trees.
    }
    @(shell-block "curl -fsSL https://samth.github.io/rackup/install.sh | sh")
    @p[class: "rackup-note"]{
     This installs @code{rackup} itself. Then run @code{rackup install stable}
     to install Racket.
     Pass @code{-y} for non-interactive mode:
    }
    @(shell-block "curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y")
    @p[class: "rackup-note"]{
     Or, to verify the install script's checksum before running it:
    }
    @(shell-block
      "curl -fsSL -o install.sh https://samth.github.io/rackup/install.sh\n"
      "echo \"<sha256>  install.sh\" | sha256sum -c -\n"
      "sh install.sh && rm install.sh")
   }

   @; ── What it manages ─────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{What it manages}
    @p{
     Racket has stable releases, historical releases going back to PLT Scheme,
     pre-release builds, snapshot builds, and local source trees. @code{rackup}
     handles all of them with the same interface.
    }
    @div[class: "rackup-grid"]{
     @div{
      @h3{Stable releases}
      @p{Current or specific versions.}
      @ul{
       @li{@code{rackup install stable}}
       @li{@code{rackup install 8.18}}
       @li{@code{rackup install 5.2}}}}
     @div{
      @h3{Historical}
      @p{PLT Scheme-era installers.}
      @ul{
       @li{@code{rackup install 4.2.5}}
       @li{@code{rackup install 372}}
       @li{@code{rackup available 4.}}}}
     @div{
      @h3{Pre-release and snapshots}
      @p{From @a[href: "https://pre-release.racket-lang.org"]{pre-release}
         and @a[href: "https://snapshot.racket-lang.org"]{snapshot} builds.}
      @ul{
       @li{@code{rackup install pre-release}}
       @li{@code{rackup install snapshot}}
       @li{@code{rackup install snapshot:utah}}}}
     @div{
      @h3{Local source trees}
      @p{Link a built-from-source tree.}
      @ul{
       @li{@code{rackup link dev ~/racket}}
       @li{Exports @code{scheme} and @code{petite} too}}}}}

   @; ── Switching and shims ─────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{Switching and shims}
    @div[class: "rackup-two-col"]{
     @div{
      @p{
       When you install a toolchain, @code{rackup} creates shims for all of its
       executables: @code{racket}, @code{raco}, @code{scribble}, @code{slideshow},
       @code{drracket}, and others. The shims go on your @code{PATH}, so your
       shell, editor, and scripts use @code{racket} directly.
      }
      @p{
       Switch the active toolchain with @code{rackup default}. The first
       toolchain you install becomes the default automatically.
      }}
     @div{
      @(shell-block
        "$ rackup install stable\n"
        "$ rackup install pre-release\n"
        "$ rackup default stable\n"
        "$ racket -e '(displayln (version))'\n"
        "$ raco pkg install gregor")}}}

   @; ── Command reference ───────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{Commands}
    @table[class: "rackup-cmd-table"]{
     @(cmd-row "rackup install <spec>" "Install a toolchain")
     @(cmd-row "rackup list" "List installed toolchains")
     @(cmd-row "rackup available" "List installable toolchains")
     @(cmd-row "rackup default <name>" "Set the global default toolchain")
     @(cmd-row "rackup current" "Show the active toolchain and its source")
     @(cmd-row "rackup switch <name>" "Switch the active toolchain in this shell")
     @(cmd-row "rackup run <name> -- <cmd>" "Run a command using a specific toolchain")
     @(cmd-row "rackup which <cmd>" "Show path for a shimmed command")
     @(cmd-row "rackup link <name> <path>" "Link a local source tree")
     @(cmd-row "rackup remove <name>" "Remove an installed toolchain")
     @(cmd-row "rackup prompt" "Print toolchain info for shell prompt")
     @(cmd-row "rackup reshim" "Rebuild shims from installed toolchains")
     @(cmd-row "rackup doctor" "Print diagnostics")
     @(cmd-row "rackup init --shell <sh>" "Set up shell integration")
     @(cmd-row "rackup self-upgrade" "Upgrade rackup itself")
     @(cmd-row "rackup uninstall" "Remove rackup and all managed state")
     @(cmd-row "rackup version" "Print version info")
    }}

   @; ── install ─────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
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
     @tr{@td{@code{--variant cs|bc}} @td{Override VM variant (default depends on version).}}
     @tr{@td{@code{--distribution full|minimal}} @td{Install full or minimal distribution (default: full).}}
     @tr{@td{@code{--snapshot-site auto|utah|northwestern}} @td{Choose snapshot mirror (default: auto).}}
     @tr{@td{@code{--arch <arch>}} @td{Override target architecture (default: host arch).}}
     @tr{@td{@code{--set-default}} @td{Set installed toolchain as the global default.}}
     @tr{@td{@code{--force}} @td{Reinstall if the same canonical toolchain is already installed.}}
     @tr{@td{@code{--no-cache}} @td{Redownload installer instead of using cache.}}
     @tr{@td{@code{--installer-ext sh|tgz|dmg}} @td{Force installer extension (default: platform-dependent).}}
     @tr{@td{@code{--quiet}} @td{Show minimal output (errors + final result lines).}}
     @tr{@td{@code{--verbose}} @td{Show detailed installer URL/path output.}}
    }
    @h3{Examples}
    @(shell-block
      "rackup install stable\n"
      "rackup install 8.18 --variant cs\n"
      "rackup install snapshot --snapshot-site utah\n"
      "rackup install pre-release --set-default")
   }

   @; ── list ────────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup list}}
    @p{List installed toolchains and show default/active tags.}
    @(shell-block "rackup list [--ids]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--ids}} @td{Print only toolchain IDs, one per line (for scripting).}}
    }}

   @; ── available ───────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup available}}
    @p{List install aliases (stable, pre-release, snapshot) and numeric release versions.}
    @(shell-block "rackup available [--all|--limit N]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--all}} @td{Show all parsed release versions.}}
     @tr{@td{@code{--limit N}} @td{Show at most N release versions (default: 20).}}
    }
    @h3{Examples}
    @(shell-block
      "rackup available\n"
      "rackup available --limit 50\n"
      "rackup available --all")
   }

   @; ── default ─────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup default}}
    @p{Show, set, or clear the global default toolchain.
       If the requested toolchain spec is not installed, interactive shells
       are prompted to install it.}
    @(shell-block "rackup default [id|status|set <toolchain>|clear|<toolchain>|--unset]")
    @h3{Examples}
    @(shell-block
      "rackup default              # show current default\n"
      "rackup default stable       # set default to stable\n"
      "rackup default set 8.18     # set default to 8.18\n"
      "rackup default status       # print set/unset and id\n"
      "rackup default clear        # clear the default\n"
      "rackup default --unset      # same as clear")
   }

   @; ── current ─────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup current}}
    @p{Show the active toolchain and whether it comes from shell activation or global default.}
    @(shell-block "rackup current [id|source|line]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{id}} @td{Print only the active toolchain id (blank if none).}}
     @tr{@td{@code{source}} @td{Print @code{env}, @code{default}, or @code{none}.}}
     @tr{@td{@code{line}} @td{Print @code{<id><TAB><source>}.}}
    }}

   @; ── which ───────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup which}}
    @p{Show the real executable path for a tool in a toolchain.}
    @(shell-block "rackup which <exe> [--toolchain <toolchain>]")
   }

   @; ── switch ──────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup switch}}
    @p{Switch the active toolchain in the current shell without changing the default.
       When run via the shell integration installed by @code{rackup init}, this
       updates the current shell. Otherwise, it emits shell code that you can
       @code{eval}.}
    @(shell-block "rackup switch <toolchain> | rackup switch --unset")
    @h3{Examples}
    @(shell-block
      "rackup switch stable\n"
      "rackup switch 8.18\n"
      "rackup switch --unset")
   }

   @; ── shell ───────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup shell}}
    @p{Emit shell code to activate/deactivate a toolchain in the current shell.
       This is the low-level form used by @code{rackup switch} and the shell
       wrapper.}
    @(shell-block "rackup shell <toolchain> | rackup shell --deactivate")
   }

   @; ── run ─────────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup run}}
    @p{Run a command under a specific toolchain without changing defaults.}
    @(shell-block "rackup run <toolchain> -- <command> [args...]")
    @h3{Example}
    @(shell-block "rackup run 8.18 -- racket -e '(displayln (version))'")
   }

   @; ── link ────────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup link}}
    @p{Link an in-place/local Racket build as a managed toolchain.}
    @(shell-block "rackup link <name> <path> [--set-default] [--force]")
    @h3{Accepted paths}
    @ul{
     @li{A source checkout root containing @code{racket/bin} and @code{racket/collects}.}
     @li{A @code{PLTHOME} directory containing @code{bin} and @code{collects}.}
    }
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--set-default}} @td{Set the linked toolchain as the global default.}}
     @tr{@td{@code{--force}} @td{Replace an existing link with the same local name.}}
    }
    @h3{Example}
    @(shell-block "rackup link dev ~/src/racket")
   }

   @; ── remove ──────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup remove}}
    @p{Remove one installed or linked toolchain and its addon directory.}
    @(shell-block "rackup remove <toolchain>")
   }

   @; ── prompt ──────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup prompt}}
    @p{Print prompt/status information for the active toolchain.
       Prints nothing when no active/default toolchain is configured.
       Handled by the shell wrapper without starting Racket when possible.}
    @(shell-block "rackup prompt [--long|--short|--raw|--source]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--long}} @td{Print the long bracketed form: @code{[rk:<toolchain-id>]}.}}
     @tr{@td{@code{--short}} @td{Print a compact label like @code{racket-9.1} (same as default).}}
     @tr{@td{@code{--raw}} @td{Print only the active toolchain id.}}
     @tr{@td{@code{--source}} @td{Print @code{<id><TAB><env|default>}.}}
    }
    @h3{Shell prompt integration}
    @(shell-block "PS1='$(rackup prompt) '$PS1")
   }

   @; ── reshim ──────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup reshim}}
    @p{Rebuild shim executables from the union of installed toolchain executables.
       This runs automatically on install and link but can be run manually if
       shims get out of sync.}
    @(shell-block "rackup reshim")
   }

   @; ── init ────────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup init}}
    @p{Install or update shell integration in @code{~/.bashrc} or @code{~/.zshrc}.
       Writes a managed block that sources @code{~/.rackup/shell/rackup.<shell>}.}
    @(shell-block "rackup init [--shell bash|zsh]")
   }

   @; ── self-upgrade ────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup self-upgrade}}
    @p{Upgrade rackup's code by rerunning the bootstrap installer into the
       current @code{RACKUP_HOME}. By default this skips shell init edits and
       keeps your current shell config unchanged.}
    @(shell-block "rackup self-upgrade [--with-init]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--with-init}} @td{Allow the installer to run shell init updates.}}
    }
   }

   @; ── runtime ─────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup runtime}}
    @p{Manage rackup's hidden internal runtime used to run rackup itself.}
    @(shell-block "rackup runtime status|install|upgrade")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{status}} @td{Show whether the hidden runtime is present and its metadata.}}
     @tr{@td{@code{install}} @td{Install the hidden runtime if missing (or adopt existing).}}
     @tr{@td{@code{upgrade}} @td{Install a newer hidden runtime if one is available.}}
    }
   }

   @; ── uninstall ───────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup uninstall}}
    @p{Remove rackup-managed data and shell init blocks. This is destructive and
       cannot be undone. It deletes all installed toolchains, the hidden runtime,
       shims, caches, and per-toolchain addon directories. It also removes
       rackup-managed init blocks from @code{~/.bashrc} and @code{~/.zshrc}.}
    @(shell-block "rackup uninstall [--yes]")
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{--yes}} @td{Skip interactive DELETE confirmation.}}
    }
   }

   @; ── doctor ──────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup doctor}}
    @p{Print diagnostics for rackup paths, hidden runtime, and installed toolchains.
       Useful when troubleshooting installation or shim issues.}
    @(shell-block "rackup doctor")
   }

   @; ── version ─────────────────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{@code{rackup version}}
    @p{Print rackup version information (git commit and date).}
    @(shell-block "rackup version")
   }

   @; ── Shell integration ───────────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{Shell integration}
    @p{After bootstrapping, run @code{rackup init} to set up your shell.
       This adds a small managed block to your @code{.bashrc} or @code{.zshrc}
       that puts the shims directory on your @code{PATH} and enables the
       @code{rackup switch} shell function.}
    @(shell-block
      "rackup init --shell bash   # or zsh")
    @p{Once initialized, switching toolchains takes effect immediately in
       the current shell without starting a subshell:}
    @(shell-block
      "rackup switch 8.18\n"
      "racket --version            # uses 8.18")
   }

   @; ── Environment variables ───────────────────────────────────────
   @div[class: "rackup-section"]{
    @h2{Environment variables}
    @table[class: "rackup-opt-table"]{
     @tr{@td{@code{RACKUP_HOME}} @td{Override the rackup state directory (default: @code{~/.rackup}).}}
     @tr{@td{@code{RACKUP_TOOLCHAIN}} @td{Override the active toolchain for the current shell session.}}
    }
    @p{When @code{rackup} activates a toolchain it sets @code{PLTHOME},
       @code{PLTADDONDIR}, and @code{PATH} so that @code{racket}, @code{raco},
       and other executables resolve to the correct installation.}
   }

   @; ── Migrating from racket-dev-goodies ───────────────────────────
   @div[class: "rackup-section"]{
    @h2{Migrating from racket-dev-goodies}
    @p{If you previously used
       @a[href: "https://github.com/takikawa/racket-dev-goodies"]{racket-dev-goodies}
       (the @code{plt} shell function and @code{plt-bin} symlinks), rackup replaces
       it entirely.}
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
