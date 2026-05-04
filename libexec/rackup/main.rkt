#lang racket/base

(require racket/cmdline
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         (for-syntax racket/base
                     racket/file
                     racket/string
                     racket/syntax
                     "commands-data.rkt")
         "commands-data.rkt"
         "install.rkt"
         "legacy-plt-catalog.rkt"
         "paths.rkt"
         "rebuild.rkt"
         "remote.rkt"
         "rktd-io.rkt"
         "runtime.rkt"
         "shell.rkt"
         "shims.rkt"
         "state.rkt"
         "state-lock.rkt"
         "util.rkt"
         "versioning.rkt")

(provide main
         cmd-version
         cmd-upgrade)

(define-syntax (bake-version stx)
  (define here (let-values ([(dir _n _d) (split-path (syntax-source stx))]) dir))
  (define version-file (build-path here ".." ".." "build-version.txt"))
  (with-handlers ([exn:fail? (lambda (_) #'#f)])
    (let ([lines (file->lines version-file)])
      (if (null? lines)
          #'#f
          #`(quote #,(string-trim (car lines)))))))

(define baked-version (bake-version))

(define-runtime-path rackup-repo-anchor "../../.gitignore")

(define (usage-line cmd desc)
  (printf "  ~a~a~a\n" cmd (make-string (max 2 (- 22 (string-length cmd))) #\space) desc))

(define version-help
  (string-append
   "A <version> is a Racket release number (e.g. 8.18), or one of the channels:\n"
   "stable, pre-release, snapshot, snapshot:utah, snapshot:northwestern.\n"
   "Run `rackup available` to see installable versions and channels."))

;; `command-line` requires #:usage-help strings to be literals, not a runtime
;; identifier like `version-help`, so this wrapper inlines them.
(define-syntax-rule (command-line/version-help
                     #:program program-expr
                     #:argv argv-expr
                     clause ...)
  (command-line
   #:program program-expr
   #:argv argv-expr
   #:usage-help
   "A <version> is a Racket release number (e.g. 8.18), or one of the channels:"
   "stable, pre-release, snapshot, snapshot:utah, snapshot:northwestern."
   "Run `rackup available` to see installable versions and channels."
   clause ...))

(define (usage)
  (displayln "rackup - Racket toolchain manager")
  (displayln "")
  (displayln "Commands:")
  (usage-line "available [--all|--limit N]" "List remote install versions and recent release versions.")
  (usage-line "install <version> [flags]" "Install a Racket toolchain (release, pre-release, snapshot).")
  (usage-line "link <name> <path> [flags]"
              "Link an in-place/local Racket build as a managed toolchain.")
  (usage-line "rebuild [<name>] [flags] [-- <make-args>...]"
              "Rebuild a linked source toolchain in place (runs `make`).")
  (usage-line "list [--ids]" "List installed toolchains (shows default/active tags).")
  (usage-line "default [id|status|set <toolchain>|clear|<toolchain>|--unset]"
              "Show, set, or clear the global default toolchain.")
  (usage-line "current [id|source|line]"
              "Show the active toolchain and where it came from.")
  (usage-line "which <exe> [--toolchain <toolchain>]"
              "Show the real executable path for a tool in a toolchain.")
  (usage-line "switch <toolchain> | switch --unset"
              "Switch the active toolchain in this shell without changing default.")
  (usage-line "shell <toolchain> | shell --deactivate"
              "Low-level: emit shell code to activate/deactivate a toolchain.")
  (usage-line "run <toolchain> -- <command> [args...]"
              "Run a command using a specific toolchain without changing defaults.")
  (usage-line "prompt [--long|--short|--raw|--source]"
              "Print fast prompt info for PS1 (default: compact label).")
  (usage-line "upgrade [version] [--force]" "Upgrade channel-based toolchains to latest version.")
  (usage-line "remove <toolchain>" "Remove an installed or linked toolchain and its addon dir.")
  (usage-line "reshim" "Rebuild executable shims from installed toolchains.")
  (usage-line "init [--shell bash|zsh]" "Install/update shell integration in ~/.bashrc or ~/.zshrc.")
  (usage-line "uninstall [--dangerously-delete-without-prompting]"
              "Remove rackup, its toolchains/runtime, and shell init blocks (destructive).")
  (usage-line "self-upgrade [--with-init] [--exe | --source] [--ref <ref>] [--repo <owner/repo>]"
              "Upgrade rackup's code by rerunning the installer into the current RACKUP_HOME.")
  (usage-line "runtime status|install|upgrade"
              "Manage rackup's hidden internal runtime used to run rackup itself.")
  (usage-line "doctor" "Print diagnostics for paths, runtime, and installed toolchains.")
  (usage-line "version" "Print rackup version info (git commit and date).")
  (usage-line "help [command]" "Show global help or help for a specific command.")
  (displayln "")
  (displayln version-help)
  (displayln "")
  (displayln "Use `rackup <command> --help` or `rackup help <command>` for command help."))

;; If spec is a meta-name like "stable", try resolving it to an actual
;; version number and look up locally.  Returns the ID or #f.
(define (try-resolve-meta-spec spec)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define spec* (parse-install-spec spec))
    (match (hash-ref spec* 'kind)
      ['stable
       (define ver (lookup-stable-version))
       (find-local-toolchain ver)]
      [_ #f])))

(define (resolve-toolchain-or-die spec)
  (define id (or (find-local-toolchain spec)
                 (try-resolve-meta-spec spec)))
  (unless id
    (rackup-error "no matching installed toolchain: ~a" spec))
  id)

(define (toolchain-dir-ids/safe)
  (with-handlers ([exn:fail? (lambda (_) null)])
    (if (directory-exists? (rackup-toolchains-dir))
        (sort (for/list ([p (in-list (directory-list (rackup-toolchains-dir) #:build? #t))]
                         #:when (or (directory-exists? p) (link-exists? p)))
                (path-basename-string p))
              string<?)
        null)))

(define (find-orphan-toolchain-id spec)
  (define idx (load-index))
  (define registered (installed-toolchain-ids idx))
  (define orphan-ids (filter (lambda (id) (not (member id registered))) (toolchain-dir-ids/safe)))
  (define (unique xs)
    (and (= (length xs) 1) (car xs)))
  (define (ambiguous xs)
    (and (> (length xs) 1)
         (rackup-error "multiple orphan/partial toolchain directories match '~a': ~a"
                       spec
                       (string-join xs ", "))))
  (or (and (member spec orphan-ids) spec)
      (let ([xs (filter (lambda (id) (string-prefix? id spec)) orphan-ids)])
        (or (unique xs) (ambiguous xs)))
      (let* ([quoted (regexp-quote spec)]
             [rx (pregexp (format "(^|-)~a([.-]|-|$)" quoted))]
             [xs (filter (lambda (id) (regexp-match? rx id)) orphan-ids)])
        (or (unique xs) (ambiguous xs)))
      #f))

(define (remove-orphan-toolchain! id)
  (define tc-dir (rackup-toolchain-dir id))
  (define addon (rackup-addon-dir id))
  (unless (or (link-exists? tc-dir) (directory-exists? tc-dir))
    (rackup-error "orphan toolchain directory not found: ~a" id))
  (delete-toolchain-dir! tc-dir)
  (when (directory-exists? addon)
    (delete-directory/files addon))
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (with-state-lock (reshim!)))
  (displayln (format "Removed orphan/partial toolchain directory ~a" id)))

(define (yes?/default-yes s)
  (define a
    (if (string? s)
        (string-downcase (string-trim s))
        "__no__"))
  (or (string=? a "") (member a '("y" "yes"))))

(define (call-with-user-tty proc)
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (and (terminal-port? (current-input-port))
                          (terminal-port? (current-error-port))
                          (proc (current-input-port) (current-error-port))))])
    (define tty-in (open-input-file "/dev/tty"))
    (define tty-out (open-output-file "/dev/tty" #:exists 'append))
    (dynamic-wind void
                  (lambda () (proc tty-in tty-out))
                  (lambda ()
                    (close-input-port tty-in)
                    (close-output-port tty-out)))))

(define (resolve-toolchain-or-offer-install spec)
  (define id (or (find-local-toolchain spec)
                 (try-resolve-meta-spec spec)))
  (cond
    [id id]
    [(not (call-with-user-tty (lambda (_in _out) #t)))
     (rackup-error "no matching installed toolchain: ~a\nHint: run `rackup install ~a` first"
                   spec
                   spec)]
    [else
     (define answer
       (call-with-user-tty
        (lambda (in out)
          (fprintf out "Toolchain '~a' is not installed. Install it now? [Y/n] " spec)
          (flush-output out)
          (read-line in))))
     (unless (yes?/default-yes answer)
       (rackup-error "toolchain not installed: ~a" spec))
     (install-toolchain! spec '())]))

(define (cmd-list rest)
  (define ids-only? #f)
  (command-line #:program "rackup list"
                #:argv rest
                #:once-each
                [("--ids") "Print only toolchain IDs" (set! ids-only? #t)]
                #:args ()
                (void))
  (ensure-index!)
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (when ids-only?
    (for ([id ids]) (displayln id))
    (exit 0))
  (define default-id (get-default-toolchain idx))
  (define active-id (resolve-active-toolchain-id))
  (define env-id (getenv "RACKUP_TOOLCHAIN"))
  (define stale-env?
    (and env-id
         (not (string-blank? env-id))
         (not (member env-id ids))))
  (when stale-env?
    (displayln (ansi "33" (format "Warning: RACKUP_TOOLCHAIN selects '~a', but that toolchain is not installed." env-id)))
    (when (and default-id (member default-id ids))
      (displayln (ansi "33" (format "It overrides the default toolchain '~a'." default-id))))
    (displayln "Clear it with: rackup switch --unset")
    (displayln "Or unset it manually with: unset RACKUP_TOOLCHAIN")
    (newline))
  (if (null? ids)
      (displayln "No toolchains installed.")
      (let ([all-meta (for/list ([id ids])
                        (cons id (read-toolchain-meta id)))])
        (for ([id ids])
          (define m (cdr (assoc id all-meta)))
          (define is-default? (equal? id default-id))
          (define is-active? (equal? id active-id))
          (define is-stable? (equal? (hash-ref m 'requested-spec #f) "stable"))
          (define tags
            (filter values
                    (list (and is-default? "default")
                          (and is-active? "active")
                          (and is-stable? "stable"))))
          (define tag-str
            (if (null? tags)
                ""
                (string-append
                 (ansi (cond [is-active? "32"] [is-stable? "35"] [else "36"])
                       (format "[~a]" (string-join tags ",")))
                 " ")))
          (define meta-str
            (format " (~a, ~a, ~a)"
                    (hash-ref m 'resolved-version "?")
                    (hash-ref m 'variant "?")
                    (hash-ref m 'distribution "?")))
          (define names (toolchain-short-names id idx #:all-meta all-meta))
          (define names-str
            (if (null? names)
                ""
                (format "\n  aka ~a" (string-join (sort names string<?) ", "))))
          (printf "~a~a ~a~a\n" tag-str id meta-str names-str)))))

(define (default-id->line)
  (define id (get-default-toolchain))
  (if id
      (displayln id)
      (displayln "")))

(define (set-default-from-spec! spec)
  (define id (resolve-toolchain-or-offer-install spec))
  (commit-state-change!
   (set-default-toolchain! id))
  (displayln (format "Default toolchain: ~a" id)))

(define (cmd-default rest)
  (ensure-index!)
  (define unset? #f)
  (define args
    (command-line #:program "rackup default"
                  #:argv rest
                  #:once-each
                  [("--unset") "Clear the default toolchain" (set! unset? #t)]
                  #:args args
                  args))
  (cond
    [unset?
     (commit-state-change! (clear-default-toolchain!))
     (displayln "Cleared default toolchain.")]
    [else
     (match args
       ['() (default-id->line)]
       [(list "id") (default-id->line)]
       [(list "status")
        (define id (get-default-toolchain))
        (if id
            (printf "set\t~a\n" id)
            (displayln "unset"))]
       [(list "set" spec)
        (set-default-from-spec! spec)]
       [(list "clear")
        (commit-state-change! (clear-default-toolchain!))
        (displayln "Cleared default toolchain.")]
       [(list spec)
        (set-default-from-spec! spec)]
       [_ (rackup-error
           "usage: rackup default [id|status|set <toolchain>|clear|<toolchain>|--unset]")])]))

(define (source->line src)
  (if src
      (symbol->string src)
      "none"))

(define (cmd-current rest)
  (ensure-index!)
  (define args
    (command-line #:program "rackup current"
                  #:argv rest
                  #:args args
                  args))
  (define id (resolve-active-toolchain-id))
  (define src (current-toolchain-source))
  (match args
    ['()
     (cond
       [id (printf "~a\t(~a)\n" id src)]
       [else (displayln "none")])]
    [(list "id")
     (if id
         (displayln id)
         (displayln ""))]
    [(list "source")
     (displayln (source->line src))]
    [(list "line")
     (if id
         (printf "~a\t~a\n" id (source->line src))
         (displayln "none\tnone"))]
    [_ (rackup-error "usage: rackup current [id|source|line]")]))

(define (cmd-which rest)
  (ensure-index!)
  (define toolchain #f)
  (define exe
    (command-line #:program "rackup which"
                  #:argv (reorder-args rest '("--toolchain"))
                  #:once-each
                  [("--toolchain") id "Use specific toolchain"
                   (set! toolchain (resolve-toolchain-or-die id))]
                  #:args (exe)
                  exe))
  (define tc toolchain)
  (define p (resolve-executable-path exe tc))
  (if p
      (displayln (path->string p))
      (begin
        (eprintf "rackup: executable not found: ~a\n" exe)
        (exit 1))))

(define (warn-no-shell-integration! cmd-name)
  (when (terminal-port? (current-output-port))
    (eprintf "rackup: shell integration is not set up.\n")
    (eprintf "Run `rackup init` first, then restart your shell.\n")
    (eprintf "After that, `rackup ~a` will work correctly.\n" cmd-name)
    (exit 1)))

(define (cmd-shell rest)
  (ensure-index!)
  (define deactivate? #f)
  (define args
    (command-line #:program "rackup shell"
                  #:argv rest
                  #:once-each
                  [("--deactivate") "Deactivate shell toolchain" (set! deactivate? #t)]
                  #:args args
                  args))
  (warn-no-shell-integration! "shell")
  (cond
    [deactivate? (display (emit-shell-deactivation))]
    [(= (length args) 1)
     (define id (resolve-toolchain-or-die (first args)))
     (display (emit-shell-activation id))]
    [else (rackup-error "usage: rackup shell <toolchain> | rackup shell --deactivate")]))

(define (cmd-switch rest)
  (ensure-index!)
  (define unset? #f)
  (define args
    (command-line #:program "rackup switch"
                  #:argv rest
                  #:once-each
                  [("--unset") "Deactivate shell toolchain" (set! unset? #t)]
                  #:args args
                  args))
  (warn-no-shell-integration! "switch")
  (cond
    [unset? (display (emit-shell-deactivation))]
    [(= (length args) 1)
     (define id (resolve-toolchain-or-offer-install (first args)))
     (display (emit-shell-activation id))]
    [else (rackup-error "usage: rackup switch <toolchain> | rackup switch --unset")]))

(define (cmd-init rest)
  (define shell-name #f)
  (command-line #:program "rackup init"
                #:argv rest
                #:once-each
                [("--shell") sh "Shell type (bash or zsh)" (set! shell-name sh)]
                #:args ()
                (void))
  (define rc (init-shell! shell-name))
  (with-state-lock (reshim!))
  (printf "Initialized shell integration in ~a\n" (path->string rc)))

(define (split-on-double-dash xs)
  (let loop ([left null]
             [rest xs])
    (cond
      [(null? rest) (values (reverse left) null)]
      [(equal? (car rest) "--") (values (reverse left) (cdr rest))]
      [else (loop (cons (car rest) left) (cdr rest))])))

(define (toolchain-runtime-env-vars id)
  (append (toolchain-env-vars id)
          (list (cons "PLTADDONDIR" (path->string (rackup-addon-dir id))))))

(define (cmd-run rest)
  (ensure-index!)
  (define all-args
    (command-line #:program "rackup run"
                  #:argv rest
                  #:args args
                  args))
  (define-values (head tail) (split-on-double-dash all-args))
  (match head
    [(list spec)
     (unless (pair? tail)
       (rackup-error "usage: rackup run <toolchain> -- <command> [args...]"))
     (define id (resolve-toolchain-or-die spec))
     (define env (environment-variables-copy (current-environment-variables)))
     (restore-saved-racket-env-vars! env)
     (environment-variables-set! env #"RACKUP_TOOLCHAIN" (string->bytes/utf-8 id))
     (for ([kv (in-list (toolchain-runtime-env-vars id))])
       (define key (string->bytes/utf-8 (car kv)))
       ;; For PLTCOMPILEDROOTS, respect a user-set value restored above.
       (unless (and (equal? (car kv) "PLTCOMPILEDROOTS")
                    (environment-variables-ref env key))
         (environment-variables-set! env
                                     key
                                     (string->bytes/utf-8 (cdr kv)))))
     (define old-path (or (getenv "PATH") ""))
     (define shims (path->string (rackup-shims-dir)))
     (define runtime-path
       (if (regexp-match? (pregexp (format "(^|:)~a(:|$)" (regexp-quote shims))) old-path)
           old-path
           (string-append shims ":" old-path)))
     (environment-variables-set! env #"PATH" (string->bytes/utf-8 runtime-path))
     (define cmd (car tail))
     (define cmd-args (cdr tail))
     (define exe
       (or (resolve-executable-path cmd id)
           (resolve-command-path cmd runtime-path)
           cmd))
     (exit
      (parameterize ([current-environment-variables env])
        (if (apply system* exe cmd-args) 0 1)))]
    [_ (rackup-error "usage: rackup run <toolchain> -- <command> [args...]")]))

(define (cmd-upgrade rest)
  (ensure-index!)
  (define force? #f)
  (define no-cache? #f)
  (define version-arg
    (command-line/version-help
                  #:program "rackup upgrade"
                  #:argv (reorder-args rest)
                  #:usage-help
                  "Only channel-based toolchains can be upgraded; omit <version> to upgrade all."
                  #:once-each
                  [("--force") "Reinstall even if already up to date" (set! force? #t)]
                  [("--no-cache") "Re-download installer instead of using cache" (set! no-cache? #t)]
                  #:args version
                  (match version
                    ['() #f]
                    [(list s) s]
                    [_ (rackup-error "usage: rackup upgrade [version] [--force] [--no-cache]")])))
  (define targets (upgradeable-toolchains version-arg))
  (when (null? targets)
    (if version-arg
        (rackup-error "no upgradeable toolchain matching '~a' found.\nOnly channel-based toolchains (stable, pre-release, snapshot) can be upgraded."
                      version-arg)
        (rackup-error "no upgradeable toolchains installed.\nInstall a channel-based toolchain first, e.g.: rackup install stable")))
  (define upgraded 0)
  (for ([pair (in-list targets)])
    (define id (car pair))
    (define meta (cdr pair))
    (define new-id
      (with-handlers ([exn:fail? (lambda (e)
                                   (eprintf "rackup: failed to upgrade ~a: ~a\n"
                                            id (exn-message e))
                                   #f)])
        (upgrade-toolchain! id meta
                            #:force? force?
                            #:no-cache? no-cache?)))
    (when new-id
      (set! upgraded (add1 upgraded))))
  (when (> (length targets) 1)
    (printf "\nUpgraded ~a of ~a toolchain~a.\n"
            upgraded
            (length targets)
            (if (= (length targets) 1) "" "s"))))

(define (cmd-remove rest)
  (define clean-compiled? #f)
  (define toolchain
    (command-line #:program "rackup remove"
                  #:argv rest
                  #:usage-help
                  "<toolchain> is an installed toolchain id or a prefix; run `rackup list`"
                  "to see installed toolchains."
                  #:once-each
                  [("--clean-compiled")
                   ("Remove version-specific compiled/<key>/ directories"
                    "from user-scope and linked package source directories")
                   (set! clean-compiled? #t)]
                  #:args (toolchain)
                  toolchain))
  (define installed-id (find-local-toolchain toolchain))
  (cond
    [installed-id (remove-toolchain! installed-id #:clean-compiled? clean-compiled?)]
    [else
     (define orphan-id (find-orphan-toolchain-id toolchain))
     (cond
       [orphan-id
        (when clean-compiled?
          (rackup-error "--clean-compiled cannot be used with orphan toolchains"))
        (remove-orphan-toolchain! orphan-id)]
       [else
        (rackup-error "no matching installed toolchain: ~a" toolchain)])]))

(define (cmd-reshim rest)
  (define aliases? #f)
  (define no-aliases? #f)
  (command-line #:program "rackup reshim"
                #:argv rest
                #:once-any
                [("--short-aliases") "Enable short aliases: r (racket), dr (drracket)"
                 (set! aliases? #t)]
                [("--no-short-aliases") "Remove short aliases"
                 (set! no-aliases? #t)]
                #:args ()
                (void))
  (ensure-index!)
  (commit-state-change!
   (when aliases? (install-shim-aliases!))
   (when no-aliases? (remove-shim-aliases!)))
  ;; Keep installed shell helper scripts in sync with the running rackup
  ;; code so new subcommands and flags become tab-completable without
  ;; requiring the user to rerun `rackup init`.
  (refresh-shell-integration!)
  (displayln "Reshim complete."))

;; Reorder install args so flags precede the positional spec.
;; command-line stops flag processing at the first non-flag arg, so
;; command-line stops flag processing at the first positional arg, so
;; `rackup install stable --set-default` fails.  Reorder to put flags first.
;; flags-with-arg lists flags that consume the next token as their value.
(define (reorder-args rest [flags-with-arg '()])
  (let loop ([flags '()] [positionals '()] [xs rest])
    (cond
      [(null? xs) (append (reverse flags) (reverse positionals))]
      [(string-prefix? (car xs) "-")
       (if (and (member (car xs) flags-with-arg) (pair? (cdr xs)))
           (loop (list* (cadr xs) (car xs) flags) positionals (cddr xs))
           (loop (cons (car xs) flags) positionals (cdr xs)))]
      [else (loop flags (cons (car xs) positionals) (cdr xs))])))

(define (cmd-install rest)
  (define short-aliases? #f)
  (define opts-rev '())
  (define (flag! . args) (set! opts-rev (append (reverse args) opts-rev)))
  (define version
    (command-line/version-help
                  #:program "rackup install"
                  #:argv (reorder-args rest
                                       '("--variant" "--distribution" "--snapshot-site"
                                         "--arch" "--installer-ext" "--prefix"))
                  #:once-each
                  [("--variant") v "cs|bc - Override VM variant" (flag! "--variant" v)]
                  [("--distribution") d "full|minimal - Distribution type" (flag! "--distribution" d)]
                  [("--snapshot-site") s "auto|utah|northwestern - Snapshot mirror"
                   (flag! "--snapshot-site" s)]
                  [("--arch") a "Override target architecture" (flag! "--arch" a)]
                  [("--set-default") "Set installed toolchain as default" (flag! "--set-default")]
                  [("--force") "Reinstall existing toolchain" (flag! "--force")]
                  [("--no-cache") "Redownload installer" (flag! "--no-cache")]
                  [("--installer-ext") e "sh|tgz|dmg - Force installer extension"
                   (flag! "--installer-ext" e)]
                  [("--prefix") p
                   "Install toolchain under <p>/<id>/ via symlink (e.g., /tmp/rackup-tc on fast disk)"
                   (flag! "--prefix" p)]
                  [("--short-aliases") "Install short aliases: r (racket), dr (drracket)"
                   (set! short-aliases? #t)]
                  #:once-any
                  [("--quiet") "Show minimal output" (flag! "--quiet")]
                  [("--verbose") "Show detailed output" (flag! "--verbose")]
                  #:args (version)
                  version))
  (void (install-toolchain! version (reverse opts-rev)))
  (when short-aliases?
    (commit-state-change!
     (install-shim-aliases!))))

(define (prompt-short-label id)
  (define meta (and id (read-toolchain-meta id)))
  (define kind (and (hash? meta) (hash-ref meta 'kind #f)))
  (define version (and (hash? meta) (hash-ref meta 'resolved-version #f)))
  (define spec (and (hash? meta) (hash-ref meta 'requested-spec #f)))
  (match kind
    ['local (or spec
                (and id (string-prefix? id "local-") (substring id 6))
                id
                "local")]
    [_
     (define suffix
       (match kind
         ['release (or version id)]
         ['stable (or version id)]
         ['pre-release (format "pre-~a" (or version id))]
         ['snapshot (format "snapshot-~a" (or version id))]
         [_ (or id "")]))
     (if (string-blank? suffix) "" (format "racket-~a" suffix))]))

(define (cmd-prompt rest)
  (define mode 'short)
  (command-line #:program "rackup prompt"
                #:argv rest
                #:once-any
                [("--long") "Long format: [rk:<id>]" (set! mode 'long)]
                [("--short") "Short format (default)" (set! mode 'short)]
                [("--raw") "Raw toolchain ID" (set! mode 'raw)]
                [("--source") "ID and source" (set! mode 'source)]
                #:args ()
                (void))
  (define id (resolve-active-toolchain-id))
  (define src (current-toolchain-source))
  (when id
    (match mode
      ['long (printf "[rk:~a]\n" id)]
      ['short (displayln (prompt-short-label id))]
      ['raw (displayln id)]
      ['source (printf "~a\t~a\n" id (or src 'unknown))]
      [_ (displayln (prompt-short-label id))])))

(define (parse-available-options rest)
  (define limit 20)
  (command-line #:program "rackup available"
                #:argv rest
                #:once-any
                [("--all") "Show all versions" (set! limit #f)]
                [("--limit") n "Maximum versions to show"
                 (define k (string->number n))
                 (unless (and (exact-integer? k) (positive? k))
                   (rackup-error "invalid --limit value: ~a (expected positive integer)" n))
                 (set! limit k)]
                #:args ()
                (void))
  limit)

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
                               (printf "  ~a -> ~a\n" label (ansi "33" (format "unavailable (~a)" (exn-message e)))))])
    (define req (resolve-install-request spec))
    (printf "  ~a -> ~a\n" (ansi "1" label) (fmt-req-summary req))))

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
  (define shown
    (if (and limit (> (length versions) limit))
        (take versions limit)
        versions))
  (printf "Release versions (~a):\n"
          (if limit
              (format "showing ~a of ~a" (length shown) (length versions))
              (format "all ~a" (length shown))))
  (for ([v shown])
    (printf "  ~a\n" v))
  (when (not limit)
    (newline)
    (printf "PLT Scheme versions (pre-5.0, ~a):\n" (length legacy-plt-version-tokens))
    (for ([v (in-list legacy-plt-version-tokens)])
      (printf "  ~a\n" v)))
  (newline)
  (displayln "Examples:")
  (displayln "  rackup install stable")
  (displayln "  rackup install 8.18")
  (displayln "  rackup install pre-release")
  (displayln "  rackup install snapshot")
  (newline)
  (displayln "Note: specific variant/distribution/arch compatibility is checked at install time."))

(define (cmd-link rest)
  (define set-default? #f)
  (define force? #f)
  (define-values (name path)
    (command-line #:program "rackup link"
                  #:argv (reorder-args rest)
                  #:once-each
                  [("--set-default") "Set as default toolchain" (set! set-default? #t)]
                  [("--force") "Overwrite existing toolchain" (set! force? #t)]
                  #:args (name path)
                  (values name path)))
  (define opts
    (append (if set-default? '("--set-default") '())
            (if force? '("--force") '())))
  (define id (link-toolchain! name path opts))
  (displayln id))

(define (cmd-rebuild rest)
  (define-values (rebuild-args make-args)
    (split-on-double-dash rest))
  (define pull? #f)
  (define dry-run? #f)
  (define update-meta? #t)
  (define jobs #f)
  (define name
    (command-line #:program "rackup rebuild"
                  #:argv (reorder-args rebuild-args '("-j" "--jobs"))
                  #:usage-help
                  "Rebuild a linked source toolchain in place by running `make`."
                  "If <name> is omitted, the active or default toolchain is used."
                  "Anything after `--` is passed verbatim to make, e.g.:"
                  "  rackup rebuild dev -- CPUS=8 PKGS=\"main-distribution\""
                  #:once-each
                  [("--pull") "Run `git pull --ff-only` in the source tree first"
                              (set! pull? #t)]
                  [("-j" "--jobs") n "Parallelism for make (-jN, CPUS=N)"
                                   (let ([v (string->number n)])
                                     (unless (and (exact-integer? v) (positive? v))
                                       (rackup-error "--jobs requires a positive integer: ~a" n))
                                     (set! jobs v))]
                  [("--dry-run") "Print planned commands without executing them"
                                 (set! dry-run? #t)]
                  [("--no-update-meta")
                   "Skip post-build metadata refresh (escape hatch)"
                   (set! update-meta? #f)]
                  #:args ([name #f])
                  name))
  (rebuild-toolchain! name
                      #:pull? pull?
                      #:dry-run? dry-run?
                      #:update-meta? update-meta?
                      #:jobs jobs
                      #:make-args make-args)
  (void))

(define (parse-uninstall-options rest)
  (define yes? #f)
  (command-line #:program "rackup uninstall"
                #:argv rest
                #:once-each
                [("--dangerously-delete-without-prompting") "Skip confirmation prompt" (set! yes? #t)]
                #:args ()
                (void))
  yes?)

(define (installed-toolchain-metas/safe)
  (with-handlers ([exn:fail? (lambda (_) null)])
    (filter hash?
            (for/list ([id (in-list (installed-toolchain-ids))])
              (read-toolchain-meta id)))))

(define (linked-source-paths/safe)
  (remove-duplicates
   (filter values
           (for/list ([m (in-list (installed-toolchain-metas/safe))])
             (and (hash? m) (equal? (hash-ref m 'kind #f) 'local) (hash-ref m 'source-path #f))))
   string=?))

(define (warn-uninstall-summary home-path)
  (define home-str (path->string home-path))
  (define ids
    (with-handlers ([exn:fail? (lambda (_) null)])
      (installed-toolchain-ids)))
  (define linked-paths (linked-source-paths/safe))
  (eprintf "WARNING: `rackup uninstall` is destructive.\n")
  (eprintf "WARNING: This will permanently delete all rackup-managed data under:\n")
  (eprintf "  ~a\n" home-str)
  (eprintf "WARNING: This includes:\n")
  (eprintf "  - hidden runtime used to run rackup\n")
  (eprintf "  - installed toolchains and linked-toolchain metadata/overlays\n")
  (eprintf "  - shims, caches, downloaded installers, and per-toolchain addon dirs/packages\n")
  (eprintf
   "WARNING: This will also remove rackup-managed shell init blocks from ~~/.bashrc and ~~/.zshrc if present.\n")
  (eprintf "WARNING: This cannot be undone.\n")
  (eprintf "Detected installed toolchains: ~a\n" (length ids))
  (when (pair? ids)
    (for ([id (in-list ids)])
      (eprintf "  - ~a\n" id)))
  (when (pair? linked-paths)
    (eprintf
     "WARNING: Linked local source trees will NOT be deleted (only rackup's links to them).\n")
    (for ([p (in-list linked-paths)])
      (eprintf "  - external source tree: ~a\n" p))))

(define (confirm-uninstall! home-path yes?)
  (unless yes?
    (unless (terminal-port? (current-input-port))
      (rackup-error "refusing to uninstall without interactive confirmation (rerun with --dangerously-delete-without-prompting)"))
    (displayln "")
    (printf "Type DELETE to uninstall rackup and remove ~a: " (path->string home-path))
    (flush-output)
    (define answer (read-line))
    (unless (and (string? answer) (equal? (string-trim answer) "DELETE"))
      (rackup-error "uninstall aborted"))))

(define current-remove-shell-init-blocks-proc
  (make-parameter remove-shell-init-blocks!))

(define current-uninstall-system*-proc
  (make-parameter system*))

(define (normalized-path p)
  (simplify-path (path->complete-path p) #t))

(define (validate-uninstall-home-path! home-path)
  (ensure-path-without-control-chars! home-path "uninstall target path")
  (define normalized-home (normalized-path home-path))
  (define user-home (normalized-path (find-system-path 'home-dir)))
  (define env-home
    (let ([h (getenv "HOME")])
      (and h (not (string-blank? h)) (normalized-path h))))
  (define current-dir (normalized-path (current-directory)))
  (cond
    [(not (absolute-path? normalized-home))
     (rackup-error "refusing to uninstall non-absolute target: ~a" (path->string normalized-home))]
    [(equal? normalized-home (string->path "/"))
     (rackup-error "refusing to uninstall unsafe rackup home target: /")]
    [(equal? normalized-home user-home)
     (rackup-error
      "refusing to uninstall unsafe rackup home target equal to your home directory: ~a"
      (path->string normalized-home))]
    [(and env-home (equal? normalized-home env-home))
     (rackup-error
      "refusing to uninstall unsafe rackup home target equal to your home directory: ~a"
      (path->string normalized-home))]
    [(equal? normalized-home current-dir)
     (rackup-error
      "refusing to uninstall unsafe rackup home target equal to the current directory: ~a"
      (path->string normalized-home))]
    [else normalized-home]))

(define (uninstall-rm-exe)
  (or (find-executable-path "rm") (string->path "/bin/rm")))

(define (delete-rackup-home!/external home-path)
  (define normalized-home (validate-uninstall-home-path! home-path))
  (define ok? ((current-uninstall-system*-proc) (uninstall-rm-exe) "-rf" normalized-home))
  (unless ok?
    (rackup-error "failed to delete rackup home synchronously: ~a"
                  (path->string normalized-home))))

(define (cmd-uninstall rest)
  (define yes? (parse-uninstall-options rest))
  (define home-path (validate-uninstall-home-path! (rackup-home)))
  (warn-uninstall-summary home-path)
  (confirm-uninstall! home-path yes?)
  (define removed-rcs
    (with-handlers ([exn:fail? (lambda (e)
                                 (eprintf "rackup: warning: failed to clean shell init blocks: ~a\n"
                                          (exn-message e))
                                 null)])
      ((current-remove-shell-init-blocks-proc))))
  (displayln "rackup uninstalled.")
  (when (pair? removed-rcs)
    (displayln "Removed rackup shell init blocks from:")
    (for ([p (in-list removed-rcs)])
      (printf "  ~a\n" (path->string p))))
  (displayln "Your current shell may still have rackup-related PATH/env changes until you start a new shell.")
  ;; The actual rm -rf is done by the shell wrapper after this process
  ;; exits. In source mode, RACKUP_HOME contains the running .rkt/.zo
  ;; files, so deleting in-process would crash during exit.
  )

(define default-rackup-repo "samth/rackup")

;; Decide which install.sh URL to fetch.  When a custom --ref or --repo
;; is specified (e.g., to test a branch/PR), fetch install.sh directly
;; from the target branch's raw GitHub URL so any install.sh changes on
;; the branch are exercised too.  Otherwise use the published URL.
(define (self-upgrade-script-source #:ref [ref #f] #:repo [repo #f])
  (define env-override (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH"))
  (cond
    [(and env-override (getenv "RACKUP_TESTING"))
     env-override]
    [(or ref repo)
     (format "https://raw.githubusercontent.com/~a/~a/scripts/install.sh"
             (or repo default-rackup-repo)
             (or ref "main"))]
    [else "https://samth.github.io/rackup/install.sh"]))

(define (url-like? s)
  (and (string? s) (regexp-match? #px"^[a-zA-Z][a-zA-Z0-9+.-]*://" s)))

(define (parse-self-upgrade-options rest)
  (define with-init? #f)
  (define mode #f) ; #f = auto, 'exe, 'source
  (define ref #f)
  (define repo #f)
  (command-line #:program "rackup self-upgrade"
                #:argv rest
                #:once-each
                [("--with-init") "Also update shell init" (set! with-init? #t)]
                [("--ref") r
                 "Install rackup from git <ref> (branch, tag, or commit) for testing"
                 (set! ref r)]
                [("--repo") r
                 "Install rackup from GitHub <owner>/<repo> (defaults to samth/rackup)"
                 (set! repo r)]
                #:once-any
                [("--exe") "Require prebuilt binary" (set! mode 'exe)]
                [("--source") "Install from source" (set! mode 'source)]
                #:args ()
                (void))
  (hash 'with-init? with-init? 'mode mode 'ref ref 'repo repo))

(define (cmd-self-upgrade rest)
  (define opts (parse-self-upgrade-options rest))
  (define mode (hash-ref opts 'mode #f))
  (define ref (hash-ref opts 'ref #f))
  (define repo (hash-ref opts 'repo #f))
  (define custom-source? (or ref repo))
  (define source (self-upgrade-script-source #:ref ref #:repo repo))
(define (parse-sha256-sidecar text)
    (for/or ([line (in-list (string-split (string-downcase text) "\n"))])
      (match (regexp-match #px"^([0-9a-f]{64})\\b" (string-trim line))
        [(list _ sha) sha]
        [_ #f])))
  (define script-path
    (cond
      [(url-like? source)
       ;; Only attempt checksum verification for the default published
       ;; install.sh.  Custom --ref/--repo sources fetch from raw GitHub
       ;; and do not publish a .sha256 sidecar; skipping avoids a
       ;; misleading warning and unnecessary HTTP round-trip.
       (define expected-sha
         (cond
           [custom-source? #f]
           [else
            (define checksum-url (string-append source ".sha256"))
            (with-handlers ([exn:fail? (lambda (e)
                                         (rackup-error
                                          "could not verify install script integrity.\nChecksum fetch failed: ~a\nTo skip verification, use: rackup self-upgrade --ref <ref>"
                                          (exn-message e)))])
              (parse-sha256-sidecar (http-get-string checksum-url)))]))
       (define p (make-temporary-file "rackup-self-upgrade-~a.sh"))
       (download-url->file source p)
       (when expected-sha
         (verify-installer-sha256! p expected-sha))
       (file-or-directory-permissions p #o755)
       p]
      [else (string->path source)]))
  (unless (file-exists? script-path)
    (rackup-error "self-upgrade installer script not found: ~a" source))
  (define home-str (path->string (rackup-home)))
  (define sha-file (build-path (rackup-home) ".installed-sha256"))
  (define sha-before
    (and (file-exists? sha-file) (file->string sha-file)))
  (displayln "Checking for updates...")
  (define args
    (append (list "-y")
            (if (hash-ref opts 'with-init? #f)
                null
                (list "--no-init"))
            (cond
              [(eq? mode 'exe)    (list "--exe")]
              [(eq? mode 'source) (list "--source")]
              [else               null])
            (if ref (list "--ref" ref) null)
            (if repo (list "--repo" repo) null)
            (list "--prefix" home-str)))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_BOOTSTRAP_MODE" #"self-upgrade")
  (define ok?
    (parameterize ([current-environment-variables env])
      (apply system* (shell-exe) script-path args)))
  (when (and (url-like? source) (file-exists? script-path))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (delete-file script-path)))
  (unless ok?
    (rackup-error "self-upgrade failed"))
  (define sha-after
    (and (file-exists? sha-file) (file->string sha-file)))
  (when (not (equal? sha-before sha-after))
    (displayln "rackup code upgrade complete.")
    ;; Run `rackup reshim` in a subprocess so the just-installed rackup
    ;; code (not the old in-memory code) drives reshim!.  This ensures
    ;; any migrations of per-toolchain env vars (e.g., backfilling
    ;; PLTCOMPILEDROOTS) run with the new logic.
    (define new-rackup (rackup-bin-entry))
    (when (file-exists? new-rackup)
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (eprintf "rackup: warning: post-upgrade reshim failed: ~a\n"
                                  (exn-message e)))])
        (unless (system* (path->string new-rackup) "reshim")
          (eprintf "rackup: warning: post-upgrade reshim reported failure\n"))))))

(define (cmd-version rest)
  (command-line #:program "rackup version"
                #:argv rest
                #:args ()
                (void))
  (cond
    [baked-version
     (displayln baked-version)]
    [else
     (define (git-output . args)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define out (open-output-string))
         (define git (find-executable-path "git"))
         (and git
              (parameterize ([current-output-port out]
                             [current-error-port (open-output-string)])
                (apply system* git args))
              (let ([s (string-trim (get-output-string out))])
                (and (not (string-blank? s)) s)))))
     (define dir (path->string (let-values ([(d _n _d) (split-path rackup-repo-anchor)]) d)))
     (define commit (git-output "-C" dir "rev-parse" "--short" "HEAD"))
     (define date (git-output "-C" dir "log" "-1" "--format=%ci" "HEAD"))
     (cond
       [commit
        (if date
            (printf "rackup ~a (~a)\n" commit date)
            (printf "rackup ~a\n" commit))]
       [else
        (displayln "rackup (unknown version)")])]))

(define (cmd-doctor rest)
  (command-line #:program "rackup doctor"
                #:argv rest
                #:args ()
                (void))
  (doctor-report))

(define-syntax (rackup-dispatch-table stx)
  (syntax-case stx ()
    [(_)
     (let ([entries (command-registry (lambda (name _aliases _arg _desc _hints handler)
                                        (cons name handler)))])
       (with-syntax ([(name ...) (map car entries)]
                     [(handler ...) (map cdr entries)])
         #'(make-immutable-hash (list (cons name handler) ...))))]))

(define dispatch-table (rackup-dispatch-table))

(define (dispatch args)
  (match args
    ['() (usage)]
    [(or (list "--help") (list "-h")) (usage)]
    [(list "help") (usage)]
    [(list "help" cmd) (dispatch (list cmd "--help"))]
    [(list "help" _ ...) (rackup-error "usage: rackup help [command]")]
    [(cons cmd rest)
     (define canonical-cmd (hash-ref rackup-command-alias-map cmd cmd))
     (define handler (hash-ref dispatch-table canonical-cmd #f))
     (cond
       [handler (handler rest)]
       [else (usage) (exit 2)])]))

(define (main)
  (with-handlers ([exn:fail:user? (lambda (e)
                                    (eprintf "~a\n" (exn-message e))
                                    (exit 2))]
                  [exn:fail? (lambda (e)
                               (eprintf "rackup: internal error: ~a\n" (exn-message e))
                               (exit 1))])
    (dispatch (vector->list (current-command-line-arguments)))))

(module+ for-testing
  (provide cmd-uninstall
           cmd-rebuild
           validate-uninstall-home-path!
           delete-rackup-home!/external
           installed-toolchain-metas/safe
           current-remove-shell-init-blocks-proc
           current-uninstall-system*-proc))
