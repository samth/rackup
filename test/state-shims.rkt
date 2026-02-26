#lang racket/base

(require rackunit
         racket/file
         racket/port
         racket/path
         racket/string
         racket/system
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shell.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt")

(define (with-temp-rackup-home proc)
  (define tmp (make-temporary-file "rackup-test~a" 'directory))
  (define old-home (getenv "RACKUP_HOME"))
  (dynamic-wind
   (lambda ()
     (putenv "RACKUP_HOME" (path->string tmp)))
   (lambda ()
     (proc tmp))
   (lambda ()
     (if old-home
         (putenv "RACKUP_HOME" old-home)
         (putenv "RACKUP_HOME" ""))
     (delete-directory/files tmp #:must-exist? #f))))

(module+ test
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (check-true (directory-exists? (rackup-home)))
     (check-equal? (installed-toolchain-ids) null)

     (define id "release-8.18-cs-x86_64-linux-full")
     (define tc-dir (rackup-toolchain-dir id))
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
     (file-or-directory-permissions racket-exe #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))

     (define meta
       (hash 'id id
             'kind 'release
             'requested-spec "stable"
             'resolved-version "8.18"
             'variant 'cs
             'distribution 'full
             'arch "x86_64"
             'platform "linux"
             'snapshot-site #f
             'snapshot-stamp #f
             'installer-url "https://example.invalid/racket.sh"
             'installer-filename "racket.sh"
             'install-root (path->string install-root)
             'bin-link (path->string (rackup-toolchain-bin-link id))
             'real-bin-dir (path->string real-bin)
             'executables '("racket")
             'installed-at "2026-02-26T00:00:00Z"))
     (register-toolchain! id meta)
     (check-equal? (get-default-toolchain) id)
     (check-equal? (find-local-toolchain "release-8.18") id)
     (check-equal? (path->string (resolve-executable-path "racket"))
                   (path->string (build-path (rackup-toolchain-bin-link id) "racket")))

     (reshim!)
     (check-true (link-exists? (build-path (rackup-shims-dir) "racket")))
     (check-true (link-exists? (build-path (rackup-shims-dir) "rackup")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define src-root (build-path tmp "fake-src"))
     (define plthome (build-path src-root "racket"))
     (define bin-dir (build-path plthome "bin"))
     (define collects-dir (build-path plthome "collects"))
     (define pkgs-dir (build-path src-root "pkgs"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)

     (define (write-exe name body)
       (define p (build-path bin-dir name))
       (write-string-file p body)
       (file-or-directory-permissions p #o755)
       p)

     (write-exe
      "racket"
      (string-append
       "#!/usr/bin/env bash\n"
       "set -euo pipefail\n"
       "if [[ \"$#\" -ge 2 && \"$1\" == \"-e\" ]]; then\n"
       "  case \"$2\" in\n"
       "    *\"(version)\"*) printf '9.99-local'; exit 0 ;;\n"
       "    *\"system-type 'vm\"*) printf 'cs'; exit 0 ;;\n"
       "  esac\n"
       "fi\n"
       "printf 'PLTHOME=%s\\n' \"${PLTHOME:-}\"\n"
       "printf 'PLTCOLLECTS=%s\\n' \"${PLTCOLLECTS:-}\"\n"
       "printf 'PLTADDONDIR=%s\\n' \"${PLTADDONDIR:-}\"\n"
       "printf 'ARGS=%s\\n' \"$*\"\n"))
     (write-exe
      "raco"
      (string-append
       "#!/usr/bin/env bash\n"
       "set -euo pipefail\n"
       "printf 'raco-ok\\n'\n"))

     (define linked-id (link-toolchain! "devsrc" (path->string src-root) '("--set-default")))
     (check-equal? linked-id "local-devsrc")
     (check-equal? (find-local-toolchain "devsrc") linked-id)
     (check-equal? (find-local-toolchain linked-id) linked-id)

     (define linked-meta (read-toolchain-meta linked-id))
     (check-equal? (hash-ref linked-meta 'kind) 'local)
     (check-equal? (hash-ref linked-meta 'distribution) 'in-place)
     (check-equal? (hash-ref linked-meta 'plthome) (path->string plthome))
     (check-not-false (member "racket" (hash-ref linked-meta 'executables)))
     (check-true (file-exists? (rackup-toolchain-env-file linked-id)))

     (define shim-racket (build-path (rackup-shims-dir) "racket"))
     (define old-pltaddon (getenv "PLTADDONDIR"))
     (void (putenv "PLTADDONDIR" ""))
     (define shim-out
       (parameterize ([current-output-port (open-output-string)]
                      [current-error-port (open-output-string)])
         (define out (current-output-port))
         (check-true (system* shim-racket))
         (get-output-string out)))
     (void (if old-pltaddon (putenv "PLTADDONDIR" old-pltaddon) (putenv "PLTADDONDIR" "")))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTHOME=~a" (path->string plthome)))) shim-out))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTCOLLECTS=~a:~a"
                                                              (path->string collects-dir)
                                                              (path->string pkgs-dir))))
                                shim-out))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTADDONDIR=~a"
                                                              (path->string (rackup-addon-dir linked-id)))))
                                shim-out))

     (define activation (emit-shell-activation linked-id))
     (check-true (string-contains? activation "export PLTHOME="))
     (check-true (string-contains? activation "export PLTCOLLECTS="))
     (void (putenv "RACKUP_TOOLCHAIN" linked-id))
     (define deactivation (emit-shell-deactivation))
     (check-true (string-contains? deactivation "unset PLTHOME"))
     (check-true (string-contains? deactivation "unset PLTCOLLECTS"))
     (void (putenv "RACKUP_TOOLCHAIN" "")))))
