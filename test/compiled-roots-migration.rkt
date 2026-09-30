#lang racket/base

;; Upgrade-path and rebuild tests for a linked toolchain's keyed compiled
;; dirs.  Earlier rackup versions wrote the key as the sole root in the
;; tree's config.rktd ("keyed-only"); reshim, link, and rebuild now undo
;; that.  Linked toolchains' roots are `<key>/@(version)`, and `rackup
;; rebuild` prunes the keyed dirs of other versions from the source tree.
;; Steady-state unit tests live in test/compiled-roots.rkt.

(require rackunit
         racket/file
         racket/string
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-rebuild)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rebuild.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt")

(define (write-script! p body)
  (with-output-to-file p (lambda () (display body)) #:exists 'replace)
  (file-or-directory-permissions p #o755))

;; A fake in-place source tree whose `racket` answers rackup's
;; version/variant/addon probe with the version stored in racket/VERSION,
;; so a test can simulate a version bump.
(define (make-fake-source-tree! root [version "9.99.0.1"])
  (define plthome (build-path root "racket"))
  (define bin (build-path plthome "bin"))
  (make-directory* bin)
  (make-directory* (build-path plthome "collects"))
  (make-directory* (build-path root "pkgs"))
  (write-string-file (build-path root "Makefile") "")
  (set-fake-version! root version)
  (write-script!
   (build-path bin "racket")
   (string-append "#!/usr/bin/env bash\n"
                  "set -euo pipefail\n"
                  "if [[ \"$#\" -ge 2 && \"$1\" == \"-f\" ]]; then\n"
                  "  printf '(\"%s\" chez-scheme \"/tmp/x\")' \"$(cat \"$(dirname \"$0\")/../VERSION\")\"\n"
                  "  exit 0\n"
                  "fi\n"
                  "exit 1\n"))
  (write-script! (build-path bin "raco") "#!/usr/bin/env bash\nexit 0\n"))

(define (set-fake-version! root version)
  (write-string-file (build-path root "racket" "VERSION") version))

(define (write-string-file p s)
  (with-output-to-file p (lambda () (display s)) #:exists 'replace))

(define (with-temp-rackup-home proc)
  (define home (make-temporary-file "rackup-croots-mig~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
  (for ([v (in-list '(#"RACKUP_TOOLCHAIN" #"RACKUP_TESTING" #"PLTCOMPILEDROOTS"
                      #"_RACKUP_ORIG_PLTCOMPILEDROOTS"))])
    (environment-variables-set! env v #f))
  (dynamic-wind void
                (lambda ()
                  (parameterize ([current-environment-variables env])
                    (proc home)))
                (lambda () (delete-directory/files home #:must-exist? #f))))

(define (quietly thunk)
  (parameterize ([current-output-port (open-output-string)]
                 [current-error-port (open-output-string)])
    (thunk)))

(define (config-path src)
  (build-path src "racket" "etc" "config.rktd"))

(define (config src)
  (read-rktd-file (config-path src) #f))

(define (linked-key id)
  (define meta (read-toolchain-meta id))
  (compiled-roots-key (hash-ref meta 'resolved-version #f)
                      (hash-ref meta 'variant #f)
                      (hash-ref meta 'requested-spec #f)))

(define (link-fake! home name)
  (define src (build-path home (string-append "src-" name)))
  (make-directory* src)
  (make-fake-source-tree! src)
  (quietly (lambda () (link-toolchain! name (path->string src) '("--set-default"))))
  src)

;; Places where `raco setup` through the shim would write keyed `.zo`.
(define (keyed-dirs src key)
  (list (build-path src "racket" "collects" "racket" key)
        (build-path src "pkgs" "racket-lib" "racket" "private" key)
        (build-path src "pkgs" "base" key)))

;; Give each keyed dir a version subdir holding a fake `.zo`; with
;; version #f, write the version-less layout of earlier rackup releases.
(define (populate-keyed-dirs! src key version)
  (for ([d (in-list (keyed-dirs src key))])
    (define c (if version (build-path d version "compiled") (build-path d "compiled")))
    (make-directory* c)
    (write-string-file (build-path c "base_rkt.zo") "zo")))

;; The sorted entries of each keyed dir.
(define (keyed-contents src key)
  (for/list ([d (in-list (keyed-dirs src key))])
    (if (directory-exists? d)
        (sort (map path->string (directory-list d)) string<?)
        'missing)))

(define (env-sh id)
  (file->string (rackup-toolchain-env-file id)))

(define (rebuild! name #:make-ok? [make-ok? #t])
  (parameterize ([current-rebuild-system*-proc
                  (lambda (exe . args)
                    (or make-ok? (not (regexp-match? #rx"make$" (path->string exe)))))])
    (quietly (lambda () (cmd-rebuild (list name))))))

(module+ test
  ;; --- prune-keyed-compiled-dirs! ------------------------------------------
  ;; Empties every `<dir>/<key>` except the kept version, anywhere under the
  ;; root except inside `.git` and `compiled/` dirs; leaves the default
  ;; `compiled/` and other keys alone.
  (let ([root (make-temporary-file "rackup-prune~a" 'directory)])
    (define key "compiled/cs-local-dev")
    (define (mk . parts)
      (define d (apply build-path root parts))
      (make-directory* d)
      d)
    (mk "a" "compiled" "cs-local-dev" "9.1" "compiled")
    (mk "a" "compiled" "cs-local-dev" "9.2" "compiled")
    (mk "a" "compiled" "cs-local-dev" "compiled")
    (mk "a" "b" "c" "compiled" "cs-local-dev" "9.1")
    (mk ".git" "x" "compiled" "cs-local-dev" "9.1")
    (mk "a" "compiled" "cs-local-other" "9.1")
    (write-string-file (build-path (mk "a" "compiled") "m_rkt.zo") "fresh")
    (check-equal? (prune-keyed-compiled-dirs! root key "9.2") 3)
    (check-equal? (directory-list (build-path root "a" "compiled" "cs-local-dev"))
                  (list (string->path "9.2"))
                  "the kept version survives; old versions and the legacy layout go")
    (check-equal? (directory-list (build-path root "a" "b" "c" "compiled" "cs-local-dev")) '())
    (check-true (directory-exists? (build-path root ".git" "x" "compiled" "cs-local-dev" "9.1"))
                ".git is skipped")
    (check-true (directory-exists? (build-path root "a" "compiled" "cs-local-other" "9.1"))
                "another toolchain's key is kept")
    (check-true (file-exists? (build-path root "a" "compiled" "m_rkt.zo"))
                "the default compiled dir is kept")
    (check-equal? (prune-keyed-compiled-dirs! root key "9.2") 0 "idempotent")
    (delete-directory/files root))

  ;; --- Upgrade: reshim undoes a keyed-only migration ------------------------
  ;; The state an older rackup left: config.rktd names only the key and meta
  ;; carries 'compiled-roots-scheme 'keyed-only.
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "undo"))
     (define id "local-undo")
     (define key (linked-key id))
     (make-directory* (build-path src "racket" "etc"))
     (write-rktd-file (config-path src)
                      (hash 'compiled-file-roots (list key)
                            'installation-name "development"))
     (write-toolchain-meta! id (hash-set (read-toolchain-meta id)
                                         'compiled-roots-scheme 'keyed-only))
     (quietly (lambda () (with-state-lock (reshim!))))
     (check-false (hash-ref (config src) 'compiled-file-roots #f)
                  "reshim removes the keyed root from config.rktd")
     (check-equal? (hash-ref (config src) 'installation-name #f) "development"
                   "other config keys survive")
     (check-false (hash-ref (read-toolchain-meta id) 'compiled-roots-scheme #f)
                  "reshim drops the keyed-only flag")
     (check-true (string-contains? (env-sh id) (string-append key "/@(version):."))
                 "env.sh gets the versioned root and the `.` fallback")))

  ;; --- Reshim leaves a user's own compiled-file-roots alone ---------------
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "custom"))
     (make-directory* (build-path src "racket" "etc"))
     (write-rktd-file (config-path src) (hash 'compiled-file-roots '("/custom/abs")))
     (quietly (lambda () (with-state-lock (reshim!))))
     (check-equal? (hash-ref (config src) 'compiled-file-roots #f) '("/custom/abs"))))

  ;; --- Rebuild undoes keyed-only before `make` ------------------------------
  ;; The build's later steps read the tree's config.rktd, so the entry must
  ;; be gone by the time `make` runs.
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "premake"))
     (define key (linked-key "local-premake"))
     (make-directory* (build-path src "racket" "etc"))
     (write-rktd-file (config-path src) (hash 'compiled-file-roots (list key)))
     (define roots-at-make 'make-not-run)
     (parameterize ([current-rebuild-system*-proc
                     (lambda (exe . args)
                       (when (regexp-match? #rx"make$" (path->string exe))
                         (set! roots-at-make (hash-ref (config src) 'compiled-file-roots #f)))
                       #t)])
       (quietly (lambda () (cmd-rebuild '("premake")))))
     (check-false roots-at-make "make ran without the keyed root in config.rktd")))

  ;; --- Rebuild prunes the keyed dirs of other versions ---------------------
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "prune"))
     (define id "local-prune")
     (define key (linked-key id))
     (define default-zo (build-path src "racket" "collects" "racket" "compiled" "base_rkt.zo"))
     (make-directory* (build-path src "racket" "collects" "racket" "compiled"))
     (write-string-file default-zo "fresh")
     ;; The version-less layout of an earlier rackup, plus an older version.
     (populate-keyed-dirs! src key #f)
     (populate-keyed-dirs! src key "9.99.0.0")
     (populate-keyed-dirs! src key "9.99.0.1")
     (rebuild! "prune")
     (check-equal? (keyed-contents src key) '(("9.99.0.1") ("9.99.0.1") ("9.99.0.1"))
                   "rebuild keeps only the current version's dir")
     (check-true (file-exists? default-zo) "default compiled dir untouched")
     ;; Version bump (as after `git pull`): the old version's dir goes.
     (set-fake-version! src "9.99.0.2")
     (populate-keyed-dirs! src key "9.99.0.2")
     (rebuild! "prune")
     (check-equal? (keyed-contents src key) '(("9.99.0.2") ("9.99.0.2") ("9.99.0.2")))
     (check-true (string-contains? (env-sh id) (string-append key "/@(version):."))
                 "env.sh keeps the versioned root with the `.` fallback")))

  ;; --- A failed `make` still prunes after a version bump --------------------
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "failprune"))
     (define key (linked-key "local-failprune"))
     (populate-keyed-dirs! src key "9.99.0.1")
     (set-fake-version! src "9.99.0.3")
     (check-exn exn:fail? (lambda () (rebuild! "failprune" #:make-ok? #f)))
     (check-equal? (keyed-contents src key) '(() () ())
                   "failed make after a bump still prunes the old version"))))
