#lang racket/base

(require racket/file
         racket/path
         racket/string
         "paths.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

(define (shell-helper-script)
  (string-append
   "# rackup shell helper\n"
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
  (define shell-script
    (format "~a/shell/rackup.~a" base shell-name))
  (string-append
   start-marker "\n"
   "if [ -d \"" base "/shims\" ]; then\n"
   "  case \":$PATH:\" in\n"
   "    *\":"
   base
   "/shims:\"*) ;;\n"
   "    *) export PATH=\""
   base
   "/shims:$PATH\" ;;\n"
   "  esac\n"
   "fi\n"
   "[ -f \"" shell-script "\" ] && . \"" shell-script "\"\n"
   end-marker "\n"))

(define (emit-path-prepend)
  "if [ -d \"${RACKUP_HOME:-$HOME/.rackup}/shims\" ]; then\n  case \":$PATH:\" in *\":${RACKUP_HOME:-$HOME/.rackup}/shims:\"*) ;; *) export PATH=\"${RACKUP_HOME:-$HOME/.rackup}/shims:$PATH\" ;; esac\nfi\n")

(define (emit-shell-activation toolchain-id)
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  (define addon (path->string* (rackup-addon-dir toolchain-id)))
  (string-append
   (emit-path-prepend)
   "export RACKUP_TOOLCHAIN='" toolchain-id "'\n"
   "export PLTADDONDIR='" addon "'\n"))

(define (emit-shell-deactivation)
  (string-append
   (emit-path-prepend)
   "unset RACKUP_TOOLCHAIN\n"
   "unset PLTADDONDIR\n"))

(define (guess-shell)
  (define sh (or (getenv "SHELL") ""))
  (cond
    [(regexp-match? #px"/zsh$" sh) "zsh"]
    [else "bash"]))

(define (rc-path shell-name)
  (build-path (find-system-path 'home-dir)
              (format ".~arc" shell-name)))

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
           (string-append (substring existing 0 start-pos)
                          new-block
                          after-end*)))]
    [else
     (string-append (if (string-blank? existing) "" (string-append existing "\n"))
                    new-block)]))

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
