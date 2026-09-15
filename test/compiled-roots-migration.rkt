#lang racket/base

;; Upgrade/migration-path tests for compiled-output isolation: linking or
;; rebuilding a git source checkout flips it to keyed-only (single root,
;; config.rktd written), while a bare reshim never flips an unmigrated
;; toolchain.  Steady-state unit tests live in test/compiled-roots.rkt.

(require rackunit
         racket/file
         racket/path
         racket/system
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-rebuild)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rebuild.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt")

(define (write-empty-file! p)
  (with-output-to-file p (lambda () (display "")) #:exists 'replace))

(define (write-script! p body)
  (with-output-to-file p (lambda () (display body)) #:exists 'replace)
  (file-or-directory-permissions p #o755))

;; A fake in-place source tree with a `racket` that answers rackup's
;; version/variant/addon probe (matching test/rebuild.rkt).
(define (make-fake-source-tree! root)
  (define plthome (build-path root "racket"))
  (define bin (build-path plthome "bin"))
  (make-directory* bin)
  (make-directory* (build-path plthome "collects"))
  (make-directory* (build-path root "pkgs"))
  (write-empty-file! (build-path root "Makefile"))
  (write-script!
   (build-path bin "racket")
   (string-append "#!/usr/bin/env bash\n"
                  "set -euo pipefail\n"
                  "if [[ \"$#\" -ge 2 && \"$1\" == \"-e\" ]]; then\n"
                  "  if [[ \"$2\" == *\"(version)\"*\"system-type\"*\"find-system-path\"* ]]; then\n"
                  "    printf '9.99-rebuild\\nchez-scheme\\n%s' \"${PLTADDONDIR:-/tmp/x}\"\n"
                  "    exit 0\n"
                  "  fi\n"
                  "fi\n"
                  "exit 1\n"))
  (write-script! (build-path bin "raco") "#!/usr/bin/env bash\nexit 0\n"))

(define (with-temp-rackup-home proc)
  (define home (make-temporary-file "rackup-croots-mig~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
  (environment-variables-set! env #"RACKUP_TOOLCHAIN" #f)
  ;; Exercise the real (non-test) code path so keyed-only actually applies:
  ;; the migration is gated off under RACKUP_TESTING to protect shared trees.
  (environment-variables-set! env #"RACKUP_TESTING" #f)
  (dynamic-wind void
                (lambda ()
                  (parameterize ([current-environment-variables env])
                    (proc home)))
                (lambda () (delete-directory/files home #:must-exist? #f))))

(define (config-roots src)
  (define cfg (read-rktd-file (build-path src "racket" "etc" "config.rktd") #f))
  (and (hash? cfg) (hash-ref cfg 'compiled-file-roots #f)))

(define (expected-key id-meta)
  (compiled-roots-key (hash-ref id-meta 'resolved-version #f)
                      (hash-ref id-meta 'variant #f)
                      (hash-ref id-meta 'requested-spec #f)))

(module+ test
  (define git (find-executable-path "git"))

  ;; --- Upgrade via rebuild on a git checkout ------------------------------
  ;; A legacy toolchain (no scheme flag, `:.` env) that gets rebuilt in a
  ;; git tree migrates: config.rktd records a single keyed root, meta gains
  ;; 'keyed-only, and env.sh drops the `.` fallback.  The stubbed system*
  ;; makes git-work-tree? and make both "succeed" without real work; it
  ;; still needs the git binary present for the detection path.
  (when git
    (with-temp-rackup-home
     (lambda (home)
       (define src (build-path home "src-git"))
       (make-directory* src)
       (make-fake-source-tree! src)
       (link-toolchain! "gitsrc" (path->string src) '("--set-default"))
       (define id "local-gitsrc")
       ;; Fresh link on a non-git temp dir => legacy to start.
       (check-not-equal? (hash-ref (read-toolchain-meta id) 'compiled-roots-scheme #f) 'keyed-only)
       (define key (expected-key (read-toolchain-meta id)))
       (parameterize ([current-rebuild-system*-proc (lambda args #t)])
         (cmd-rebuild '("gitsrc")))
       (define meta (read-toolchain-meta id))
       (check-equal? (hash-ref meta 'compiled-roots-scheme #f)
                     'keyed-only
                     "rebuild in a git tree migrates to keyed-only")
       (check-equal? (config-roots src)
                     (list key)
                     "config.rktd records the single keyed root (no fallback)")
       (define env-sh (file->string (rackup-toolchain-env-file id)))
       (check-true (regexp-match? (regexp (regexp-quote key)) env-sh))
       (check-false (regexp-match? (regexp (string-append (regexp-quote key) ":\\.")) env-sh)
                    "migrated env.sh has no `.` fallback"))))

  ;; --- Rebuild on a NON-git tree stays legacy -----------------------------
  (with-temp-rackup-home
   (lambda (home)
     (define src (build-path home "src-nogit"))
     (make-directory* src)
     (make-fake-source-tree! src)
     (link-toolchain! "nogitsrc" (path->string src) '("--set-default"))
     (define id "local-nogitsrc")
     (define key (expected-key (read-toolchain-meta id)))
     ;; Stub: git rev-parse "fails" (not a git tree); make "succeeds".
     (parameterize ([current-rebuild-system*-proc (lambda (exe . rest)
                                                    (not (member "rev-parse" rest)))])
       (cmd-rebuild '("nogitsrc")))
     (define meta (read-toolchain-meta id))
     (check-not-equal? (hash-ref meta 'compiled-roots-scheme #f)
                       'keyed-only
                       "non-git rebuild does not migrate")
     (define env-sh (file->string (rackup-toolchain-env-file id)))
     (check-true (regexp-match? (regexp (string-append (regexp-quote key) ":\\.")) env-sh)
                 "non-git rebuild keeps the legacy `.` fallback")))

  ;; --- A bare reshim never flips, but honors a persisted flag -------------
  (with-temp-rackup-home
   (lambda (home)
     (define src (build-path home "src-reshim"))
     (make-directory* src)
     (make-fake-source-tree! src)
     (link-toolchain! "reshimsrc" (path->string src) '("--set-default"))
     (define id "local-reshimsrc")
     (define key (expected-key (read-toolchain-meta id)))
     ;; Unmigrated: reshim leaves the legacy `.` fallback in place.
     (with-state-lock (reshim!))
     (define env1 (file->string (rackup-toolchain-env-file id)))
     (check-true (regexp-match? (regexp (string-append (regexp-quote key) ":\\.")) env1)
                 "bare reshim does not flip an unmigrated toolchain")
     ;; After a migration recorded the flag, reshim keeps it keyed-only.
     (write-toolchain-meta! id (hash-set (read-toolchain-meta id) 'compiled-roots-scheme 'keyed-only))
     (with-state-lock (reshim!))
     (define env2 (file->string (rackup-toolchain-env-file id)))
     (check-true (regexp-match? (regexp (regexp-quote key)) env2))
     (check-false (regexp-match? (regexp (string-append (regexp-quote key) ":\\.")) env2)
                  "reshim honors the persisted keyed-only flag")))

  ;; --- Linking a real git checkout defaults to keyed-only -----------------
  (when git
    (with-temp-rackup-home (lambda (home)
                             (define src (build-path home "src-gitlink"))
                             (make-directory* src)
                             (make-fake-source-tree! src)
                             (parameterize ([current-output-port (open-output-string)]
                                            [current-error-port (open-output-string)])
                               (system* git "-C" (path->string src) "init" "-q"))
                             (link-toolchain! "gitlink" (path->string src) '("--set-default"))
                             (define id "local-gitlink")
                             (define meta (read-toolchain-meta id))
                             (check-equal? (hash-ref meta 'compiled-roots-scheme #f)
                                           'keyed-only
                                           "linking a git checkout defaults to keyed-only")
                             (check-equal? (config-roots src) (list (expected-key meta)))))))
