#lang plt-web

(require plt-web/style
         file/sha1)

;; Extract --install-sh <path> from command-line args before plt-web sees them.
(define install-sh-path
  (let loop ([args (vector->list (current-command-line-arguments))]
             [result #f]
             [rest '()])
    (cond
      [(null? args)
       (current-command-line-arguments (list->vector (reverse rest)))
       result]
      [(and (string=? (car args) "--install-sh") (pair? (cdr args)))
       (loop (cddr args) (cadr args) rest)]
      [else
       (loop (cdr args) result (cons (car args) rest))])))

(define install-sh-sha256
  (if install-sh-path
      (bytes->hex-string
       (call-with-input-file install-sh-path sha256-bytes))
      "UNKNOWN"))

(define rackup-site
  (site "www"
        #:navigation
        (list @a[href: "./docs.html"]{Docs}
              @a[href: "./install.sh"]{install.sh}
              @a[href: "https://github.com/samth/rackup"]{GitHub}
              @a[href: "https://github.com/samth/rackup/blob/main/README.md"]{README})
        #:page-headers
        @list{
          @link[rel: "icon" type: "image/svg+xml" href: "./favicon.svg"]
          @style[type: "text/css"]{
            html, body {
              background: white;
              color: #333;
            }
            body {
              font-family: "Helvetica Neue", Helvetica, Arial, sans-serif;
              font-size: 16px;
              line-height: 1.5;
            }
            a {
              color: #0679a7;
            }
            a:hover {
              color: #034b6b;
            }
            .navbar.gumby-content {
              background: white;
              border-bottom: 1px solid #ddd;
            }
            .navbar ul li a,
            .navbar .logo {
              color: #333;
            }
            .navbar ul li a {
              font-size: 0.9rem;
              font-weight: 600;
            }
            .bodycontent {
              margin: 0;
              max-width: none;
              padding: 0 0 4rem;
            }
            .rackup-page {
              margin: 0 auto;
              max-width: 1050px;
              padding: 0 1.5rem;
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
            .rackup-install-row {
              position: relative;
            }
            pre.rackup-shell {
              background: #2d2d2d !important;
              border: none !important;
              border-radius: 6px;
              color: #f0f0f0 !important;
              margin: 0 !important;
              overflow-x: auto;
              padding: 0.8rem 1rem !important;
            }
            pre.rackup-shell::before,
            pre.rackup-shell::after {
              content: none !important;
              display: none !important;
            }
            pre.rackup-shell code {
              background: transparent !important;
              color: #f0f0f0 !important;
              display: block;
              font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
              font-size: 1rem !important;
              line-height: 1.5 !important;
              margin: 0 !important;
              padding: 0 !important;
              white-space: pre-wrap;
            }
            .rackup-shell + .rackup-shell {
              margin-top: 0.6rem;
            }
            .rackup-copy-btn {
              background: transparent;
              border: none;
              color: #888;
              cursor: pointer;
              display: inline-flex;
              padding: 0.4rem;
              position: absolute;
              right: 0.6rem;
              text-decoration: none;
              top: 0.55rem;
            }
            .rackup-copy-btn:hover {
              color: #ddd;
            }
            .rackup-copy-btn svg {
              height: 18px;
              width: 18px;
            }
            .rackup-top pre.rackup-shell code {
              font-size: 1.3rem !important;
            }
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
            .rackup-section:last-child {
              border-bottom: none;
            }
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
            .rackup-grid ul li {
              margin-bottom: 0.2rem;
            }
            .rackup-grid ul li code {
              font-size: 0.95rem;
            }

            /* Two-column layout */
            .rackup-two-col {
              display: grid;
              gap: 2rem;
              grid-template-columns: 1fr 1fr;
              margin-top: 1rem;
            }
            @"@"media (max-width: 700px) {
              .rackup-two-col {
                grid-template-columns: 1fr;
              }
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
            .rackup-two-col ul li {
              margin-bottom: 0.3rem;
            }

            /* Persona quick-start cards */
            .rackup-personas {
              display: grid;
              gap: 1.5rem;
              grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
              margin-top: 1rem;
            }
            .rackup-persona {
              background: #fafafa;
              border: 1px solid #e0e0e0;
              border-radius: 8px;
              padding: 1.2rem 1.2rem 0.8rem;
            }
            .rackup-persona h3 {
              color: #0679a7;
              font-size: 1.05rem;
              font-weight: 600;
              margin: 0 0 0.3rem;
            }
            .rackup-persona > p {
              color: #555;
              font-size: 0.95rem;
              margin: 0 0 0.8rem;
            }

            /* Command reference */
            .rackup-cmd-table {
              border: none !important;
              border-collapse: collapse;
              font-size: 0.95rem;
              margin-top: 0.5rem;
              width: 100%;
            }
            .rackup-cmd-table tr {
              border: none !important;
            }
            .rackup-cmd-table td {
              border: none !important;
              padding: 0.4rem 0.8rem 0.4rem 0;
              vertical-align: top;
            }
            .rackup-cmd-table td:first-child {
              white-space: nowrap;
            }
            .rackup-cmd-table td:last-child {
              color: #555;
            }
          }}))

(define (shell-block id text)
  @pre[class: "rackup-shell"]{@code[id: id]{@text}})

(void
 (page
  #:site rackup-site
  #:file "index.html"
  #:title "rackup"
  #:window-title "rackup"
  #:description "rackup is a toolchain manager for Racket."
  @list{
    @div[class: "rackup-page"]{

      @div[class: "rackup-top"]{
        @h1{@code{rackup}}
        @p[class: "rackup-top-desc"]{
          A toolchain manager for Racket. Install and switch between stable releases,
          pre-releases, snapshots, old PLT Scheme builds, and local source trees.
        }
        @div[class: "rackup-install-row"]{
          @(shell-block "install-cmd" "curl -fsSL https://samth.github.io/rackup/install.sh | sh")
          @a[class: "rackup-copy-btn" href: "#" id: "copy-install-cmd"]{
            @literal{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>}}
        }
        @p[class: "rackup-note"]{
          This installs @code{rackup} itself. Then run @code{rackup install stable}
          to install Racket.
          Pass @code{-y} for non-interactive mode:
        }
        @div[class: "rackup-install-row"]{
          @(shell-block "noninteractive-cmd" "curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y")
          @a[class: "rackup-copy-btn" href: "#" id: "copy-noninteractive-cmd"]{
            @literal{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>}}
        }
        @p[class: "rackup-note"]{
          Or, to verify the install script's checksum before running it:
        }
        @div[class: "rackup-install-row"]{
          @(shell-block "paranoid-cmd" @string-append{curl -fsSL -o install.sh https://samth.github.io/rackup/install.sh
echo "@|install-sh-sha256|  install.sh" | sha256sum -c -
sh install.sh && rm install.sh})
          @a[class: "rackup-copy-btn" href: "#" id: "copy-paranoid-cmd"]{
            @literal{<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>}}
        }
      }

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
            @p{From @a[href: "https://pre-release.racket-lang.org"]{pre-release} and @a[href: "https://snapshot.racket-lang.org"]{snapshot} builds.}
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
          @div{@(shell-block "workflow-cmd" "$ rackup install stable\n$ rackup install pre-release\n$ rackup default stable\n$ racket -e '(displayln (version))'\n$ raco pkg install gregor")}}}

      @div[class: "rackup-section"]{
        @h2{Quick start by use case}
        @p{
          Pick the guide that matches your situation.
        }
        @div[class: "rackup-personas"]{
          @div[class: "rackup-persona"]{
            @h3{New to Racket}
            @p{Get up and running from scratch.}
            @(shell-block "persona-new" "curl -fsSL https://samth.github.io/rackup/install.sh | sh\nrackup install stable\nrackup init --shell bash   # or zsh\nracket")
          }
          @div[class: "rackup-persona"]{
            @h3{Existing Racket user}
            @p{Manage multiple Racket versions side by side.}
            @(shell-block "persona-existing" "curl -fsSL https://samth.github.io/rackup/install.sh | sh\nrackup install 8.18\nrackup install stable\nrackup default stable\nrackup switch 8.18          # switch in current shell")
          }
          @div[class: "rackup-persona"]{
            @h3{Racket developer (source builds)}
            @p{Link your local source tree alongside release builds.}
            @(shell-block "persona-dev" "curl -fsSL https://samth.github.io/rackup/install.sh | sh\nrackup link dev ~/src/racket\nrackup install stable\nrackup default dev\nrackup switch stable         # try a release build\nrackup switch dev            # back to your source tree")
          }
          @div[class: "rackup-persona"]{
            @h3{Package developer}
            @p{Test your package across multiple Racket versions.}
            @(shell-block "persona-pkg" "rackup install stable\nrackup install pre-release\nrackup install 8.15\nrackup run stable -- raco test .\nrackup run pre-release -- raco test .\nrackup run 8.15 -- raco test .")
          }
          @div[class: "rackup-persona"]{
            @h3{CI / Docker / automation}
            @p{Non-interactive setup for scripts and containers.}
            @(shell-block "persona-ci" "curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y\nrackup install stable --quiet\nrackup run stable -- raco test .")}}}

      @div[class: "rackup-section"]{
        @h2{Commands}
        @table[class: "rackup-cmd-table"]{
          @tr{@td{@code{rackup install @i{name}}} @td{Install a toolchain}}
          @tr{@td{@code{rackup list}} @td{List installed toolchains}}
          @tr{@td{@code{rackup available}} @td{List installable toolchains}}
          @tr{@td{@code{rackup default @i{name}}} @td{Set the global default toolchain}}
          @tr{@td{@code{rackup current}} @td{Show the active toolchain and its source}}
          @tr{@td{@code{rackup switch @i{name}}} @td{Switch the active toolchain in this shell}}
          @tr{@td{@code{rackup run @i{name} -- @i{cmd}}} @td{Run a command using a specific toolchain}}
          @tr{@td{@code{rackup which @i{cmd}}} @td{Show path for a shimmed command}}
          @tr{@td{@code{rackup link @i{name} @i{path}}} @td{Link a local source tree}}
          @tr{@td{@code{rackup rebuild}} @td{Rebuild a linked source toolchain in place}}
          @tr{@td{@code{rackup upgrade}} @td{Upgrade channel-based toolchains to latest version}}
          @tr{@td{@code{rackup remove @i{name}}} @td{Remove an installed toolchain}}
          @tr{@td{@code{rackup prompt}} @td{Print toolchain info for shell prompt}}
          @tr{@td{@code{rackup reshim}} @td{Rebuild shims from installed toolchains}}
          @tr{@td{@code{rackup doctor}} @td{Print diagnostics}}
          @tr{@td{@code{rackup init --shell @i{sh}}} @td{Set up shell integration}}
          @tr{@td{@code{rackup self-upgrade}} @td{Upgrade rackup itself}}
          @tr{@td{@code{rackup uninstall}} @td{Remove rackup and all managed state}}
          @tr{@td{@code{rackup version}} @td{Print version info}}
        }}

      }

    @script/inline{
      (function () {
        function setupCopy(btnId, sourceId) {
          var btn = document.getElementById(btnId);
          var source = document.getElementById(sourceId);
          if (btn && source && navigator.clipboard) {
            btn.addEventListener("click", function (event) {
              event.preventDefault();
              navigator.clipboard.writeText(source.textContent).then(function () {
                var old = btn.innerHTML;
                btn.innerHTML = "Copied";
                setTimeout(function () {
                  btn.innerHTML = old;
                }, 1200);
              });
            });
          }
        }
        setupCopy("copy-install-cmd", "install-cmd");
        setupCopy("copy-noninteractive-cmd", "noninteractive-cmd");
        setupCopy("copy-paranoid-cmd", "paranoid-cmd");
      }());
    }}))
