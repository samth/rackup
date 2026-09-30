#lang racket/base

;; Consistency tests: the bash shim, `rackup run`, `rackup rebuild`, and
;; reshim must compute the same toolchain environment and executables.
;; Each block pins one previously divergent pair of code paths.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-rebuild)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rebuild.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt")

(define-runtime-path rackup-bin "../bin/rackup")

(define (write-script! p body)
  (write-string-file p body)
  (file-or-directory-permissions p #o755))

(define print-env-body
  (string-append "#!/usr/bin/env bash\n"
                 "printf 'PLTADDONDIR=%s\\nPLTCOMPILEDROOTS=%s\\n' "
                 "\"${PLTADDONDIR:-}\" \"${PLTCOMPILEDROOTS:-}\"\n"))

;; A fake in-place source tree whose `racket` answers rackup's probe.
(define (make-fake-source-tree! root)
  (define plthome (build-path root "racket"))
  (define bin (build-path plthome "bin"))
  (make-directory* bin)
  (make-directory* (build-path plthome "collects"))
  (make-directory* (build-path root "pkgs"))
  (write-string-file (build-path root "Makefile") "")
  (write-script! (build-path bin "racket")
                 (string-append
                  "#!/usr/bin/env bash\n"
                  "if [[ \"$#\" -ge 2 && \"$1\" == \"-e\" ]]; then\n"
                  "  if [[ \"$2\" == *\"(version)\"*\"system-type\"*\"find-system-path\"* ]]; then\n"
                  "    printf '9.99-env\\nchez-scheme\\n/tmp/x'\n"
                  "    exit 0\n"
                  "  fi\n"
                  "fi\n"
                  "exit 1\n"))
  (write-script! (build-path bin "raco") "#!/usr/bin/env bash\nexit 0\n")
  (write-script! (build-path bin "print-env") print-env-body))

;; A clean rackup home, with none of the Racket or rackup variables that
;; these tests set explicitly.  RACKUP_TESTING stays unset so link/rebuild
;; take the real (non-test) code paths against throwaway trees.
(define (with-temp-rackup-home proc)
  (define home (make-temporary-file "rackup-envcons~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
  (for ([v (in-list '(#"RACKUP_TOOLCHAIN" #"RACKUP_TESTING" #"PLTADDONDIR"
                      #"PLTCOMPILEDROOTS" #"_RACKUP_MANAGED_PLTCOMPILEDROOTS"))])
    (environment-variables-set! env v #f))
  (dynamic-wind
   void
   (lambda () (parameterize ([current-environment-variables env]) (proc home)))
   (lambda () (delete-directory/files home #:must-exist? #f))))

;; Run a program with extra environment bindings; return (list status
;; stdout stderr).
(define (run cmd #:env [extra '()] . args)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([kv (in-list extra)])
    (environment-variables-set! env (car kv) (cdr kv)))
  (define out (open-output-string))
  (define err (open-output-string))
  (define status
    (parameterize ([current-environment-variables env]
                   [current-output-port out]
                   [current-error-port err])
      (apply system*/exit-code cmd args)))
  (list status (get-output-string out) (get-output-string err)))

(define (shim name)
  (path->string (build-path (rackup-shims-dir) name)))

(define (quietly thunk)
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (thunk)))

(define (link-fake! home name)
  (define src (build-path home (string-append "src-" name)))
  (make-directory* src)
  (make-fake-source-tree! src)
  (quietly (lambda () (link-toolchain! name (path->string src) '("--set-default"))))
  src)

(define (linked-key id)
  (define meta (read-toolchain-meta id))
  (compiled-roots-key (hash-ref meta 'resolved-version #f)
                      (hash-ref meta 'variant #f)
                      (hash-ref meta 'requested-spec #f)))

(define installer-id "release-9.1-cs-x86_64-linux-full")

;; An installer-style toolchain whose bin holds print-env, set as default.
(define (setup-installer-toolchain!)
  (ensure-index!)
  (define real-bin (build-path (rackup-toolchain-install-dir installer-id) "bin"))
  (make-directory* real-bin)
  (write-script! (build-path real-bin "print-env") print-env-body)
  (make-file-or-directory-link real-bin (rackup-toolchain-bin-link installer-id))
  (with-state-lock
    (register-toolchain! installer-id
                         (hash 'id installer-id 'kind 'release 'requested-spec "9.1"
                               'resolved-version "9.1" 'variant 'cs 'distribution 'full
                               'arch "x86_64" 'platform "linux"
                               'executables '("print-env")
                               'installed-at "2026-03-01T00:00:00Z"))
    (set-default-toolchain! installer-id)
    (reshim!)))

(module+ test
  (define make-exe (find-executable-path "make"))

  ;; --- #1: rebuild's `make` uses the managed addon dir ---------------------
  ;; bin/rackup clears PLTADDONDIR, so the build's `raco setup` used to fall
  ;; back to the native addon dir and miss packages the shim sees.
  (when make-exe
    (with-temp-rackup-home
     (lambda (home)
       (link-fake! home "addon1")
       (define seen 'make-not-run)
       (parameterize ([current-rebuild-system*-proc
                       (lambda (exe . _args)
                         (when (equal? exe make-exe)
                           (set! seen (getenv "PLTADDONDIR")))
                         #t)])
         (quietly (lambda () (cmd-rebuild '("addon1")))))
       (check-equal? seen (path->string (rackup-addon-dir "local-addon1"))
                     "rebuild's make sees the managed addon dir"))))

  ;; --- #2: a failed make leaves meta, env.sh and config.rktd consistent -
  ;; An older rackup could leave config.rktd keyed-only while meta and env.sh
  ;; stayed on `key:.`.  rebuild now removes the keyed-only entry before
  ;; `make`, so a failed build leaves every caller on `key:.`.
  (when make-exe
    (with-temp-rackup-home
     (lambda (home)
       (define src (link-fake! home "failmake"))
       (define id "local-failmake")
       (define key (linked-key id))
       (define cfg-path (build-path src "racket" "etc" "config.rktd"))
       (make-directory* (build-path src "racket" "etc"))
       (write-rktd-file cfg-path (hash 'compiled-file-roots (list key)))
       (check-exn exn:fail?
                  (lambda ()
                    (parameterize ([current-rebuild-system*-proc
                                    (lambda (exe . _args) (not (equal? exe make-exe)))])
                      (quietly (lambda () (cmd-rebuild '("failmake"))))))
                  "stubbed make fails")
       (check-false (hash-ref (read-rktd-file cfg-path #f) 'compiled-file-roots #f)
                    "config.rktd no longer names only the key")
       (check-true (string-contains? (file->string (rackup-toolchain-env-file id))
                                     (string-append key "/@(version):."))
                   "env.sh keeps the `.` fallback"))))

  ;; --- #3: env.sh gives PLTCOMPILEDROOTS the same precedence as rackup run -
  (with-temp-rackup-home
   (lambda (home)
     (make-directory* (rackup-toolchain-dir installer-id))
     (write-toolchain-env-file! installer-id
                                (list (cons "PLTCOMPILEDROOTS" "compiled/9.1-cs:.")))
     (define script
       (format ". '~a'; printf '%s|%s' \"${PLTCOMPILEDROOTS:-}\" \"${_RACKUP_MANAGED_PLTCOMPILEDROOTS:-}\""
               (path->string (rackup-toolchain-env-file installer-id))))
     (define (sourced extra)
       (second (run (find-executable-path "bash") "-c" script #:env extra)))
     (check-equal? (sourced '()) "compiled/9.1-cs:.|compiled/9.1-cs:."
                   "unset: toolchain value, recorded in the marker")
     (check-equal? (sourced (list (cons #"PLTCOMPILEDROOTS" #"user-choice")))
                   "user-choice|"
                   "a user-set value wins")
     (check-equal? (sourced (list (cons #"PLTCOMPILEDROOTS" #"compiled/other:.")
                                  (cons #"_RACKUP_MANAGED_PLTCOMPILEDROOTS" #"compiled/other:.")))
                   "compiled/9.1-cs:.|compiled/9.1-cs:."
                   "a value an enclosing rackup launch exported is replaced")))

  ;; --- #4: the shim ignores an inherited PLTADDONDIR ----------------------
  ;; Installer toolchains have no PLTADDONDIR in env.sh; the dispatcher used
  ;; to keep the shell's value, unlike rackup run/which/reshim/upgrade.
  (with-temp-rackup-home
   (lambda (home)
     (setup-installer-toolchain!)
     (define r (run (shim "print-env") #:env (list (cons #"PLTADDONDIR" #"/tmp/elsewhere"))))
     (check-equal? (first r) 0)
     (check-true (string-contains?
                  (second r)
                  (format "PLTADDONDIR=~a\n" (path->string (rackup-addon-dir installer-id))))
                 "shim uses the managed addon dir")))

  ;; --- #5: reshim keeps a linked toolchain's bin overlay in sync ----------
  (with-temp-rackup-home
   (lambda (home)
     (define src (link-fake! home "overlay"))
     (define id "local-overlay")
     (define real-bin (build-path src "racket" "bin"))
     (define overlay-entry (build-path (rackup-toolchain-bin-link id) "newtool"))
     (write-script! (build-path real-bin "newtool") "#!/usr/bin/env bash\necho newtool-ran\n")
     (with-state-lock (reshim!))
     (check-true (link-exists? overlay-entry) "new real-bin executable linked into overlay")
     (check-not-false (member "newtool" (hash-ref (read-toolchain-meta id) 'executables)))
     (check-true (link-exists? (build-path (rackup-shims-dir) "newtool")) "and shimmed")
     (define r (run (shim "newtool")))
     (check-equal? (first r) 0)
     (check-equal? (second r) "newtool-ran\n")
     (delete-file (build-path real-bin "newtool"))
     (with-state-lock (reshim!))
     (check-false (link-exists? overlay-entry) "dangling overlay link removed")
     (check-false (member "newtool" (hash-ref (read-toolchain-meta id) 'executables)))
     (check-false (link-exists? (build-path (rackup-shims-dir) "newtool")) "and unshimmed")))

  ;; --- #7: the shim and rackup agree on the active toolchain --------------
  (with-temp-rackup-home
   (lambda (home)
     (setup-installer-toolchain!)
     (define (status . extra) (first (run (shim "print-env") #:env extra)))
     ;; `rackup prompt` is answered by shell code in bin/rackup, a third
     ;; reader of the active toolchain.
     (define (prompt . extra) (second (run rackup-bin "prompt" "--raw" #:env extra)))
     (write-string-file (rackup-default-file) (format "  ~a  \n\n" installer-id))
     (check-equal? (get-default-toolchain) installer-id)
     (check-equal? (status) 0 "default file with surrounding whitespace")
     (check-equal? (string-trim (prompt)) installer-id)
     (check-equal? (status (cons #"RACKUP_TOOLCHAIN" #"   ")) 0
                   "whitespace-only RACKUP_TOOLCHAIN means the default")
     (check-equal? (string-trim (prompt (cons #"RACKUP_TOOLCHAIN" #"   "))) installer-id)
     (write-string-file (rackup-default-file) "not a valid id!")
     (check-false (get-default-toolchain))
     (check-equal? (prompt) "" "prompt shows nothing for an invalid default")
     (define r (run (shim "print-env")))
     (check-equal? (first r) 2 "invalid default means no active toolchain in the shim too")
     (check-true (string-contains? (third r) "no active toolchain is configured"))
     ;; A default recorded only in the index (older rackup) migrates to the
     ;; file, the one place the shim reads.
     (delete-file (rackup-default-file))
     (save-index! (hash-set (load-index) 'default-toolchain installer-id))
     (check-false (get-default-toolchain) "rackup reads only the file, like the shim")
     (void (ensure-index!))
     (check-equal? (get-default-toolchain) installer-id)
     (check-equal? (status) 0 "shim sees the migrated default"))))
