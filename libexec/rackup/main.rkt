#lang racket/base

(require racket/list
         racket/match
         racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         "install.rkt"
         "paths.rkt"
         "remote.rkt"
         "runtime.rkt"
         "shell.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide main)

(define (usage-line cmd desc)
  (printf "  ~a~a~a\n"
          cmd
          (make-string (max 2 (- 22 (string-length cmd))) #\space)
          desc))

(define (usage)
  (displayln "rackup - Racket toolchain manager")
  (displayln "")
  (displayln "Commands:")
  (usage-line "available [--all|--limit N]"
              "List remote install specs and recent release versions.")
  (usage-line "install <spec> [flags]"
              "Install a Racket toolchain (release, pre-release, snapshot).")
  (usage-line "link <name> <path> [flags]"
              "Link an in-place/local Racket build as a managed toolchain.")
  (usage-line "list" "List installed toolchains (shows default/active tags).")
  (usage-line "default [<toolchain>|--unset]"
              "Show, set, or clear the global default toolchain.")
  (usage-line "current" "Show the active toolchain and whether it is shell/global.")
  (usage-line "which <exe> [--toolchain <toolchain>]"
              "Show the real executable path for a tool in a toolchain.")
  (usage-line "shell <toolchain> | shell --deactivate"
              "Emit shell code to activate/deactivate a toolchain in this shell.")
  (usage-line "run <toolchain> -- <command> [args...]"
              "Run a command using a specific toolchain without changing defaults.")
  (usage-line "remove <toolchain>"
              "Remove an installed or linked toolchain and its addon dir.")
  (usage-line "reshim" "Rebuild executable shims from installed toolchains.")
  (usage-line "init [--shell bash|zsh]"
              "Install/update shell integration in ~/.bashrc or ~/.zshrc.")
  (usage-line "uninstall [--yes]"
              "Remove rackup, its toolchains/runtime, and shell init blocks (destructive).")
  (usage-line "runtime status|install|upgrade"
              "Manage rackup's hidden internal runtime used to run rackup itself.")
  (usage-line "doctor" "Print diagnostics for paths, runtime, and installed toolchains.")
  (usage-line "help" "Show this help text.")
  (displayln "")
  (displayln "Use `rackup <command>` for the command, and `rackup help` for this summary."))

(define (resolve-toolchain-or-die spec)
  (define id (find-local-toolchain spec))
  (unless id
    (rackup-error "no matching installed toolchain: ~a" spec))
  id)

(define (cmd-list)
  (ensure-index!)
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (define default-id (get-default-toolchain idx))
  (define active-id (resolve-active-toolchain-id))
  (if (null? ids)
      (displayln "No toolchains installed.")
      (for ([id ids])
        (define m (read-toolchain-meta id))
        (define tags
          (filter values
                  (list (and (equal? id default-id) "default") (and (equal? id active-id) "active"))))
        (printf "~a ~a  (~a, ~a, ~a)\n"
                (if (null? tags) " " "*")
                id
                (hash-ref m 'resolved-version "?")
                (hash-ref m 'variant "?")
                (hash-ref m 'distribution "?"))
        (unless (null? tags)
          (printf "    tags: ~a\n" (string-join tags ", "))))))

(define (cmd-default rest)
  (ensure-index!)
  (match rest
    ['()
     (define id (get-default-toolchain))
     (if id
         (displayln id)
         (displayln ""))]
    [(list "--unset")
     (clear-default-toolchain!)
     (displayln "Cleared default toolchain.")]
    [(list spec)
     (define id (resolve-toolchain-or-die spec))
     (set-default-toolchain! id)
     (reshim!)
     (displayln (format "Default toolchain: ~a" id))]
    [_ (rackup-error "usage: rackup default [<toolchain>|--unset]")]))

(define (cmd-current)
  (ensure-index!)
  (define id (resolve-active-toolchain-id))
  (define src (current-toolchain-source))
  (cond
    [id (printf "~a\t(~a)\n" id src)]
    [else (displayln "none")]))

(define (parse-which-args rest)
  (define toolchain #f)
  (define exe #f)
  (let loop ([xs rest])
    (match xs
      ['() (values exe toolchain)]
      [(list "--toolchain" id more ...)
       (set! toolchain (resolve-toolchain-or-die id))
       (loop more)]
      [(list x more ...)
       (if exe
           (rackup-error "usage: rackup which <exe> [--toolchain <toolchain>]")
           (begin
             (set! exe x)
             (loop more)))])))

(define (cmd-which rest)
  (ensure-index!)
  (define-values (exe tc) (parse-which-args rest))
  (unless exe
    (rackup-error "usage: rackup which <exe> [--toolchain <toolchain>]"))
  (define p (resolve-executable-path exe tc))
  (if p
      (displayln (path->string p))
      (begin
        (eprintf "rackup: executable not found: ~a\n" exe)
        (exit 1))))

(define (cmd-shell rest)
  (ensure-index!)
  (match rest
    [(list "--deactivate") (display (emit-shell-deactivation))]
    [(list spec)
     (define id (resolve-toolchain-or-die spec))
     (display (emit-shell-activation id))]
    [_ (rackup-error "usage: rackup shell <toolchain> | rackup shell --deactivate")]))

(define (cmd-init rest)
  (define shell-name #f)
  (match rest
    ['() (void)]
    [(list "--shell" sh) (set! shell-name sh)]
    [_ (rackup-error "usage: rackup init [--shell bash|zsh]")])
  (define rc (init-shell! shell-name))
  (reshim!)
  (printf "Initialized shell integration in ~a\n" (path->string rc)))

(define (split-on-double-dash xs)
  (let loop ([left null]
             [rest xs])
    (cond
      [(null? rest) (values (reverse left) null)]
      [(equal? (car rest) "--") (values (reverse left) (cdr rest))]
      [else (loop (cons (car rest) left) (cdr rest))])))

(define (apply-toolchain-runtime-env! id)
  (for ([kv (in-list (toolchain-env-vars id))])
    (putenv (car kv) (cdr kv)))
  (putenv "PLTADDONDIR" (path->string (rackup-addon-dir id))))

(define (cmd-run rest)
  (ensure-index!)
  (define-values (head tail) (split-on-double-dash rest))
  (match head
    [(list spec)
     (unless (pair? tail)
       (rackup-error "usage: rackup run <toolchain> -- <command> [args...]"))
     (define id (resolve-toolchain-or-die spec))
     (putenv "RACKUP_TOOLCHAIN" id)
     (apply-toolchain-runtime-env! id)
     (define old-path (or (getenv "PATH") ""))
     (define shims (path->string (rackup-shims-dir)))
     (unless (regexp-match? (pregexp (format "(^|:)~a(:|$)" (regexp-quote shims))) old-path)
       (putenv "PATH" (string-append shims ":" old-path)))
     (define cmd (car tail))
     (define args (cdr tail))
     (define exe (or (find-executable-path cmd) cmd))
     (exit (if (apply system* exe args) 0 1))]
    [_ (rackup-error "usage: rackup run <toolchain> -- <command> [args...]")]))

(define (cmd-remove rest)
  (match rest
    [(list spec) (remove-toolchain! (resolve-toolchain-or-die spec))]
    [_ (rackup-error "usage: rackup remove <toolchain>")]))

(define (cmd-reshim)
  (ensure-index!)
  (reshim!)
  (displayln "Reshim complete."))

(define (cmd-install rest)
  (match rest
    [(list spec more ...)
     (define id (install-toolchain! spec more))
     (displayln id)]
    [_ (rackup-error "usage: rackup install <spec> [flags]")]))

(define (parse-available-options rest)
  (define limit 20)
  (let loop ([xs rest])
    (match xs
      ['() limit]
      [(list "--all") #f]
      [(list "--limit" n more ...)
       (define k (string->number n))
       (unless (and (exact-integer? k) (positive? k))
         (rackup-error "invalid --limit value: ~a (expected positive integer)" n))
       (set! limit k)
       (loop more)]
      [(list flag _ ...) (rackup-error "usage: rackup available [--all|--limit N] (unknown flag ~a)"
                                       flag)])))

(define (fmt-req-summary req)
  (define kind (hash-ref req 'kind #f))
  (define version (hash-ref req 'resolved-version "?"))
  (define variant (hash-ref req 'variant "?"))
  (define dist (hash-ref req 'distribution "?"))
  (define arch (hash-ref req 'arch "?"))
  (define snap-site (hash-ref req 'snapshot-site #f))
  (define snap-stamp (hash-ref req 'snapshot-stamp #f))
  (if (eq? kind 'snapshot)
      (format "~a (~a, stamp ~a, ~a, ~a, ~a)"
              version
              (or snap-site "?")
              (or snap-stamp "?")
              variant
              dist
              arch)
      (format "~a (~a, ~a, ~a)" version variant dist arch)))

(define (display-available-alias label spec)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "  ~a -> unavailable (~a)\n" label (exn-message e)))])
    (define req (resolve-install-request spec))
    (printf "  ~a -> ~a\n" label (fmt-req-summary req))))

(define (cmd-available rest)
  (define limit (parse-available-options rest))
  (displayln "Install aliases:")
  (display-available-alias "stable" "stable")
  (display-available-alias "pre-release" "pre-release")
  (display-available-alias "snapshot" "snapshot")
  (display-available-alias "snapshot:utah" "snapshot:utah")
  (display-available-alias "snapshot:northwestern" "snapshot:northwestern")
  (newline)
  (define versions
    (with-handlers ([exn:fail? (lambda (e)
                                 (rackup-error "failed to fetch release list: ~a" (exn-message e)))])
      (fetch-all-release-versions)))
  (define shown (if (and limit (> (length versions) limit)) (take versions limit) versions))
  (printf "Release versions (~a):\n"
          (if limit
              (format "showing ~a of ~a" (length shown) (length versions))
              (format "all ~a" (length shown))))
  (for ([v shown])
    (printf "  ~a\n" v))
  (newline)
  (displayln "Examples:")
  (displayln "  rackup install stable")
  (displayln "  rackup install 8.18")
  (displayln "  rackup install pre-release")
  (displayln "  rackup install snapshot")
  (newline)
  (displayln "Note: specific variant/distribution/arch compatibility is checked at install time."))

(define (cmd-link rest)
  (match rest
    [(list name path more ...)
     (define id (link-toolchain! name path more))
     (displayln id)]
    [_ (rackup-error "usage: rackup link <name> <path> [--set-default] [--force]")]))

(define (parse-uninstall-options rest)
  (define yes? #f)
  (let loop ([xs rest])
    (match xs
      ['() yes?]
      [(list (or "-y" "--yes") more ...)
       (set! yes? #t)
       (loop more)]
      [(list flag _ ...) (rackup-error "usage: rackup uninstall [--yes] (unknown flag ~a)" flag)])))

(define (installed-toolchain-metas/safe)
  (with-handlers ([exn:fail? (lambda (_) null)])
    (for/list ([id (in-list (installed-toolchain-ids))])
      (define m (read-toolchain-meta id))
      (and (hash? m) m))))

(define (linked-source-paths/safe)
  (remove-duplicates
   (filter values
           (for/list ([m (in-list (installed-toolchain-metas/safe))])
             (and (hash? m)
                  (equal? (hash-ref m 'kind #f) 'local)
                  (hash-ref m 'source-path #f))))
   string=?))

(define (warn-uninstall-summary home-path)
  (define home-str (path->string home-path))
  (define ids (with-handlers ([exn:fail? (lambda (_) null)]) (installed-toolchain-ids)))
  (define linked-paths (linked-source-paths/safe))
  (eprintf "WARNING: `rackup uninstall` is destructive.\n")
  (eprintf "WARNING: This will permanently delete all rackup-managed data under:\n")
  (eprintf "  ~a\n" home-str)
  (eprintf "WARNING: This includes:\n")
  (eprintf "  - hidden runtime used to run rackup\n")
  (eprintf "  - installed toolchains and linked-toolchain metadata/overlays\n")
  (eprintf "  - shims, caches, downloaded installers, and per-toolchain addon dirs/packages\n")
  (eprintf "WARNING: This will also remove rackup-managed shell init blocks from ~~/.bashrc and ~~/.zshrc if present.\n")
  (eprintf "WARNING: This cannot be undone.\n")
  (eprintf "Detected installed toolchains: ~a\n" (length ids))
  (when (pair? ids)
    (for ([id (in-list ids)])
      (eprintf "  - ~a\n" id)))
  (when (pair? linked-paths)
    (eprintf "WARNING: Linked local source trees will NOT be deleted (only rackup's links to them).\n")
    (for ([p (in-list linked-paths)])
      (eprintf "  - external source tree: ~a\n" p))))

(define (confirm-uninstall! home-path yes?)
  (unless yes?
    (unless (terminal-port? (current-input-port))
      (rackup-error "refusing to uninstall without interactive confirmation (rerun with --yes)"))
    (displayln "")
    (printf "Type DELETE to uninstall rackup and remove ~a: " (path->string home-path))
    (flush-output)
    (define answer (read-line))
    (unless (and (string? answer) (equal? (string-trim answer) "DELETE"))
      (rackup-error "uninstall aborted"))))

(define (cmd-uninstall rest)
  (define yes? (parse-uninstall-options rest))
  (define home-path (rackup-home))
  (warn-uninstall-summary home-path)
  (confirm-uninstall! home-path yes?)
  (define removed-rcs
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "rackup: warning: failed to clean shell init blocks: ~a\n"
                                          (exn-message e))
                                 null)])
      (remove-shell-init-blocks!)))
  (when (directory-exists? home-path)
    (define sh (or (find-executable-path "sh") (string->path "/bin/sh")))
    ;; Delete after this process exits, since we're running code from this directory.
    (define cleanup-cmd
      (format "sleep 1; rm -rf ~a >/dev/null 2>&1" (sh-single-quote (path->string home-path))))
    (with-handlers ([exn:fail? (lambda (_e) (void))])
      (void (system* sh "-c" (string-append cleanup-cmd " &")))))
  (displayln "rackup uninstalled.")
  (when (pair? removed-rcs)
    (displayln "Removed rackup shell init blocks from:")
    (for ([p (in-list removed-rcs)])
      (printf "  ~a\n" (path->string p))))
  (displayln "Final file deletion may complete shortly after this command exits.")
  (displayln "Your current shell may still have rackup-related PATH/env changes until you start a new shell."))

(define (cmd-doctor)
  (doctor-report))

(define (main)
  (with-handlers ([exn:fail:user? (lambda (e)
                                    (eprintf "~a\n" (exn-message e))
                                    (exit 2))]
                  [exn:fail? (lambda (e)
                               (eprintf "rackup: internal error: ~a\n" (exn-message e))
                               (exit 1))])
    (define args (vector->list (current-command-line-arguments)))
    (match args
      ['() (usage)]
      [(or (list "help" _ ...) (list "--help") (list "-h")) (usage)]
      [(list "available" rest ...) (cmd-available rest)]
      [(list "install" rest ...) (cmd-install rest)]
      [(list "link" rest ...) (cmd-link rest)]
      [(list "list") (cmd-list)]
      [(list "default" rest ...) (cmd-default rest)]
      [(list "current") (cmd-current)]
      [(list "which" rest ...) (cmd-which rest)]
      [(list "shell" rest ...) (cmd-shell rest)]
      [(list "run" rest ...) (cmd-run rest)]
      [(list "remove" rest ...) (cmd-remove rest)]
      [(list "reshim") (cmd-reshim)]
      [(list "init" rest ...) (cmd-init rest)]
      [(list "uninstall" rest ...) (cmd-uninstall rest)]
      [(list "runtime" rest ...) (cmd-runtime rest)]
      [(list "doctor") (cmd-doctor)]
      [_
       (usage)
       (exit 2)])))
