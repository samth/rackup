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
         "../libexec/rackup/runtime.rkt"
         "../libexec/rackup/shell.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt")

(define (with-temp-rackup-home proc)
  (define tmp (make-temporary-file "rackup-test~a" 'directory))
  (define old-home (getenv "RACKUP_HOME"))
  (dynamic-wind (lambda () (putenv "RACKUP_HOME" (path->string tmp)))
                (lambda () (proc tmp))
                (lambda ()
                  (if old-home
                      (putenv "RACKUP_HOME" old-home)
                      (putenv "RACKUP_HOME" ""))
                  (delete-directory/files tmp #:must-exist? #f))))

(module+ test
  (with-temp-rackup-home (lambda (tmp)
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
                             (hash 'id
                                   id
                                   'kind
                                   'release
                                   'requested-spec
                                   "stable"
                                   'resolved-version
                                   "8.18"
                                   'variant
                                   'cs
                                   'distribution
                                   'full
                                   'arch
                                   "x86_64"
                                   'platform
                                   "linux"
                                   'snapshot-site
                                   #f
                                   'snapshot-stamp
                                   #f
                                   'installer-url
                                   "https://example.invalid/racket.sh"
                                   'installer-filename
                                   "racket.sh"
                                   'install-root
                                   (path->string install-root)
                                   'bin-link
                                   (path->string (rackup-toolchain-bin-link id))
                                   'real-bin-dir
                                   (path->string real-bin)
                                   'executables
                                   '("racket")
                                   'installed-at
                                   "2026-02-26T00:00:00Z"))
                           (register-toolchain! id meta)
                           (check-equal? (get-default-toolchain) id)
                           (check-equal? (find-local-toolchain "release-8.18") id)
                           (check-equal? (path->string (resolve-executable-path "racket"))
                                         (path->string (build-path (rackup-toolchain-bin-link id)
                                                                   "racket")))

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
     (define chez-bin-dir
       (build-path src-root "racket" "src" "build" "cs" "c" "ChezScheme" "pb" "bin" "pb"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)
     (make-directory* chez-bin-dir)

     (define (write-exe name body)
       (define p (build-path bin-dir name))
       (write-string-file p body)
       (file-or-directory-permissions p #o755)
       p)

     (write-exe "racket"
                (string-append "#!/usr/bin/env bash\n"
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
     (write-exe "raco"
                (string-append "#!/usr/bin/env bash\n" "set -euo pipefail\n" "printf 'raco-ok\\n'\n"))
     (for ([name '("scheme" "petite")])
       (define p (build-path chez-bin-dir name))
       (write-string-file p
                          (string-append "#!/usr/bin/env bash\n"
                                         "set -euo pipefail\n"
                                         "printf '"
                                         name
                                         "-ok %s\\n' \"$*\"\n"))
       (file-or-directory-permissions p #o755))

     (define linked-id (link-toolchain! "devsrc" (path->string src-root) '("--set-default")))
     (check-equal? linked-id "local-devsrc")
     (check-equal? (find-local-toolchain "devsrc") linked-id)
     (check-equal? (find-local-toolchain linked-id) linked-id)

     (define linked-meta (read-toolchain-meta linked-id))
     (check-equal? (hash-ref linked-meta 'kind) 'local)
     (check-equal? (hash-ref linked-meta 'distribution) 'in-place)
     (check-equal? (hash-ref linked-meta 'plthome) (path->string plthome))
     (check-not-false (member "racket" (hash-ref linked-meta 'executables)))
     (check-not-false (member "scheme" (hash-ref linked-meta 'executables)))
     (check-not-false (member "petite" (hash-ref linked-meta 'executables)))
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
     (void (if old-pltaddon
               (putenv "PLTADDONDIR" old-pltaddon)
               (putenv "PLTADDONDIR" "")))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTHOME=~a" (path->string plthome))))
                                shim-out))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTCOLLECTS=~a:~a"
                                                              (path->string collects-dir)
                                                              (path->string pkgs-dir))))
                                shim-out))
     (check-true (regexp-match?
                  (regexp (regexp-quote (format "PLTADDONDIR=~a"
                                                (path->string (rackup-addon-dir linked-id)))))
                  shim-out))

     (define scheme-out
       (parameterize ([current-output-port (open-output-string)]
                      [current-error-port (open-output-string)])
         (define out (current-output-port))
         (check-true (system* (build-path (rackup-shims-dir) "scheme") "--version"))
         (get-output-string out)))
     (define petite-out
       (parameterize ([current-output-port (open-output-string)]
                      [current-error-port (open-output-string)])
         (define out (current-output-port))
         (check-true (system* (build-path (rackup-shims-dir) "petite") "--version"))
         (get-output-string out)))
     (check-true (string-contains? scheme-out "scheme-ok --version"))
     (check-true (string-contains? petite-out "petite-ok --version"))

     (define activation (emit-shell-activation linked-id))
     (check-true (string-contains? activation "export PLTHOME="))
     (check-true (string-contains? activation "export PLTCOLLECTS="))
     (void (putenv "RACKUP_TOOLCHAIN" linked-id))
     (define deactivation (emit-shell-deactivation))
     (check-true (string-contains? deactivation "unset PLTHOME"))
     (check-true (string-contains? deactivation "unset PLTCOLLECTS"))
     (void (putenv "RACKUP_TOOLCHAIN" ""))))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define runtime-id "runtime-9.1-cs-x86_64-linux-minimal")
     (define version-dir (rackup-runtime-version-dir runtime-id))
     (define install-root (rackup-runtime-install-dir runtime-id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho hidden-runtime-test\n")
     (file-or-directory-permissions racket-exe #o755)
     (make-file-or-directory-link real-bin (rackup-runtime-bin-link runtime-id))
     (make-file-or-directory-link version-dir (rackup-runtime-current-link))
     (write-rktd-file (rackup-runtime-meta-file runtime-id)
                      (hash 'id
                            runtime-id
                            'role
                            'internal-runtime
                            'resolved-version
                            "9.1"
                            'variant
                            'cs
                            'distribution
                            'minimal
                            'arch
                            "x86_64"
                            'platform
                            "linux"
                            'installer-url
                            "https://example.invalid/runtime.sh"
                            'installer-filename
                            "runtime.sh"
                            'install-root
                            (path->string install-root)
                            'bin-link
                            (path->string (rackup-runtime-bin-link runtime-id))
                            'real-bin-dir
                            (path->string real-bin)
                            'installed-at
                            "2026-02-26T00:00:00Z"
                            'installed-by
                            'runtime-command
                            'source-spec
                            "stable"))

     (define rs (hidden-runtime-status))
     (check-true (hash-ref rs 'present?))
     (check-equal? (hash-ref rs 'id) runtime-id)
     (check-equal? (hash-ref (hash-ref rs 'meta) 'resolved-version) "9.1")

     (define runtime-status-out
       (let ([out (open-output-string)])
         (parameterize ([current-output-port out]
                        [current-error-port (open-output-string)])
           (cmd-runtime '("status"))
           (get-output-string out))))
     (check-true (string-contains? runtime-status-out "present: yes"))
     (check-true (string-contains? runtime-status-out (format "id: ~a" runtime-id)))

     (define doctor-out
       (let ([out (open-output-string)])
         (parameterize ([current-output-port out]
                        [current-error-port (open-output-string)])
           (doctor-report)
           (get-output-string out))))
     (check-true (string-contains? doctor-out "runtime-present: #t"))
     (check-true (string-contains? doctor-out (format "runtime-id: ~a" runtime-id)))))

  (let* ([rc-before (string-append "export FOO=1\n"
                                   "# >>> rackup initialize >>>\n"
                                   "export PATH=\"$HOME/.rackup/shims:$PATH\"\n"
                                   "# <<< rackup initialize <<<\n"
                                   "export BAR=2\n")]
         [expected-after "export FOO=1\nexport BAR=2\n"])
    (define-values (rc-after changed?) (strip-managed-block rc-before))
    (check-true changed?)
    (check-equal? rc-after expected-after))

  (define-values (unchanged changed?) (strip-managed-block "export PATH=/usr/bin\n"))
  (check-false changed?)
  (check-equal? unchanged "export PATH=/usr/bin\n"))
