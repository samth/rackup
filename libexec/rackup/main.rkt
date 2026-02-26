#lang racket/base

(require racket/list
         racket/match
         racket/path
         racket/string
         racket/system
         "install.rkt"
         "paths.rkt"
         "shell.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide main)

(define (usage)
  (displayln "rackup - Racket toolchain manager")
  (displayln "")
  (displayln "Commands:")
  (displayln "  install <spec> [--variant cs|bc] [--distribution full|minimal] [--snapshot-site auto|utah|northwestern] [--set-default]")
  (displayln "  list")
  (displayln "  default [<toolchain>]")
  (displayln "  current")
  (displayln "  which <exe> [--toolchain <toolchain>]")
  (displayln "  shell <toolchain> | shell --deactivate")
  (displayln "  run <toolchain> -- <command> [args...]")
  (displayln "  remove <toolchain>")
  (displayln "  reshim")
  (displayln "  init [--shell bash|zsh]")
  (displayln "  doctor")
  (displayln "  help"))

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
                  (list (and (equal? id default-id) "default")
                        (and (equal? id active-id) "active"))))
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
     (if id (displayln id) (displayln ""))]
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
           (begin (set! exe x) (loop more)))])))

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
    [(list "--deactivate")
     (display (emit-shell-deactivation))]
    [(list spec)
     (define id (resolve-toolchain-or-die spec))
     (display (emit-shell-activation id))]
    [_ (rackup-error "usage: rackup shell <toolchain> | rackup shell --deactivate")]))

(define (cmd-init rest)
  (define shell-name #f)
  (match rest
    ['() (void)]
    [(list "--shell" sh)
     (set! shell-name sh)]
    [_ (rackup-error "usage: rackup init [--shell bash|zsh]")])
  (define rc (init-shell! shell-name))
  (reshim!)
  (printf "Initialized shell integration in ~a\n" (path->string rc)))

(define (split-on-double-dash xs)
  (let loop ([left null] [rest xs])
    (cond
      [(null? rest) (values (reverse left) null)]
      [(equal? (car rest) "--") (values (reverse left) (cdr rest))]
      [else (loop (cons (car rest) left) (cdr rest))])))

(define (cmd-run rest)
  (ensure-index!)
  (define-values (head tail) (split-on-double-dash rest))
  (match head
    [(list spec)
     (unless (pair? tail)
       (rackup-error "usage: rackup run <toolchain> -- <command> [args...]"))
     (define id (resolve-toolchain-or-die spec))
     (putenv "RACKUP_TOOLCHAIN" id)
     (putenv "PLTADDONDIR" (path->string (rackup-addon-dir id)))
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
     (remove-toolchain! (resolve-toolchain-or-die spec))]
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

(define (cmd-doctor)
  (doctor-report))

(define (main)
  (with-handlers ([exn:fail:user?
                   (lambda (e)
                     (eprintf "~a\n" (exn-message e))
                     (exit 2))]
                  [exn:fail?
                   (lambda (e)
                     (eprintf "rackup: internal error: ~a\n" (exn-message e))
                     (exit 1))])
    (define args (vector->list (current-command-line-arguments)))
    (match args
      ['() (usage)]
      [(list "help" _ ...) (usage)]
      [(list "install" rest ...) (cmd-install rest)]
      [(list "list") (cmd-list)]
      [(list "default" rest ...) (cmd-default rest)]
      [(list "current") (cmd-current)]
      [(list "which" rest ...) (cmd-which rest)]
      [(list "shell" rest ...) (cmd-shell rest)]
      [(list "run" rest ...) (cmd-run rest)]
      [(list "remove" rest ...) (cmd-remove rest)]
      [(list "reshim") (cmd-reshim)]
      [(list "init" rest ...) (cmd-init rest)]
      [(list "doctor") (cmd-doctor)]
      [_ (usage) (exit 2)])))
