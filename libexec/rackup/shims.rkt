#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/set
         racket/string
         "paths.rkt"
         "state.rkt"
         "rktd-io.rkt"
         "util.rkt")

(provide ensure-shim-dispatcher!
         ensure-core-rackup-shim!
         resolve-active-toolchain-id
         resolve-executable-path
         reshim!
         current-toolchain-source)

(define (dispatcher-script)
  (string-append
   "#!/usr/bin/env bash\n"
   "set -euo pipefail\n"
   "SELF=\"${BASH_SOURCE[0]}\"\n"
   "LIBEXEC_DIR=\"$(cd -P \"$(dirname \"$SELF\")\" && pwd)\"\n"
   "HOME_DIR=\"${RACKUP_HOME:-$(cd -P \"$LIBEXEC_DIR/..\" && pwd)}\"\n"
   "SHIM_NAME=\"$(basename \"$0\")\"\n"
   "DEFAULT_FILE=\"$HOME_DIR/state/default-toolchain\"\n"
   "ACTIVE=\"${RACKUP_TOOLCHAIN:-}\"\n"
   "if [[ -z \"$ACTIVE\" && -f \"$DEFAULT_FILE\" ]]; then\n"
   "  ACTIVE=\"$(tr -d '\\r\\n' < \"$DEFAULT_FILE\")\"\n"
   "fi\n"
   "if [[ -z \"$ACTIVE\" ]]; then\n"
   "  echo \"rackup: no active/default toolchain configured\" >&2\n"
   "  echo \"Try: rackup list ; rackup default <toolchain>\" >&2\n"
   "  exit 2\n"
   "fi\n"
   "TARGET=\"$HOME_DIR/toolchains/$ACTIVE/bin/$SHIM_NAME\"\n"
   "if [[ ! -x \"$TARGET\" ]]; then\n"
   "  echo \"rackup: executable '$SHIM_NAME' not found in toolchain '$ACTIVE'\" >&2\n"
   "  echo \"Try: rackup which $SHIM_NAME --toolchain $ACTIVE\" >&2\n"
   "  exit 127\n"
   "fi\n"
   "if [[ -z \"${PLTADDONDIR:-}\" ]]; then\n"
   "  export PLTADDONDIR=\"$HOME_DIR/addons/$ACTIVE\"\n"
   "fi\n"
   "exec \"$TARGET\" \"$@\"\n"))

(define (ensure-shim-dispatcher!)
  (ensure-rackup-layout!)
  (define p (rackup-shim-dispatcher))
  (write-string-file p (dispatcher-script))
  (file-or-directory-permissions p #o755)
  p)

(define (ensure-core-rackup-shim!)
  (ensure-rackup-layout!)
  (define shim (build-path (rackup-shims-dir) "rackup"))
  (when (or (link-exists? shim) (file-exists? shim))
    (delete-file shim))
  (make-file-or-directory-link (rackup-bin-entry) shim)
  shim)

(define (resolve-active-toolchain-id)
  (define env (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and env (not (string-blank? env))) env]
    [else (get-default-toolchain)]))

(define (current-toolchain-source)
  (define env (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and env (not (string-blank? env))) 'env]
    [(get-default-toolchain) 'default]
    [else #f]))

(define (resolve-executable-path exe [toolchain-id #f])
  (define id (or toolchain-id (resolve-active-toolchain-id)))
  (unless id
    (rackup-error "no active/default toolchain configured"))
  (define p (build-path (rackup-toolchain-bin-link id) exe))
  (if (file-exists? p) p #f))

(define (rackup-managed-shim? p)
  (and (link-exists? p)
       (let ([target (simplify-path (resolve-path p) #t)])
         (or (equal? target (simplify-path (rackup-shim-dispatcher) #t))
             (equal? target (simplify-path (rackup-bin-entry) #t))))))

(define (all-installed-executables)
  (define ids (installed-toolchain-ids))
  (sort (remove-duplicates
         (append*
          (for/list ([id ids])
            (define m (read-toolchain-meta id))
            (if (and (hash? m) (list? (hash-ref m 'executables #f)))
                (hash-ref m 'executables)
                null))))
        string<?))

(define (reshim!)
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (define shims-dir (rackup-shims-dir))
  (define dispatcher (rackup-shim-dispatcher))
  (define desired (list->set (cons "rackup" (all-installed-executables))))
  (for ([name (in-set desired)])
    (unless (equal? name "rackup")
      (define p (build-path shims-dir name))
      (when (link-exists? p) (delete-file p))
      (make-file-or-directory-link dispatcher p)))
  (for ([p (in-list (directory-list shims-dir #:build? #t))])
    (define name (path-basename-string p))
    (when (and (not (set-member? desired name))
               (rackup-managed-shim? p))
      (delete-file p))))
