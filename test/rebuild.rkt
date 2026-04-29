#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-rebuild)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/rebuild.rkt"
         "../libexec/rackup/state.rkt")

(module+ test
  (define (with-temp-dir proc)
    (define dir (make-temporary-file "rackup-rebuild-test~a" 'directory))
    (dynamic-wind
     void
     (lambda () (proc dir))
     (lambda () (delete-directory/files dir #:must-exist? #f))))

  (define (write-empty-file! p)
    (with-output-to-file p (lambda () (display "")) #:exists 'replace))

  ;; rebuild-plan: package-based -> kind 'package-based, cwd source-root.
  (with-temp-dir
   (lambda (root)
     (define src-root (build-path root "checkout"))
     (define plthome (build-path src-root "racket"))
     (make-directory* plthome)
     (write-empty-file! (build-path src-root "Makefile"))
     (define plan
       (rebuild-plan (hasheq 'source-root (path->string src-root)
                             'plthome (path->string plthome)
                             'bin-dir (path->string (build-path plthome "bin")))))
     (check-equal? (hash-ref plan 'kind) 'package-based)
     (check-equal? (hash-ref plan 'cwd) (path->string src-root))
     (check-equal? (hash-ref plan 'reason) #f)))

  ;; source-root present, no Makefile -> 'unsupported with reason.
  (with-temp-dir
   (lambda (root)
     (define src-root (build-path root "checkout"))
     (define plthome (build-path src-root "racket"))
     (make-directory* plthome)
     (define plan
       (rebuild-plan (hasheq 'source-root (path->string src-root)
                             'plthome (path->string plthome)
                             'bin-dir (path->string (build-path plthome "bin")))))
     (check-equal? (hash-ref plan 'kind) 'unsupported)
     (check-true (regexp-match? #rx"no Makefile found at source root"
                                (hash-ref plan 'reason)))))

  ;; in-place: no source-root, Makefile at plthome -> 'in-place.
  (with-temp-dir
   (lambda (root)
     (define plthome (build-path root "build"))
     (make-directory* plthome)
     (write-empty-file! (build-path plthome "Makefile"))
     (define plan
       (rebuild-plan (hasheq 'source-root #f
                             'plthome (path->string plthome)
                             'bin-dir (path->string (build-path plthome "bin")))))
     (check-equal? (hash-ref plan 'kind) 'in-place)
     (check-equal? (hash-ref plan 'cwd) (path->string plthome))))

  ;; installed-prefix: no source-root, no Makefile -> unsupported.
  (with-temp-dir
   (lambda (root)
     (define plthome (build-path root "racket"))
     (make-directory* plthome)
     (define plan
       (rebuild-plan (hasheq 'source-root #f
                             'plthome (path->string plthome)
                             'bin-dir (path->string (build-path plthome "bin")))))
     (check-equal? (hash-ref plan 'kind) 'unsupported)
     (check-true (regexp-match? #rx"installed prefix"
                                (hash-ref plan 'reason)))))

  ;; End-to-end via cmd-rebuild against a synthetic linked toolchain.
  ;; Uses --dry-run to avoid spawning real make/git, plus a stubbed
  ;; system* for the one non-dry run.

  (define (write-script! p body)
    (with-output-to-file p (lambda () (display body)) #:exists 'replace)
    (file-or-directory-permissions p #o755))

  (define (make-fake-source-tree! root)
    (define plthome (build-path root "racket"))
    (define bin (build-path plthome "bin"))
    (make-directory* bin)
    (make-directory* (build-path plthome "collects"))
    (make-directory* (build-path root "pkgs"))
    (write-empty-file! (build-path root "Makefile"))
    (write-script! (build-path bin "racket")
                   (string-append
                    "#!/usr/bin/env bash\n"
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
    (define home (make-temporary-file "rackup-rebuild-home~a" 'directory))
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
     (define src (build-path home "src-tree"))
     (make-directory* src)
     (make-fake-source-tree! src)
     (link-toolchain! "rebuild-test" (path->string src) '("--set-default"))

     (define out
       (with-output-to-string
        (lambda ()
          (cmd-rebuild '("rebuild-test" "--dry-run" "-j" "3" "--" "CPUS=3" "PKGS=racket-lib")))))
     (check-true (regexp-match? #rx"\\+ cd " out))
     (check-true (regexp-match? #rx"make -j3 CPUS=3" out))
     (check-true (regexp-match? #rx"PKGS=racket-lib" out))
     (check-true (regexp-match? (regexp (path->string src)) out))

     (define out2
       (with-output-to-string
        (lambda () (cmd-rebuild '("--dry-run")))))
     (check-true (regexp-match? #rx"make -j" out2))

     (define out3
       (with-output-to-string
        (lambda () (cmd-rebuild '("rebuild-test" "--pull" "--dry-run")))))
     (check-true (regexp-match? #rx"git -C .* pull --ff-only" out3))

     (parameterize ([current-rebuild-system*-proc (lambda args #t)])
       (cmd-rebuild '("rebuild-test")))
     (define meta (read-toolchain-meta "local-rebuild-test"))
     (check-true (hash? meta))
     (check-equal? (hash-ref meta 'kind) 'local)
     (check-true (string? (hash-ref meta 'last-rebuilt-at #f)))
     (check-true (string? (hash-ref meta 'installed-at #f))))))
