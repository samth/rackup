#lang at-exp racket/base

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         scribble/text
         "commands-data.rkt"
         "error.rkt"
         "paths.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "text.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!
         refresh-shell-integration!
         strip-managed-block
         remove-shell-init-blocks!)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

;; The rackup subcommand list lives in commands-data.rkt; the dispatcher
;; in main.rkt is generated from the same data via a macro, so the two
;; cannot drift apart.

(define commands-line (string-join (map car rackup-commands) " "))

(define (write-bash-completion-script)
  (define bash-command-cases (include/text "templates/bash-command-cases.scrbl"))
  (output (include/text "templates/bash-completion.scrbl")))

(define (write-zsh-completion-script)
  (define command-describe-list
    ;; '_describe'-format `'name:description'` lines, one per command.
    (apply string-append
           (for/list ([e (in-list rackup-commands)])
             (string-append "    '" (car e) ":" (cdr e) "'\n"))))
  (output (include/text "templates/zsh-completion.scrbl")))

;; Write the shell helper to current-output-port.  Production callers
;; wrap in `with-output-to-file`; the for-testing submodule exposes a
;; with-output-to-string convenience for snapshot tests.
(define (write-shell-helper-script shell-name)
  (display "# rackup shell helper\n")
  (display path-prepend)
  (output (include/text "templates/shell-wrapper.scrbl"))
  (newline)
  (match shell-name
    ["bash" (write-bash-completion-script)]
    ["zsh" (write-zsh-completion-script)]))

(define path-prepend
  @~a{if [ -d "${RACKUP_HOME:-$HOME/.rackup}/shims" ]; then
        case ":$PATH:" in *":${RACKUP_HOME:-$HOME/.rackup}/shims:"*) ;; *) export PATH="${RACKUP_HOME:-$HOME/.rackup}/shims:$PATH" ;; esac
      fi@"\n"})

(define (managed-rc-block shell-name)
  (define shell-script @~a{${RACKUP_HOME:-$HOME/.rackup}/shell/rackup.@|shell-name|})
  @~a{@|start-marker|
      [ -f "@|shell-script|" ] && . "@|shell-script|"
      @|end-marker|@"\n"})

(define (emit-shell-activation toolchain-id)
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  ;; Only set RACKUP_TOOLCHAIN and PATH.  Racket-specific env vars
  ;; (PLTCOMPILEDROOTS, PLTADDONDIR, PLTHOME) are set internally by the
  ;; shim dispatcher via env.sh, scoped to each invocation — not exported
  ;; into the user's shell where they would leak into non-rackup commands.
  @~a{@|path-prepend|export RACKUP_TOOLCHAIN=@(sh-single-quote toolchain-id)@"\n"})

(define (deactivation-extra-vars)
  (define active (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and active (toolchain-exists? active))
     (remove-duplicates (map car (toolchain-env-vars active)))]
    [else null]))

(define (emit-shell-deactivation)
  ;; Unset RACKUP_TOOLCHAIN and any Racket env vars that might be
  ;; lingering from prior sessions (backwards compatibility).
  (define extras
    (apply string-append
           (for/list ([k (in-list (deactivation-extra-vars))])
             (~a "unset " k "\n"))))
  @~a{@|path-prepend|@|extras|unset RACKUP_TOOLCHAIN
      unset PLTADDONDIR
      unset PLTCOMPILEDROOTS
      unset PLTHOME@"\n"})

(define (guess-shell)
  (if (regexp-match? #px"/zsh$" (or (getenv "SHELL") "")) "zsh" "bash"))

(define (rc-path shell-name)
  (build-path (find-system-path 'home-dir) (format ".~arc" shell-name)))

;; The full managed `# >>> rackup ... # <<< rackup\n?` block as a regex,
;; including any trailing newline so removal doesn't leave a blank line.
(define managed-block-rx
  (pregexp (string-append "(?m:^)" (regexp-quote start-marker)
                          "[\\s\\S]*?" (regexp-quote end-marker) "\n?")))

(define (replace-managed-block existing new-block)
  (cond
    [(regexp-match? managed-block-rx existing)
     ;; Pass the replacement via a procedure so `&` / `\\1` in `new-block`
     ;; aren't interpreted as backreferences.
     (regexp-replace managed-block-rx existing (lambda _ new-block))]
    [(string-blank? existing) new-block]
    [else (string-append existing "\n" new-block)]))

(define (strip-managed-block existing)
  (define stripped (regexp-replace managed-block-rx existing ""))
  (cond
    [(equal? stripped existing) (values existing #f)]
    [(string-blank? stripped) (values "" #t)]
    [else (values stripped #t)]))

(define (remove-shell-init-blocks!)
  (for/fold ([removed '()] #:result (reverse removed))
            ([shell* (in-list '("bash" "zsh"))])
    (define rc (rc-path shell*))
    (cond
      [(not (file-exists? rc)) removed]
      [else
       (define-values (updated changed?) (strip-managed-block (read-string-file rc "")))
       (cond
         [changed? (write-string-file rc updated) (cons rc removed)]
         [else removed])])))

(define (write-shell-helper-files!)
  (for ([s (in-list '("bash" "zsh"))])
    (with-output-to-file (rackup-shell-script s)
      #:exists 'truncate/replace
      (lambda () (write-shell-helper-script s)))))

;; Refresh helper scripts in-place (e.g. after `self-upgrade`) so any
;; new commands or flags become tab-completable in existing shells
;; without requiring the user to rerun `rackup init`.  Only writes the
;; helper scripts; does NOT modify the user's rc files.  No-op if the
;; user has not previously run `rackup init` (no helper directory).
(define (refresh-shell-integration!)
  (when (directory-exists? (rackup-shell-dir))
    (write-shell-helper-files!)))

(define (init-shell! [shell-name #f])
  (ensure-rackup-layout!)
  (define shell* (or shell-name (guess-shell)))
  (unless (member shell* '("bash" "zsh"))
    (rackup-error "unsupported shell for init: ~a" shell*))
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (write-shell-helper-files!)
  (define rc (rc-path shell*))
  (define existing (read-string-file rc ""))
  (write-string-file rc (replace-managed-block existing (managed-rc-block shell*)))
  rc)

(module+ for-testing
  (provide shell-helper-script)
  (define (shell-helper-script shell-name)
    (with-output-to-string
      (lambda () (write-shell-helper-script shell-name)))))
