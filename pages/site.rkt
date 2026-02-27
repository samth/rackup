#lang plt-web

(require plt-web/style)

(define rackup-site
  (site "www"
        #:navigation
        (list @a[href: "./install.sh"]{install.sh}
              @a[href: "https://github.com/samth/rackup"]{GitHub}
              @a[href: "https://github.com/samth/rackup/blob/main/README.md"]{README})
        #:page-headers
        @list{
          @style[type: "text/css"]{
            html, body {
              background: #f4efe7;
              color: #221b1c;
            }
            body {
              font-family: "Lucida Grande", "Lucida Sans Unicode", Verdana, sans-serif;
            }
            .navbar.gumby-content {
              background: #fffdf9;
              border-bottom: 1px solid #e1d8ca;
              box-shadow: 0 1px 0 rgba(0, 0, 0, 0.04);
            }
            .navbar ul li a,
            .navbar .logo {
              color: #2a2324;
            }
            .navbar ul li a {
              font-size: 0.86rem;
              font-weight: 700;
              letter-spacing: 0.04em;
              text-transform: uppercase;
            }
            .bodycontent {
              margin: 0;
              max-width: none;
              padding: 0 0 5rem;
            }
            .rackup-page {
              margin: 0 auto;
              max-width: 1200px;
            }
            .rackup-utility {
              align-items: center;
              border-bottom: 1px solid #e4d9ca;
              color: #5f5353;
              display: flex;
              flex-wrap: wrap;
              gap: 0.85rem;
              justify-content: space-between;
              padding: 1rem 1.5rem 0.95rem;
            }
            .rackup-utility strong {
              color: #991b1e;
            }
            .rackup-utility-links {
              display: flex;
              flex-wrap: wrap;
              gap: 0.85rem;
            }
            .rackup-utility-links a {
              color: #5f5353;
              font-size: 0.9rem;
              text-decoration: none;
            }
            .rackup-utility-links a:hover {
              color: #991b1e;
            }
            .rackup-stage {
              background: linear-gradient(180deg, #fffdf9 0%, #f8f2e9 100%);
              border-bottom: 1px solid #e4d9ca;
              border-top: 6px solid #9f1d20;
              padding: 2.5rem 1.5rem 3rem;
            }
            .rackup-stage-grid {
              align-items: start;
              display: grid;
              gap: 2rem;
              grid-template-columns: minmax(0, 1.15fr) minmax(300px, 0.85fr);
            }
            .rackup-eyebrow {
              color: #9f1d20;
              font-size: 0.82rem;
              font-weight: 700;
              letter-spacing: 0.14em;
              margin-bottom: 1rem;
              text-transform: uppercase;
            }
            .rackup-stage h1,
            .rackup-section h2,
            .rackup-pillar h3,
            .rackup-editorial-copy h3,
            .rackup-link-grid h3 {
              color: #231b1c;
              font-family: Georgia, "Times New Roman", serif;
              line-height: 1.05;
            }
            .rackup-stage h1 {
              font-size: clamp(3rem, 6vw, 5rem);
              margin: 0 0 1rem;
            }
            .rackup-stage-lead {
              color: #4a4040;
              font-size: 1.16rem;
              line-height: 1.72;
              margin: 0 0 1.25rem;
              max-width: 40rem;
            }
            .rackup-button-row {
              display: flex;
              flex-wrap: wrap;
              gap: 0.8rem;
              margin: 1.3rem 0 1.4rem;
            }
            .rackup-button,
            .rackup-button:visited,
            .rackup-button-secondary,
            .rackup-button-secondary:visited {
              border-radius: 999px;
              display: inline-block;
              font-size: 0.92rem;
              font-weight: 700;
              padding: 0.72rem 1.1rem;
              text-decoration: none;
            }
            .rackup-button,
            .rackup-button:visited {
              background: #9f1d20;
              color: #fff;
            }
            .rackup-button-secondary,
            .rackup-button-secondary:visited {
              background: #f1e8db;
              color: #2d2526;
            }
            .rackup-shell {
              background: #262223;
              border-radius: 10px;
              box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.06);
              color: #f8f3ed;
              margin: 0;
              overflow-x: auto;
              padding: 1rem 1.1rem;
            }
            .rackup-shell + .rackup-shell {
              margin-top: 0.8rem;
            }
            .rackup-shell code {
              color: inherit;
              font-family: "Iosevka", "SFMono-Regular", Consolas, monospace;
              font-size: 0.95rem;
              white-space: pre-wrap;
            }
            .rackup-stage-note {
              color: #6a5d5d;
              font-size: 0.95rem;
              line-height: 1.65;
              margin-top: 1rem;
            }
            .rackup-stage-note code,
            .rackup-pillar code,
            .rackup-editorial-copy code,
            .rackup-link-grid code {
              background: #efe6da;
              border-radius: 4px;
              padding: 0.08rem 0.32rem;
            }
            .rackup-stage-panel {
              background: #fff;
              border: 1px solid #e2d8cb;
              box-shadow: 0 12px 40px rgba(58, 37, 28, 0.08);
              padding: 1.4rem;
            }
            .rackup-mark {
              display: block;
              margin: 0 auto 1.2rem;
              max-width: 220px;
              width: 58%;
            }
            .rackup-panel-title {
              color: #6f6161;
              font-size: 0.82rem;
              font-weight: 700;
              letter-spacing: 0.14em;
              margin: 0 0 0.9rem;
              text-transform: uppercase;
            }
            .rackup-panel-copy {
              color: #4f4545;
              line-height: 1.68;
              margin: 0 0 1rem;
            }
            .rackup-section {
              padding: 3.5rem 1.5rem 0;
            }
            .rackup-section h2 {
              font-size: clamp(2rem, 4vw, 3rem);
              margin: 0 0 0.8rem;
            }
            .rackup-section-intro {
              color: #564b4c;
              font-size: 1.06rem;
              line-height: 1.7;
              margin: 0 0 1.6rem;
              max-width: 44rem;
            }
            .rackup-pillars {
              display: grid;
              gap: 1.25rem;
              grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
            }
            .rackup-pillar {
              border-top: 4px solid #9f1d20;
              padding-top: 0.9rem;
            }
            .rackup-pillar h3 {
              font-size: 1.4rem;
              margin: 0 0 0.55rem;
            }
            .rackup-pillar p {
              color: #4f4545;
              line-height: 1.66;
              margin: 0 0 0.65rem;
            }
            .rackup-pillar ul {
              color: #6a5d5d;
              line-height: 1.6;
              margin: 0;
              padding-left: 1.1rem;
            }
            .rackup-editorial {
              display: grid;
              gap: 1.6rem;
              grid-template-columns: repeat(auto-fit, minmax(290px, 1fr));
              margin-top: 2rem;
            }
            .rackup-editorial-block {
              background: #fffdf9;
              border: 1px solid #e4d9ca;
              padding: 1.4rem;
            }
            .rackup-editorial-copy h3 {
              font-size: 2rem;
              margin: 0 0 0.85rem;
            }
            .rackup-editorial-copy p {
              color: #4f4545;
              line-height: 1.72;
              margin: 0 0 0.85rem;
            }
            .rackup-editorial-copy ul {
              color: #4f4545;
              line-height: 1.65;
              margin: 0;
              padding-left: 1.1rem;
            }
            .rackup-link-grid {
              display: grid;
              gap: 1.2rem;
              grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
              margin-top: 1.75rem;
            }
            .rackup-link-grid > * {
              background: #fff;
              border: 1px solid #e4d9ca;
              padding: 1.2rem;
            }
            .rackup-link-grid h3 {
              font-size: 1.55rem;
              margin: 0 0 0.55rem;
            }
            .rackup-link-grid p,
            .rackup-link-grid ul {
              color: #4f4545;
              line-height: 1.68;
              margin: 0;
            }
            .rackup-link-grid ul {
              padding-left: 1.1rem;
            }
            .rackup-footer-note {
              color: #6c6060;
              font-size: 0.95rem;
              line-height: 1.65;
              margin-top: 1rem;
            }
            .rackup-inline-link,
            .rackup-inline-link:visited {
              color: #9f1d20;
              text-decoration: none;
            }
            .rackup-inline-link:hover {
              text-decoration: underline;
            }
          }}))

