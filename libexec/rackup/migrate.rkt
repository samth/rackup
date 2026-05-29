#lang racket/base

;; `rackup migrate`: re-install the user-scope packages of an older Racket
;; into a rackup-managed toolchain.
;;
;; `raco pkg migrate <from>` reads the old package list from, and installs
;; the new packages into, subdirectories of a *single* addon directory
;; (`<addon>/<from>/pkgs` and `<addon>/<current>/pkgs`).  rackup gives each
;; toolchain its own isolated addon dir (`~/.rackup/addons/<id>`), so a stock
;; `raco pkg migrate` run inside a rackup toolchain never sees packages that
;; were installed by a non-rackup Racket (which used the OS-default addon
;; dir, e.g. `~/Library/Racket` on macOS) or by a different rackup toolchain.
;;
;; This bridges the gap: it stages the source `<from>/pkgs/pkgs.rktd` under
;; the target toolchain's addon dir, runs the toolchain's own
;; `raco pkg migrate <from>` (which then finds the list and installs into the
;; target's addon dir), and removes the staged copy afterward.

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "env.rkt"
         "error.rkt"
         "paths.rkt"
         "process.rkt"
         "shims.rkt"
         "state.rkt")

(provide migrate-source-versions
         detect-native-addon-dir
         run-migrate!
         current-native-addon-dir-proc
         current-migrate-system*-proc)

;; Stubbable seams for testing.
(define current-migrate-system*-proc (make-parameter system*))
(define current-native-addon-dir-proc
  (make-parameter
   (lambda (target-id)
     (define bin (path->string (rackup-toolchain-bin-link target-id)))
     (define-values (_version _variant addon)
       (probe-local-racket-version+variant+addon-dir bin '()))
     (and addon (string->path addon)))))

(define (path-exists? p)
  (or (file-exists? p) (directory-exists? p) (link-exists? p)))

(define (same-path? a b)
  (equal? (simple-form-path a) (simple-form-path b)))

;; List the version subdirectories of `addon-dir` that hold a user-scope
;; package database (mirrors `pkg-migrate-available-versions`).
(define (migrate-source-versions addon-dir)
  (cond
    [(directory-exists? addon-dir)
     (sort
      (for/list ([p (in-list (directory-list addon-dir))]
                 #:when (file-exists? (build-path addon-dir p "pkgs" "pkgs.rktd")))
        (path-element->string p))
      string<?)]
    [else '()]))

;; The OS-default addon dir as seen by the target toolchain's Racket, i.e.
;; where a non-rackup install would have stored user packages.
(define (detect-native-addon-dir target-id)
  (define addon ((current-native-addon-dir-proc) target-id))
  (unless addon
    (rackup-error
     (string-append
      "could not determine the default addon directory for toolchain ~a\n"
      "  pass --from-addon <dir> (e.g. ~~/Library/Racket on macOS)")
     target-id))
  addon)

;; Build the environment for running the target toolchain's `raco`, matching
;; what the shim dispatcher would set: the user's restored Racket env vars,
;; the toolchain's managed env vars (PLTADDONDIR -> the target addon dir,
;; PLTCOMPILEDROOTS unless the user set their own), RACKUP_TOOLCHAIN, and the
;; shims dir on PATH.
(define (build-target-env target-id)
  (define env (environment-variables-copy (current-environment-variables)))
  (restore-saved-racket-env-vars! env)
  (environment-variables-set! env #"RACKUP_TOOLCHAIN" (string->bytes/utf-8 target-id))
  (for ([kv (in-list (toolchain-runtime-env-vars target-id))])
    (define key (string->bytes/utf-8 (car kv)))
    (unless (and (equal? (car kv) "PLTCOMPILEDROOTS")
                 (environment-variables-ref env key))
      (environment-variables-set! env key (string->bytes/utf-8 (cdr kv)))))
  (define shims (path->string (rackup-shims-dir)))
  (define old-path (or (getenv "PATH") ""))
  (define new-path
    (if (regexp-match? (pregexp (format "(^|:)~a(:|$)" (regexp-quote shims))) old-path)
        old-path
        (string-append shims ":" old-path)))
  (environment-variables-set! env #"PATH" (string->bytes/utf-8 new-path))
  env)

(define (exec-raco-migrate target-id from-version dry-run? extra-args)
  (define raco (resolve-executable-path "raco" target-id))
  (unless raco
    (rackup-error "raco not found in toolchain ~a" target-id))
  (define args
    (append (list "pkg" "migrate")
            (if dry-run? (list "--dry-run") '())
            extra-args
            (list from-version)))
  (parameterize ([current-environment-variables (build-target-env target-id)])
    (if (apply (current-migrate-system*-proc) raco args) 0 1)))

;; Migrate user packages for `from-version` out of `source-addon` into the
;; `target-id` toolchain.  Returns the `raco pkg migrate` exit code (0 on
;; success).  `extra-args` are passed through to `raco pkg migrate`.
(define (run-migrate! #:target-id target-id
                      #:source-addon source-addon
                      #:from-version from-version
                      #:dry-run? [dry-run? #f]
                      #:extra-args [extra-args '()])
  (define source-version-dir (build-path source-addon from-version))
  (define source-pkgs-file (build-path source-version-dir "pkgs" "pkgs.rktd"))
  (unless (file-exists? source-pkgs-file)
    (define avail (migrate-source-versions source-addon))
    (rackup-error
     (string-append
      "no package database for version \"~a\" under ~a\n"
      "  looked for: ~a\n"
      "  versions available there: ~a")
     from-version
     (path->string source-addon)
     (path->string source-pkgs-file)
     (if (null? avail) "(none)" (string-join avail ", "))))
  (define target-addon (rackup-addon-dir target-id))
  (define staged-version-dir (build-path target-addon from-version))
  ;; If the source already lives under the target addon dir (e.g.
  ;; --from-addon points at it), `raco pkg migrate` can read it directly.
  (define need-staging? (not (same-path? source-version-dir staged-version-dir)))
  (when (and need-staging? (path-exists? staged-version-dir))
    (rackup-error
     (string-append
      "cannot stage migration: ~a already exists\n"
      "  the target toolchain may already use version \"~a\", or a previous\n"
      "  migration left it behind; remove it and retry")
     (path->string staged-version-dir)
     from-version))
  (printf "Migrating version ~a packages from ~a into toolchain ~a\n"
          from-version
          (path->string source-addon)
          target-id)
  ;; Flush so this header precedes the subprocess's own output (the child
  ;; writes to the inherited fd directly, bypassing this port's buffer).
  (flush-output)
  (define status (box 1))
  (dynamic-wind
   (lambda ()
     (when need-staging?
       (define staged-pkgs (build-path staged-version-dir "pkgs"))
       (make-directory* staged-pkgs)
       (copy-file source-pkgs-file (build-path staged-pkgs "pkgs.rktd") #t)))
   (lambda ()
     (set-box! status (exec-raco-migrate target-id from-version dry-run? extra-args)))
   (lambda ()
     (when (and need-staging? (directory-exists? staged-version-dir))
       (delete-directory/files staged-version-dir #:must-exist? #f))))
  (unbox status))
