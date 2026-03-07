#lang at-exp racket/base

(require plt-web
         plt-web/style
         racket/file
         racket/runtime-path
         file/sha1)

(provide generate-site)

(define-runtime-path css-file "rackup.css")
(define-runtime-path js-file "rackup.js")

(define (shell-block id text)
  @pre[class: "rackup-shell"]{@code[id: id]{@text}})

(define (generate-site install-sh-path)
  (define install-sh-sha256
    (if install-sh-path
        (bytes->hex-string
         (call-with-input-file install-sh-path sha256-bytes))
        "UNKNOWN"))

  (define css-resource
    (resource "www/rackup.css" (lambda (dest) (copy-file css-file dest))))
  (define js-resource
    (resource "www/rackup.js" (lambda (dest) (copy-file js-file dest))))

  (define rackup-site
    (site "www"
          #:navigation
          (list @a[href: "./install.sh"]{install.sh}
                @a[href: "https://github.com/samth/rackup"]{GitHub}
                @a[href: "https://github.com/samth/rackup/blob/main/README.md"]{README})
          #:page-headers
          @list{
            @link[rel: "stylesheet" type: "text/css" href: css-resource]}))

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
          @(shell-block "noninteractive-cmd" "curl -fsSL https://samth.github.io/rackup/install.sh | sh -s -- -y")
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

      @script[src: js-resource]}))

  (render-all))

(module+ main
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
  (generate-site install-sh-path))
