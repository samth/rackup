#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-migrate)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/migrate.rkt"
         (submod "../libexec/rackup/migrate.rkt" for-testing)
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt")

(module+ test
  (define (with-temp-dir proc)
    (define dir (make-temporary-file "rackup-migrate-test~a" 'directory))
    (dynamic-wind
     void
     (lambda () (proc dir))
     (lambda () (delete-directory/files dir #:must-exist? #f))))

  (define (write-pkgs-db! addon version [db (hash)])
    (define pkgs (build-path addon version "pkgs"))
    (make-directory* pkgs)
    (call-with-output-file (build-path pkgs "pkgs.rktd") #:exists 'replace
      (lambda (out) (write db out))))

  (define (pkg-info orig-pkg [auto? #f])
    (make-prefab-struct 'pkg-info orig-pkg #f auto?))

  ;; ---- absolutize-orig-pkg / absolutize-pkg-info ----------------------

  (let ([base (string->path "/home/u/Library/Racket/9.1/pkgs")])
    ;; Relative link/static-link/clone paths become absolute; the source
    ;; spec's other fields (url) are preserved.
    (check-equal? (absolutize-orig-pkg '(link "../../../../code/x") base)
                  '(link "/home/u/code/x"))
    (check-equal? (absolutize-orig-pkg '(static-link "../../../../code/y") base)
                  '(static-link "/home/u/code/y"))
    (check-equal? (absolutize-orig-pkg '(clone "../../../../code/z" "git://h/z") base)
                  '(clone "/home/u/code/z" "git://h/z"))
    ;; Already-absolute paths are left intact.
    (check-equal? (absolutize-orig-pkg '(link "/abs/path") base)
                  '(link "/abs/path"))
    ;; Catalog/url/git specs (no local path) are untouched.
    (check-equal? (absolutize-orig-pkg '(catalog "foo" "git://h/foo") base)
                  '(catalog "foo" "git://h/foo"))
    (check-equal? (absolutize-orig-pkg '(url "https://h/u.zip") base)
                  '(url "https://h/u.zip"))
    ;; A derived prefab (sc-pkg-info: extra `collect` field) keeps its
    ;; subtype and trailing fields while orig-pkg (field 0) is rewritten.
    (define sc (make-prefab-struct '(sc-pkg-info pkg-info 3)
                                   '(link "../../../../code/x") "chk" #t "x"))
    (define sc* (absolutize-pkg-info sc base))
    (check-equal? (prefab-struct-key sc*) '(sc-pkg-info pkg-info 3))
    (check-equal? (vector->list (struct->vector sc*))
                  (list 'struct:sc-pkg-info '(link "/home/u/code/x") "chk" #t "x")))

  ;; ---- migrate-source-versions ----------------------------------------

  (with-temp-dir
   (lambda (root)
     (define addon (build-path root "native"))
     (write-pkgs-db! addon "9.1")
     (write-pkgs-db! addon "8.18")
     ;; A version dir with no pkgs.rktd is ignored.
     (make-directory* (build-path addon "junk"))
     ;; A plain file at the top level is ignored.
     (call-with-output-file (build-path addon "stray") (lambda (o) (display "x" o)))
     (check-equal? (migrate-source-versions addon) '("8.18" "9.1"))
     (check-equal? (migrate-source-versions (build-path root "missing")) '())))

  ;; ---- run-migrate! happy path (staging + cleanup) --------------------

  (define (with-fake-target home id proc)
    ;; A minimal target toolchain: just enough for resolve-executable-path
    ;; ("raco" must exist) and rackup-addon-dir.
    (define bin (build-path home "toolchains" id "bin"))
    (make-directory* bin)
    (call-with-output-file (build-path bin "raco") (lambda (o) (display "#!/bin/sh\n" o)))
    (file-or-directory-permissions (build-path bin "raco") #o755)
    (make-directory* (build-path home "addons" id))
    (proc))

  (define (with-temp-rackup-home proc)
    (define home (make-temporary-file "rackup-migrate-home~a" 'directory))
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
    (environment-variables-set! env #"RACKUP_TOOLCHAIN" #f)
    (dynamic-wind
     void
     (lambda ()
       (parameterize ([current-environment-variables env])
         (proc home)))
     (lambda () (delete-directory/files home #:must-exist? #f))))

  (with-temp-rackup-home
   (lambda (home)
     (with-fake-target home "tc"
       (lambda ()
         (define native (build-path home "native"))
         ;; Source db: a catalog package and a locally-linked package whose
         ;; source is stored relative to the source `pkgs` dir.
         (write-pkgs-db! native "9.1"
                         (hash "catpkg" (pkg-info '(catalog "catpkg"))
                               "linkpkg" (pkg-info '(link "../../../../somecode/linkpkg"))))
         (define staged-pkgs (build-path home "addons" "tc" "9.1" "pkgs" "pkgs.rktd"))
         (define captured (box #f))
         (define staged-during? (box #f))
         (define addon-during (box #f))
         (define staged-db (box #f))
         (define code
           (parameterize ([current-migrate-system*-proc
                           (lambda (exe . args)
                             (set-box! captured (cons (path->string exe) args))
                             (set-box! staged-during? (file-exists? staged-pkgs))
                             (set-box! addon-during (getenv "PLTADDONDIR"))
                             (set-box! staged-db (read-rktd-file staged-pkgs))
                             #t)])
             (define out (open-output-string))
             (parameterize ([current-output-port out])
               (run-migrate! #:target-id "tc"
                             #:source-addon native
                             #:from-version "9.1"
                             #:dry-run? #t))))
         (check-equal? code 0)
         ;; raco was invoked with the right pkg/migrate args.
         (define call (unbox captured))
         (check-true (regexp-match? #rx"/toolchains/tc/bin/raco$" (car call)))
         (check-equal? (cdr call) '("pkg" "migrate" "--dry-run" "9.1"))
         ;; The package db was staged into the target addon dir at call time.
         (check-true (unbox staged-during?))
         ;; PLTADDONDIR pointed at the target toolchain's addon dir.
         (check-equal? (unbox addon-during)
                       (path->string (rackup-addon-dir "tc")))
         ;; The staged db rewrote the link's relative path to absolute,
         ;; resolved against the *source* pkgs dir (so it survives the
         ;; depth change into the target addon dir).  raco pkg migrate would
         ;; otherwise resolve it against the dest dir and miss the directory.
         (define db (unbox staged-db))
         (define link-orig
           (let ([info (hash-ref db "linkpkg")])
             (car (cdr (vector->list (struct->vector info))))))
         (define expected
           (path->string
            (simplify-path
             (path->complete-path "../../../../somecode/linkpkg"
                                  (build-path native "9.1" "pkgs"))
             #f)))
         (check-equal? link-orig (list 'link expected))
         (check-true (complete-path? (string->path (cadr link-orig)))
                     "staged link path must be absolute")
         ;; Catalog packages are passed through untouched.
         (let ([info (hash-ref db "catpkg")])
           (check-equal? (car (cdr (vector->list (struct->vector info))))
                         '(catalog "catpkg")))
         ;; ...and the staging dir was cleaned up afterward.
         (check-false (directory-exists? (build-path home "addons" "tc" "9.1")))))))

  ;; ---- run-migrate! forwards extra args and propagates failure --------

  (with-temp-rackup-home
   (lambda (home)
     (with-fake-target home "tc"
       (lambda ()
         (define native (build-path home "native"))
         (write-pkgs-db! native "8.18")
         (define captured (box #f))
         (define code
           (parameterize ([current-migrate-system*-proc
                           (lambda (exe . args) (set-box! captured args) #f)])
             (parameterize ([current-output-port (open-output-string)])
               (run-migrate! #:target-id "tc"
                             #:source-addon native
                             #:from-version "8.18"
                             #:extra-args '("--no-cache")))))
         ;; Non-zero exit code is propagated from a failed raco run.
         (check-equal? code 1)
         ;; Pass-through args land before <from-version>.
         (check-equal? (unbox captured) '("pkg" "migrate" "--no-cache" "8.18"))))))

  ;; ---- run-migrate! errors -------------------------------------------

  (with-temp-rackup-home
   (lambda (home)
     (with-fake-target home "tc"
       (lambda ()
         (define native (build-path home "native"))
         (write-pkgs-db! native "9.1")
         (write-pkgs-db! native "8.18")
         ;; Missing source version lists what *is* available.
         (check-exn
          (lambda (e)
            (and (exn:fail? e)
                 (regexp-match? #rx"no package database for version" (exn-message e))
                 (regexp-match? #rx"8.18, 9.1" (exn-message e))))
          (lambda ()
            (parameterize ([current-output-port (open-output-string)])
              (run-migrate! #:target-id "tc"
                            #:source-addon native
                            #:from-version "9.9"))))
         ;; A pre-existing staging dir is refused rather than clobbered.
         (make-directory* (build-path home "addons" "tc" "9.1"))
         (check-exn
          (lambda (e)
            (and (exn:fail? e)
                 (regexp-match? #rx"already exists" (exn-message e))))
          (lambda ()
            (parameterize ([current-output-port (open-output-string)])
              (run-migrate! #:target-id "tc"
                            #:source-addon native
                            #:from-version "9.1"))))))))

  ;; ---- end-to-end cmd-migrate (arg parsing) ---------------------------

  (define (write-script! p body)
    (with-output-to-file p (lambda () (display body)) #:exists 'replace)
    (file-or-directory-permissions p #o755))

  (define (make-fake-source-tree! root)
    (define plthome (build-path root "racket"))
    (define bin (build-path plthome "bin"))
    (make-directory* bin)
    (make-directory* (build-path plthome "collects"))
    (make-directory* (build-path root "pkgs"))
    (with-output-to-file (build-path root "Makefile") (lambda () (display "")) #:exists 'replace)
    (write-script! (build-path bin "racket")
                   (string-append
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    "if [[ \"$#\" -ge 2 && \"$1\" == \"-e\" ]]; then\n"
                    "  if [[ \"$2\" == *\"(version)\"*\"system-type\"*\"find-system-path\"* ]]; then\n"
                    "    printf '9.99-migrate\\nchez-scheme\\n%s' \"${PLTADDONDIR:-/tmp/x}\"\n"
                    "    exit 0\n"
                    "  fi\n"
                    "fi\n"
                    "exit 1\n"))
    (write-script! (build-path bin "raco") "#!/usr/bin/env bash\nexit 0\n"))

  (with-temp-rackup-home
   (lambda (home)
     (define src (build-path home "src-tree"))
     (make-directory* src)
     (make-fake-source-tree! src)
     (link-toolchain! "mig-test" (path->string src) '("--set-default"))
     (define native (build-path home "native"))
     (write-pkgs-db! native "9.1")

     ;; Default target = active toolchain; --from-addon + --dry-run.
     (define captured (box #f))
     (parameterize ([current-migrate-system*-proc
                     (lambda (exe . args) (set-box! captured args) #t)])
       (parameterize ([current-output-port (open-output-string)])
         (cmd-migrate (list "9.1" "--from-addon" (path->string native) "--dry-run"))))
     (check-equal? (unbox captured) '("pkg" "migrate" "--dry-run" "9.1"))

     ;; Positional <from-version> may appear before flags (reorder-args),
     ;; and trailing args after -- pass through to raco.
     (define captured2 (box #f))
     (parameterize ([current-migrate-system*-proc
                     (lambda (exe . args) (set-box! captured2 args) #t)])
       (parameterize ([current-output-port (open-output-string)])
         (cmd-migrate (list "--from-addon" (path->string native) "9.1" "--" "--no-cache"))))
     (check-equal? (unbox captured2) '("pkg" "migrate" "--no-cache" "9.1"))

     ;; The native-addon detection seam is used when no source flag is given.
     (define native2 (build-path home "native2"))
     (write-pkgs-db! native2 "8.18")
     (define captured3 (box #f))
     (parameterize ([current-native-addon-dir-proc (lambda (_id) native2)]
                    [current-migrate-system*-proc
                     (lambda (exe . args) (set-box! captured3 args) #t)])
       (parameterize ([current-output-port (open-output-string)])
         (cmd-migrate (list "8.18"))))
     (check-equal? (unbox captured3) '("pkg" "migrate" "8.18")))))
