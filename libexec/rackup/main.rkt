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

(provide main
         split-install-command-args)

(define (usage-line cmd desc)
  (printf "  ~a~a~a\n" cmd (make-string (max 2 (- 22 (string-length cmd))) #\space) desc))

(define (usage)
  (displayln "rackup - Racket toolchain manager")
  (displayln "")
  (displayln "Commands:")
  (usage-line "available [--all|--limit N]" "List remote install specs and recent release versions.")
  (usage-line "install <spec> [flags]" "Install a Racket toolchain (release, pre-release, snapshot).")
  (usage-line "link <name> <path> [flags]"
              "Link an in-place/local Racket build as a managed toolchain.")
  (usage-line "list" "List installed toolchains (shows default/active tags).")
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
  (usage-line "remove <toolchain>" "Remove an installed or linked toolchain and its addon dir.")
  (usage-line "reshim" "Rebuild executable shims from installed toolchains.")
  (usage-line "init [--shell bash|zsh]" "Install/update shell integration in ~/.bashrc or ~/.zshrc.")
  (usage-line "uninstall [--yes]"
              "Remove rackup, its toolchains/runtime, and shell init blocks (destructive).")
  (usage-line "self-upgrade [--with-init]"
              "Upgrade rackup's code by rerunning the installer into the current RACKUP_HOME.")
  (usage-line "runtime status|install|upgrade"
              "Manage rackup's hidden internal runtime used to run rackup itself.")
  (usage-line "doctor" "Print diagnostics for paths, runtime, and installed toolchains.")
  (usage-line "help [command]" "Show global help or help for a specific command.")
  (displayln "")
  (displayln "Use `rackup <command> --help` or `rackup help <command>` for command help."))

(define (help-flag? s)
  (and (string? s) (or (equal? s "--help") (equal? s "-h"))))

(define (help-usage usage-line-text)
  (printf "Usage: rackup ~a\n" usage-line-text))

(define (help-option-line flag desc)
  (printf "  ~a~a~a\n" flag (make-string (max 2 (- 24 (string-length flag))) #\space) desc))

(define (show-command-help cmd)
  (define c
    (if (symbol? cmd)
        (symbol->string cmd)
        (format "~a" cmd)))
  (case (string->symbol c)
    [(available)
     (help-usage "available [--all|--limit N]")
     (displayln "")
     (displayln "List install aliases (stable, pre-release, snapshot) and numeric release versions.")
     (displayln "")
     (displayln "Options:")
     (help-option-line "--all" "Show all parsed release versions.")
     (help-option-line "--limit N" "Show at most N release versions (default: 20).")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup available")
     (displayln "  rackup available --limit 50")
     (displayln "  rackup available --all")
     #t]
    [(install)
     (help-usage "install <spec> [flags]")
     (displayln "")
     (displayln
      "Install a Racket toolchain from official release, pre-release, or snapshot installers.")
     (displayln "")
     (displayln "Specs:")
     (displayln "  stable | pre-release | snapshot | snapshot:utah | snapshot:northwestern")
     (displayln "  <numeric version> (examples: 9.1, 8.18, 7.9, 5.2)")
     (displayln "")
     (displayln "Flags:")
     (help-option-line "--variant cs|bc" "Override VM variant (default depends on version).")
     (help-option-line "--distribution full|minimal"
                       "Install full or minimal distribution (default: full).")
     (help-option-line "--snapshot-site auto|utah|northwestern"
                       "Choose snapshot mirror (default: auto).")
     (help-option-line "--arch <arch>" "Override target architecture (default: host arch).")
     (help-option-line "--set-default" "Set installed toolchain as the global default.")
     (help-option-line "--force" "Reinstall if the same canonical toolchain is already installed.")
     (help-option-line "--no-cache" "Redownload installer instead of using cache.")
     (help-option-line "--quiet" "Show minimal output (errors + final result lines).")
     (help-option-line "--verbose" "Show detailed installer URL/path output.")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup install stable")
     (displayln "  rackup install 8.18 --variant cs")
     (displayln "  rackup install snapshot --snapshot-site utah")
     #t]
    [(link)
     (help-usage "link <name> <path> [--set-default] [--force]")
     (displayln "")
     (displayln "Link an in-place/local Racket build as a managed toolchain.")
     (displayln "")
     (displayln "Accepted paths:")
     (displayln "  - source checkout root containing racket/bin and racket/collects")
     (displayln "  - PLTHOME directory containing bin and collects")
     (displayln "")
     (displayln "Flags:")
     (help-option-line "--set-default" "Set the linked toolchain as the global default.")
     (help-option-line "--force" "Replace an existing link with the same local name.")
     (displayln "")
     (displayln "Example:")
     (displayln "  rackup link dev ~/src/racket")
     #t]
    [(list)
     (help-usage "list")
     (displayln "")
     (displayln "List installed toolchains and show default/active tags.")
     #t]
    [(default)
     (help-usage "default [id|status|set <toolchain>|clear|<toolchain>|--unset]")
     (displayln "")
     (displayln "Show, set, or clear the global default toolchain.")
     (displayln
      "If the requested toolchain spec is not installed, interactive shells are prompted to install it.")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup default")
     (displayln "  rackup default id")
     (displayln "  rackup default status")
     (displayln "  rackup default set stable")
     (displayln "  rackup default stable")
     (displayln "  rackup default clear")
     (displayln "  rackup default --unset")
     #t]
    [(current)
     (help-usage "current [id|source|line]")
     (displayln "")
     (displayln
      "Show the active toolchain and whether it comes from shell activation or global default.")
     (displayln "")
     (displayln "Subcommands:")
     (help-option-line "id" "Print only the active toolchain id (blank if none).")
     (help-option-line "source" "Print env|default|none.")
     (help-option-line "line" "Print \"<id><TAB><source>\".")
     #t]
    [(which)
     (help-usage "which <exe> [--toolchain <toolchain>]")
     (displayln "")
     (displayln "Show the real executable path for a tool in a toolchain.")
     #t]
    [(switch)
     (help-usage "switch <toolchain> | switch --unset")
     (displayln "")
     (displayln "Switch the active toolchain in the current shell without changing the default.")
     (displayln "When run via the shell integration installed by `rackup init`, this updates")
     (displayln "the current shell. Otherwise, it emits shell code that you can `eval`.")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup switch stable")
     (displayln "  rackup switch 8.18")
     (displayln "  rackup switch --unset")
     #t]
    [(shell)
     (help-usage "shell <toolchain> | shell --deactivate")
     (displayln "")
     (displayln "Emit shell code to activate/deactivate a toolchain in the current shell.")
     (displayln "This is the low-level form used by `rackup switch` and the shell wrapper.")
     #t]
    [(run)
     (help-usage "run <toolchain> -- <command> [args...]")
     (displayln "")
     (displayln "Run a command under a specific toolchain without changing defaults.")
     #t]
    [(prompt)
     (help-usage "prompt [--long|--short|--raw|--source]")
     (displayln "")
     (displayln "Print prompt/status information for the active toolchain.")
     (displayln "Prints nothing when no active/default toolchain is configured.")
     (displayln "Handled by the shell wrapper without starting Racket when possible.")
     (displayln "")
     (displayln "Default output:")
     (displayln "  racket-9.1")
     (displayln "")
     (displayln "Options:")
     (help-option-line "--long" "Print the long bracketed form: \"[rk:<toolchain-id>]\".")
     (help-option-line "--short" "Print a compact label like \"racket-9.1\" (same as default).")
     (help-option-line "--raw" "Print only the active toolchain id.")
     (help-option-line "--source" "Print \"<id><TAB><env|default>\".")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup prompt")
     (displayln "  rackup prompt --long")
     (displayln "  rackup prompt --short")
     (displayln "  rackup prompt --raw")
     (displayln "  PS1='$(rackup prompt) '$PS1")
     #t]
    [(remove)
     (help-usage "remove <toolchain>")
     (displayln "")
     (displayln "Remove one installed or linked toolchain and its addon directory.")
     #t]
    [(reshim)
     (help-usage "reshim")
     (displayln "")
     (displayln "Rebuild shim executables from the union of installed toolchain executables.")
     #t]
    [(init)
     (help-usage "init [--shell bash|zsh]")
     (displayln "")
     (displayln "Install or update shell integration in ~/.bashrc or ~/.zshrc.")
     (displayln "Writes a managed block that sources ~/.rackup/shell/rackup.<shell>.")
     #t]
    [(uninstall)
     (help-usage "uninstall [--yes]")
     (displayln "")
     (displayln "Remove rackup-managed data and shell init blocks (destructive).")
     (displayln "")
     (displayln "Options:")
     (help-option-line "--yes" "Skip interactive DELETE confirmation.")
     #t]
    [(self-upgrade)
     (help-usage "self-upgrade [--with-init]")
     (displayln "")
     (displayln
      "Upgrade rackup's code by rerunning the bootstrap installer into the current RACKUP_HOME.")
     (displayln
      "By default this skips shell init edits and keeps your current shell config unchanged.")
     (displayln "")
     (displayln "Options:")
     (help-option-line "--with-init"
                       "Allow the installer to run shell init updates (-y without --no-init).")
     (displayln "")
     (displayln "Environment overrides (advanced):")
     (help-option-line "RACKUP_SELF_UPGRADE_INSTALL_SH"
                       "Path or URL to install.sh (test/dev override).")
     #t]
    [(runtime)
     (help-usage "runtime status|install|upgrade")
     (displayln "")
     (displayln "Manage rackup's hidden internal runtime used to run rackup itself.")
     (displayln "")
     (displayln "Subcommands:")
     (help-option-line "status" "Show whether the hidden runtime is present and its metadata.")
     (help-option-line "install" "Install the hidden runtime if missing (or adopt existing).")
     (help-option-line "upgrade" "Install a newer hidden runtime if one is available.")
     #t]
    [(doctor)
     (help-usage "doctor")
     (displayln "")
     (displayln "Print diagnostics for rackup paths, hidden runtime, and installed toolchains.")
     #t]
    [(help)
     (help-usage "help [command]")
     (displayln "")
     (displayln "Show the global command summary or help for a specific command.")
     (displayln "")
     (displayln "Examples:")
     (displayln "  rackup help")
     (displayln "  rackup help install")
     #t]
    [else #f]))

(define (resolve-toolchain-or-die spec)
  (define id (find-local-toolchain spec))
  (unless id
    (rackup-error "no matching installed toolchain: ~a" spec))
  id)

(define install-option-arity
  (hash "--variant"
        1
        "--distribution"
        1
        "--snapshot-site"
        1
        "--arch"
        1
        "--set-default"
        0
        "--force"
        0
        "--no-cache"
        0
        "--quiet"
        0
        "--verbose"
        0))

(define (string-flag-like? s)
  (and (string? s) (> (string-length s) 0) (char=? (string-ref s 0) #\-)))

(define (split-install-command-args rest)
  ;; Accept a single install spec with flags interspersed before/after it.
  ;; `racket/cmdline` handles option parsing in install.rkt once options are isolated.
  (define spec #f)
  (define opts-rev null)
  (let loop ([xs rest])
    (match xs
      ['()
       (unless spec
         (rackup-error "usage: rackup install <spec> [flags]"))
       (values spec (reverse opts-rev))]
      [(list "--" more ...)
       (cond
         [(null? more) (rackup-error "usage: rackup install <spec> [flags]")]
         [spec (rackup-error "usage: rackup install <spec> [flags] (extra argument ~a)" (car more))]
         [(pair? (cdr more))
          (rackup-error "usage: rackup install <spec> [flags] (extra argument ~a)" (cadr more))]
         [else (values (car more) (reverse opts-rev))])]
      [(list tok more ...)
       (define arity (hash-ref install-option-arity tok #f))
       (cond
         [arity
          (when (< (length more) arity)
            (rackup-error "rackup install: the ~s option needs ~a argument~a"
                          tok
                          arity
                          (if (= arity 1) "" "s")))
          (define-values (consumed rest*)
            (if (= arity 0)
                (values (list tok) more)
                (values (list tok (car more)) (cdr more))))
          (set! opts-rev (append (reverse consumed) opts-rev))
          (loop rest*)]
         [(help-flag? tok) (rackup-error "usage: rackup install <spec> [flags]")]
         [(string-flag-like? tok) (rackup-error "unknown install flag: ~a" tok)]
         [spec (rackup-error "usage: rackup install <spec> [flags] (extra argument ~a)" tok)]
         [else
          (set! spec tok)
          (loop more)])])))

(define (toolchain-dir-ids/safe)
  (with-handlers ([exn:fail? (lambda (_) null)])
    (if (directory-exists? (rackup-toolchains-dir))
        (sort (for/list ([p (in-list (directory-list (rackup-toolchains-dir) #:build? #t))]
                         #:when (directory-exists? p))
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
  (unless (directory-exists? tc-dir)
    (rackup-error "orphan toolchain directory not found: ~a" id))
  (delete-directory/files tc-dir)
  (when (directory-exists? addon)
    (delete-directory/files addon))
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (reshim!))
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
  (define id (find-local-toolchain spec))
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

(define (cmd-list)
  (ensure-index!)
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (define default-id (get-default-toolchain idx))
  (define active-id (resolve-active-toolchain-id))
  (define env-id (getenv "RACKUP_TOOLCHAIN"))
  (define stale-env?
    (and env-id
         (not (string-blank? env-id))
         (not (member env-id ids))))
  (when stale-env?
    (printf "Warning: RACKUP_TOOLCHAIN selects '~a', but that toolchain is not installed.\n" env-id)
    (when (and default-id (member default-id ids))
      (printf "It overrides the default toolchain '~a'.\n" default-id))
    (displayln "Clear it with: rackup switch --unset")
    (displayln "Or unset it manually with: unset RACKUP_TOOLCHAIN")
    (newline))
  (if (null? ids)
      (displayln "No toolchains installed.")
      (for ([id ids])
        (define m (read-toolchain-meta id))
        (define tags
          (filter values
                  (list (and (equal? id default-id) "default") (and (equal? id active-id) "active"))))
        (printf "~a~a  (~a, ~a, ~a)\n"
                (if (null? tags)
                    ""
                    (format "[~a] " (string-join tags ",")))
                id
                (hash-ref m 'resolved-version "?")
                (hash-ref m 'variant "?")
                (hash-ref m 'distribution "?")))))

(define (default-id->line)
  (define id (get-default-toolchain))
  (if id
      (displayln id)
      (displayln "")))

(define (set-default-from-spec! spec)
  (define id (resolve-toolchain-or-offer-install spec))
  (set-default-toolchain! id)
  (reshim!)
  (displayln (format "Default toolchain: ~a" id)))

(define (cmd-default rest)
  (ensure-index!)
  (match rest
    ['() (default-id->line)]
    [(list "id") (default-id->line)]
    [(list "status")
     (define id (get-default-toolchain))
     (if id
         (printf "set\t~a\n" id)
         (displayln "unset"))]
    [(list "set" spec)
     (set-default-from-spec! spec)]
    [(or (list "--unset") (list "clear"))
     (clear-default-toolchain!)
     (displayln "Cleared default toolchain.")]
    [(list spec)
     (set-default-from-spec! spec)]
    [_ (rackup-error
        "usage: rackup default [id|status|set <toolchain>|clear|<toolchain>|--unset]")]))

(define (source->line src)
  (if src
      (symbol->string src)
      "none"))

(define (cmd-current rest)
  (ensure-index!)
  (define id (resolve-active-toolchain-id))
  (define src (current-toolchain-source))
  (match rest
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

(define (cmd-switch rest)
  (ensure-index!)
  (match rest
    [(list "--unset") (display (emit-shell-deactivation))]
    [(list spec)
     (define id (resolve-toolchain-or-offer-install spec))
     (display (emit-shell-activation id))]
    [_ (rackup-error "usage: rackup switch <toolchain> | rackup switch --unset")]))

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
    [(list spec)
     (define installed-id (find-local-toolchain spec))
     (cond
       [installed-id (remove-toolchain! installed-id)]
       [else
        (define orphan-id (find-orphan-toolchain-id spec))
        (if orphan-id
            (remove-orphan-toolchain! orphan-id)
            (rackup-error "no matching installed toolchain: ~a" spec))])]
    [_ (rackup-error "usage: rackup remove <toolchain>")]))

(define (cmd-reshim)
  (ensure-index!)
  (reshim!)
  (displayln "Reshim complete."))

(define (cmd-install rest)
  (if (ormap help-flag? rest)
      (show-command-help 'install)
      (let-values ([(spec opts) (split-install-command-args rest)])
        (void (install-toolchain! spec opts)))))

(define (prompt-short-label id)
  (define meta (and id (read-toolchain-meta id)))
  (define kind (and (hash? meta) (hash-ref meta 'kind #f)))
  (define version (and (hash? meta) (hash-ref meta 'resolved-version #f)))
  (define suffix
    (match kind
      ['release (or version id)]
      ['stable (or version id)]
      ['pre-release (format "pre-~a" (or version id))]
      ['snapshot (format "snapshot-~a" (or version id))]
      ['local
       (cond
         [(and (string? version)
               (not (string-blank? version))
               (not (equal? version "local")))
          (format "local-~a" version)]
         [(and (string? id) (string-prefix? id "local-")) (format "local-~a" (substring id 6))]
         [else (or id "local")])]
      [_ (or id "")]))
  (if (string-blank? suffix) "" (format "racket-~a" suffix)))

(define (cmd-prompt rest)
  (define mode
    (match rest
      ['() 'short]
      [(list "--long") 'long]
      [(list "--short") 'short]
      [(list "--raw") 'raw]
      [(list "--source") 'source]
      [_ (rackup-error "usage: rackup prompt [--long|--short|--raw|--source]")]))
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
      [(list flag _ ...)
       (rackup-error "usage: rackup available [--all|--limit N] (unknown flag ~a)" flag)])))

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
  (displayln
   "Your current shell may still have rackup-related PATH/env changes until you start a new shell."))

(define (self-upgrade-script-source)
  (or (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH") "https://samth.github.io/rackup/install.sh"))

(define (url-like? s)
  (and (string? s) (regexp-match? #px"^[a-zA-Z][a-zA-Z0-9+.-]*://" s)))

(define (parse-self-upgrade-options rest)
  (define with-init? #f)
  (let loop ([xs rest])
    (match xs
      ['() (hash 'with-init? with-init?)]
      [(list "--with-init" more ...)
       (set! with-init? #t)
       (loop more)]
      [(list flag _ ...)
       (rackup-error "usage: rackup self-upgrade [--with-init] (unknown flag ~a)" flag)])))

(define (shell-exe/path)
  (or (find-executable-path "sh") (string->path "/bin/sh")))

(define (cmd-self-upgrade rest)
  (define opts (parse-self-upgrade-options rest))
  (define source (self-upgrade-script-source))
  (define script-path
    (cond
      [(url-like? source)
       (define p (make-temporary-file "rackup-self-upgrade-~a.sh"))
       (download-url->file source p)
       (file-or-directory-permissions p #o755)
       p]
      [else (string->path source)]))
  (unless (file-exists? script-path)
    (rackup-error "self-upgrade installer script not found: ~a" source))
  (define home-str (path->string (rackup-home)))
  (printf "Upgrading rackup code in ~a\n" home-str)
  (when (url-like? source)
    (printf "Using installer script: ~a\n" source))
  (define args
    (append (list "-y")
            (if (hash-ref opts 'with-init? #f)
                null
                (list "--no-init"))
            (list "--prefix" home-str)))
  (define old-bootstrap-mode (getenv "RACKUP_BOOTSTRAP_MODE"))
  (define ok? #f)
  (dynamic-wind (lambda () (putenv "RACKUP_BOOTSTRAP_MODE" "self-upgrade"))
                (lambda () (set! ok? (apply system* (shell-exe/path) script-path args)))
                (lambda ()
                  (if old-bootstrap-mode
                      (putenv "RACKUP_BOOTSTRAP_MODE" old-bootstrap-mode)
                      (putenv "RACKUP_BOOTSTRAP_MODE" ""))))
  (when (and (url-like? source) (file-exists? script-path))
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (delete-file script-path)))
  (unless ok?
    (rackup-error "self-upgrade failed"))
  (displayln "rackup code upgrade complete."))

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
    (cond
      [(and (= (length args) 2) (help-flag? (second args)))
       (unless (show-command-help (first args))
         (usage)
         (exit 2))]
      [else
       (match args
         ['() (usage)]
         [(or (list "--help") (list "-h")) (usage)]
         [(list "help") (usage)]
         [(list "help" cmd)
          (unless (show-command-help cmd)
            (usage)
            (exit 2))]
         [(list "help" _ ...) (rackup-error "usage: rackup help [command]")]
         [(list "available" rest ...) (cmd-available rest)]
         [(list "install" rest ...) (cmd-install rest)]
         [(list "link" rest ...) (cmd-link rest)]
         [(list "list") (cmd-list)]
         [(list "default" rest ...) (cmd-default rest)]
         [(list "current" rest ...) (cmd-current rest)]
         [(list "prompt" rest ...) (cmd-prompt rest)]
         [(list "which" rest ...) (cmd-which rest)]
         [(list "switch" rest ...) (cmd-switch rest)]
         [(list "shell" rest ...) (cmd-shell rest)]
         [(list "run" rest ...) (cmd-run rest)]
         [(list "remove" rest ...) (cmd-remove rest)]
         [(list "reshim") (cmd-reshim)]
         [(list "init" rest ...) (cmd-init rest)]
         [(list "uninstall" rest ...) (cmd-uninstall rest)]
         [(list "self-upgrade" rest ...) (cmd-self-upgrade rest)]
         [(list "runtime" rest ...) (cmd-runtime rest)]
         [(list "doctor") (cmd-doctor)]
         [_
          (usage)
          (exit 2)])])))
