#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         "paths.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!
         strip-managed-block
         remove-shell-init-blocks!)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

(define (shell-helper-script)
  (string-append "# rackup shell helper\n"
                 (emit-path-prepend)
                 "rackup() {\n"
                 "  local _rackup_bin=\"${RACKUP_HOME:-$HOME/.rackup}/bin/rackup\"\n"
                 "  if [ \"$#\" -gt 0 ] && [ \"$1\" = \"shell\" ]; then\n"
                 "    shift\n"
                 "    eval \"$(\"$_rackup_bin\" shell \"$@\")\"\n"
                 "  else\n"
                 "    \"$_rackup_bin\" \"$@\"\n"
                 "  fi\n"
                 "}\n"))

(define (managed-rc-block shell-name)
  (define base "${RACKUP_HOME:-$HOME/.rackup}")
  (define shell-script (format "~a/shell/rackup.~a" base shell-name))
  (string-append start-marker
                 "\n"
                 "[ -f \""
                 shell-script
                 "\" ] && . \""
                 shell-script
                 "\"\n"
                 end-marker
                 "\n"))

(define (emit-path-prepend)
  "if [ -d \"${RACKUP_HOME:-$HOME/.rackup}/shims\" ]; then\n  case \":$PATH:\" in *\":${RACKUP_HOME:-$HOME/.rackup}/shims:\"*) ;; *) export PATH=\"${RACKUP_HOME:-$HOME/.rackup}/shims:$PATH\" ;; esac\nfi\n")

(define (emit-env-exports vars)
  (apply string-append
         (for/list ([kv (in-list vars)])
           (define k (car kv))
           (define v (cdr kv))
           (format "export ~a=~a\n" k (sh-single-quote v)))))

(define (emit-shell-activation toolchain-id)
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  (define extra-env (toolchain-env-vars toolchain-id))
  (define addon (path->string* (rackup-addon-dir toolchain-id)))
  (string-append (emit-path-prepend)
                 (emit-env-exports extra-env)
                 "export RACKUP_TOOLCHAIN="
                 (sh-single-quote toolchain-id)
                 "\n"
                 "export PLTADDONDIR="
                 (sh-single-quote addon)
                 "\n"))

(define (deactivation-extra-vars)
  (define active (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and active (toolchain-exists? active))
     (for/list ([kv (in-list (toolchain-env-vars active))])
       (car kv))]
    [else null]))

(define (emit-shell-deactivation)
  (define extra-vars (remove-duplicates (deactivation-extra-vars)))
  (string-append (emit-path-prepend)
                 (apply string-append
                        (for/list ([k (in-list extra-vars)])
                          (format "unset ~a\n" k)))
                 "unset RACKUP_TOOLCHAIN\n"
                 "unset PLTADDONDIR\n"))

(define (guess-shell)
  (define sh (or (getenv "SHELL") ""))
  (cond
    [(regexp-match? #px"/zsh$" sh) "zsh"]
    [else "bash"]))

(define (rc-path shell-name)
  (build-path (find-system-path 'home-dir) (format ".~arc" shell-name)))

(define (replace-managed-block existing new-block)
  (define start-match (regexp-match-positions (regexp (regexp-quote start-marker)) existing))
  (cond
    [start-match
     (define start-pos (caar start-match))
     (define after-start (substring existing start-pos))
     (define end-match (regexp-match-positions (regexp (regexp-quote end-marker)) after-start))
     (if (not end-match)
         (string-append existing "\n" new-block)
         (let* ([end-pos-rel (cdar end-match)]
                [end-pos (+ start-pos end-pos-rel)]
                [after-end (substring existing end-pos)]
                [after-end* (if (and (positive? (string-length after-end))
                                     (char=? (string-ref after-end 0) #\newline))
                                (substring after-end 1)
                                after-end)])
           (string-append (substring existing 0 start-pos) new-block after-end*)))]
    [else
     (string-append (if (string-blank? existing)
                        ""
                        (string-append existing "\n"))
                    new-block)]))

(define (strip-managed-block existing)
  (define start-match (regexp-match-positions (regexp (regexp-quote start-marker)) existing))
  (cond
    [(not start-match) (values existing #f)]
    [else
     (define start-pos (caar start-match))
     (define after-start (substring existing start-pos))
     (define end-match (regexp-match-positions (regexp (regexp-quote end-marker)) after-start))
     (cond
       [(not end-match) (values existing #f)]
       [else
        (define end-pos-rel (cdar end-match))
        (define end-pos (+ start-pos end-pos-rel))
        (define after-end (substring existing end-pos))
        (define after-end*
          (if (and (positive? (string-length after-end)) (char=? (string-ref after-end 0) #\newline))
              (substring after-end 1)
              after-end))
        (define prefix (substring existing 0 start-pos))
        (define combined (string-append prefix after-end*))
        (define trimmed (string-trim combined))
        (values (if (string-blank? trimmed) "" combined) #t)])]))

(define (remove-shell-init-blocks!)
  (define removed null)
  (for ([shell* '("bash" "zsh")])
    (define rc (rc-path shell*))
    (when (file-exists? rc)
      (define existing (read-string-file rc ""))
      (define-values (updated changed?) (strip-managed-block existing))
      (when changed?
        (write-string-file rc updated)
        (set! removed (cons rc removed)))))
  (reverse removed))

(define (init-shell! [shell-name #f])
  (ensure-rackup-layout!)
  (define shell* (or shell-name (guess-shell)))
  (unless (member shell* '("bash" "zsh"))
    (rackup-error "unsupported shell for init: ~a" shell*))
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (for ([s '("bash" "zsh")])
    (define p (rackup-shell-script s))
    (write-string-file p (shell-helper-script)))
  (define rc (rc-path shell*))
  (define existing (read-string-file rc ""))
  (write-string-file rc (replace-managed-block existing (managed-rc-block shell*)))
  rc)