(define (shell-block id text)
  @pre[class: "rackup-shell"]{@code[id: id]{@text}})

(define (pill-link class id label)
  @a[class: class href: "#" id: id]{@label})

(void
 (page
  #:site rackup-site
  #:file "index.html"
  #:title "rackup"
  #:window-title "rackup"
  #:description "rackup is a toolchain manager for Racket with a curl | sh bootstrap."
  @list{
    @div[class: "rackup-page"]{
      @div[class: "rackup-utility"]{
        @div{
          @strong{rackup} brings stable releases, old PLT Scheme builds,
          pre-releases, snapshots, and linked source trees under one Racket-shaped CLI.
        }
        @div[class: "rackup-utility-links"]{
          @a[href: "https://download.racket-lang.org"]{download.racket-lang.org}
          @a[href: "https://pre-release.racket-lang.org"]{pre-release.racket-lang.org}
          @a[href: "https://docs.racket-lang.org"]{docs}
        }}

      @div[class: "rackup-stage"]{
        @div[class: "rackup-stage-grid"]{
          @div{
            @div[class: "rackup-eyebrow"]{Racket Toolchains, Not a Different World}
            @h1{Install Racket directly, then keep switching like it was built in.}
            @p[class: "rackup-stage-lead"]{
              @code{rackup} bootstraps itself with @code{curl | sh}, installs real Racket
              toolchains from the usual places, and keeps the command surface intact:
              @code{racket}, @code{raco}, @code{scribble}, @code{slideshow}, @code{scheme},
              @code{petite}, and the rest all follow the selected toolchain.
            }
            @div[class: "rackup-button-row"]{
              @(pill-link "rackup-button" "copy-install-cmd" "Copy install command")
              @a[class: "rackup-button-secondary" href: "./install.sh"]{Read install.sh}
              @a[class: "rackup-button-secondary" href: "https://github.com/samth/rackup"]{Browse source}
            }
            @(shell-block "install-cmd" "curl -fsSL https://samth.github.io/rackup/install.sh | sh")
            @p[class: "rackup-stage-note"]{
              The bootstrap installs @code{rackup} plus a hidden internal runtime. Your first
              user toolchain is then one command away: @code{rackup install stable}.
            }}
          @div[class: "rackup-stage-panel"]{
            @p[class: "rackup-panel-title"]{The shape of the thing}
            @img[class: "rackup-mark" src: "logo.png" alt: "Racket logo"]
            @p[class: "rackup-panel-copy"]{
              The goal is not a parallel ecosystem. It is a better entry point into the existing
              Racket one: real installers, real binaries, one managed shim layer.
            }
            @(shell-block "hero-ops" "$ rackup install stable\n$ rackup install pre-release\n$ rackup default stable\n$ racket -e '(displayln (version))'")
            @(shell-block "hero-link" "$ rackup link localsrc ~/src/racket --set-default\n$ scheme --help\n$ petite --help")
          }}}

      @div[class: "rackup-section"]{
        @h2{One manager for the release graph Racket actually has}
        @p[class: "rackup-section-intro"]{
          The official Racket downloads are not one flat stream. There are stable releases,
          historical releases, pre-releases, snapshots, platform-specific installers, and local
          source trees. @code{rackup} is meant to absorb that shape instead of hiding it.
        }
        @div[class: "rackup-pillars"]{
          @div[class: "rackup-pillar"]{
            @h3{Stable}
            @p{Install the current release or pin old releases directly.}
            @ul{
              @li{@code{rackup install stable}}
              @li{@code{rackup install 8.18}}
              @li{@code{rackup install 5.2}}}}
          @div[class: "rackup-pillar"]{
            @h3{Historical}
            @p{Reach back into PLT Scheme-era installers when they still exist upstream.}
            @ul{
              @li{@code{rackup install 4.2.5}}
              @li{@code{rackup install 372}}
              @li{@code{rackup available 4.}}}}
          @div[class: "rackup-pillar"]{
            @h3{Pre-release}
            @p{Install from @code{pre-release.racket-lang.org} without custom scripting.}
            @ul{
              @li{@code{rackup install pre-release}}
              @li{@code{rackup available pre-release}}
              @li{@code{rackup default pre-release}}}}
          @div[class: "rackup-pillar"]{
            @h3{Snapshots}
            @p{Track snapshot builds when you need to follow current development.}
            @ul{
              @li{@code{rackup install snapshot}}
              @li{@code{rackup install snapshot:utah}}
              @li{@code{rackup available snapshot}}}}
          @div[class: "rackup-pillar"]{
            @h3{Local Trees}
            @p{Link a built-from-source tree and export its executables through the shim set.}
            @ul{
              @li{@code{rackup link localsrc ~/src/racket}}
              @li{@code{scheme} and @code{petite} included}
              @li{@code{rackup current path}}}}}}

      @div[class: "rackup-section"]{
        @h2{Operate it the way Racketeers already work}
        @div[class: "rackup-editorial"]{
          @div[class: "rackup-editorial-block"]{
            @div[class: "rackup-editorial-copy"]{
              @h3{Install, switch, inspect}
              @p{
                The everyday loop is meant to be short and obvious. Install a toolchain,
                let the first one become default, switch later with @code{rackup default},
                and ask @code{rackup current} or @code{rackup which} when you need to know
                what the shims are targeting.
              }
              @p{
                The shims are ordinary commands on @code{PATH}, so your shell prompt, editor,
                and scripts keep using @code{racket} and friends instead of a special wrapper.
              }
              @ul{
                @li{@code{rackup list} for installed toolchains}
                @li{@code{rackup available} for installable ones}
                @li{@code{rackup self-upgrade} for upgrading @code{rackup} itself}}}
          }
          @div[class: "rackup-editorial-block"]{
            @(shell-block "workflow-cmd" "$ rackup install stable\n$ rackup install pre-release\n$ rackup default stable\n$ rackup current\n$ rackup which racket\n$ raco pkg install gregor")
          }}
        @div[class: "rackup-editorial"]{
          @div[class: "rackup-editorial-block"]{
            @(shell-block "shim-cmd" "$ racket -e '(displayln (version))'\n$ raco setup --check-pkg-deps\n$ scribble --help\n$ scheme --version\n$ petite --help")
          }
          @div[class: "rackup-editorial-block"]{
            @div[class: "rackup-editorial-copy"]{
              @h3{Manage the whole executable surface}
              @p{
                Racket installations do not stop at @code{racket}. A usable toolchain manager has
                to account for the rest of the install: @code{raco}, @code{scribble},
                @code{slideshow}, @code{drracket} when present, plus Chez executables from linked
                source trees.
              }
              @p{
                That means the shim directory is generated from the selected toolchain instead of
                hard-coding a tiny subset. Linked source installs also surface @code{scheme} and
                @code{petite} automatically.
              }}}}}

      @div[class: "rackup-section"]{
        @h2{Bootstrap now, settle into the normal workflow immediately after}
        @p[class: "rackup-section-intro"]{
          Bootstrap is intentionally separate from installing a user toolchain. That keeps the
          initial install small and makes the next step explicit. Shell integration stays simple:
          a managed file under @code{~/.rackup/} and a short source line in @code{.bashrc} or
          @code{.zshrc}.
        }
        @div[class: "rackup-link-grid"]{
          @div{
            @h3{Bootstrap}
            @(shell-block "noninteractive-cmd" "curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y")
            @p[class: "rackup-footer-note"]{
              For unattended setup, pass @code{-y}. The bootstrap installs @code{rackup}, validates
              its hidden runtime, and can initialize your shell config.
            }}
          @div{
            @h3{Afterward}
            @ul{
              @li{@code{rackup install stable} installs the first toolchain and sets it as default}
              @li{@code{rackup init --shell bash} or @code{zsh} refreshes shell integration}
              @li{@code{rackup uninstall} removes the managed state after explicit confirmation}}}
          @div{
            @h3{Explore}
            @p{
              Read the @a[class: "rackup-inline-link" href: "https://github.com/samth/rackup/blob/main/README.md"]{README},
              inspect the @a[class: "rackup-inline-link" href: "https://github.com/samth/rackup"]{source},
              or compare toolchains with @code{rackup available} before choosing a default.
            }
            @p[class: "rackup-footer-note"]{
              The site is generated with @a[class: "rackup-inline-link" href: "https://docs.racket-lang.org/plt-web/index.html"]{plt-web},
              so it stays in the same family as the rest of the Racket web presence.
            }}}}}

    @script/inline{
      (function () {
        function pageBase() {
          var path = window.location.pathname || "/";
          if (!/\/$/.test(path)) path = path.replace(/\/[^/]*$/, "/");
          return window.location.origin + path.replace(/\/$/, "");
        }

        function setText(id, text) {
          var el = document.getElementById(id);
          if (el) el.textContent = text;
        }

        var base = pageBase();
        var install = base + "/install.sh";
        var installCmd = "curl -fsSL " + install + " | sh";
        var noninteractiveCmd = installCmd + " -s -- -y";

        setText("install-cmd", installCmd);
        setText("noninteractive-cmd", noninteractiveCmd);

        var copyBtn = document.getElementById("copy-install-cmd");
        if (copyBtn && navigator.clipboard) {
          copyBtn.addEventListener("click", function (event) {
            event.preventDefault();
            navigator.clipboard.writeText(installCmd).then(function () {
              var old = copyBtn.textContent;
              copyBtn.textContent = "Copied";
              setTimeout(function () {
                copyBtn.textContent = old;
              }, 1200);
            });
          });
        }
      }());
    }}))
