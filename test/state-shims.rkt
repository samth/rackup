#lang at-exp racket/base

(require rackunit
         recspecs
         racket/file
         racket/format
         racket/list
         racket/port
         racket/path
         racket/runtime-path
         racket/string
         racket/system
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/main.rkt"
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

(define (run-main/capture args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-command-line-arguments (list->vector args)]
                 [current-output-port out]
                 [current-error-port err])
    (main))
  (values (get-output-string out) (get-output-string err)))

(define (run-main/stdout args)
  (define-values (out _err) (run-main/capture args))
  out)

(define-runtime-path rackup-bin "../bin/rackup")
(define install-ns (module->namespace '(file "../libexec/rackup/install.rkt")))
(define shell-ns (module->namespace '(file "../libexec/rackup/shell.rkt")))
(define runtime-ns (module->namespace '(file "../libexec/rackup/runtime.rkt")))

(define detect-bin-dir/private
  (parameterize ([current-namespace install-ns])
    (eval 'detect-bin-dir)))

(define installed-toolchain-env-vars/private
  (parameterize ([current-namespace install-ns])
    (eval 'installed-toolchain-env-vars)))

(define maybe-modernize-legacy-archsys!/private
  (parameterize ([current-namespace install-ns])
    (eval 'maybe-modernize-legacy-archsys!)))

(define shell-helper-script/private
  (parameterize ([current-namespace shell-ns])
    (eval 'shell-helper-script)))

(define hidden-runtime-invocation-prefix/private
  (parameterize ([current-namespace runtime-ns])
    (eval 'hidden-runtime-invocation-prefix)))

(define (run-bin-rackup/capture args)
  (define out (open-output-string))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system* rackup-bin args)))
  (values ok? (get-output-string out) (get-output-string err)))

(define (run-program/capture program args)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f program args))
  (close-output-port stdin)
  (subprocess-wait proc)
  (values (subprocess-status proc)
          (port->string stdout)
          (port->string stderr)))

(module+ test
  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (reshim!)
     (define shims-dir (rackup-shims-dir))
     (for ([exe '("racket" "raco")])
       (define shim (build-path shims-dir exe))
       (check-true (link-exists? shim))
       (let-values ([(status out err) (run-program/capture shim '())])
         (check-equal? status 2)
         (check-equal? out "")
         (check-true
          (string-contains?
           err
           (format "rackup: '~a' is managed by rackup, but no active toolchain is configured."
                   exe)))
         (check-true (string-contains? err "Install one with: rackup install stable"))
         (check-true (string-contains? err "Or select one with: rackup default <toolchain>"))
         (check-true
          (string-contains? err "Inspect choices with: rackup list | rackup available --limit 20"))))))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define id "release-8.18-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (write-string-file (build-path real-bin "racket")
                        "#!/usr/bin/env bash\nexit 23\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (register-toolchain!
      id
      (hash 'id id
            'kind 'release
            'requested-spec "stable"
            'resolved-version "8.18"
            'variant 'cs
            'distribution 'full
            'arch "x86_64"
            'platform "linux"
            'executables '("racket")
            'installed-at "2026-02-28T00:00:00Z"))
     (set-default-toolchain! id)
     (reshim!)
     (let-values ([(status out err) (run-program/capture (build-path (rackup-shims-dir) "racket")
                                                         '("--version"))])
       (check-equal? status 23)
       (check-equal? out "")
       (check-equal? err ""))))

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
                           (check-equal? (run-main/stdout '("prompt"))
                                         "racket-8.18\n")
                           (check-equal? (run-main/stdout '("prompt" "--short"))
                                         "racket-8.18\n")
                           (check-equal? (run-main/stdout '("prompt" "--long"))
                                         "[rk:release-8.18-cs-x86_64-linux-full]\n")
                           (let-values ([(ok? out err) (run-bin-rackup/capture '("prompt" "--short"))])
                             (check-true ok?)
                             (check-equal? out "racket-8.18\n")
                             (check-equal? err ""))
                           (let-values ([(ok? out err) (run-bin-rackup/capture '("prompt"))])
                             (check-true ok?)
                             (check-equal? out "racket-8.18\n")
                             (check-equal? err ""))
                           (check-equal? (path->string (resolve-executable-path "racket"))
                                         (path->string (build-path (rackup-toolchain-bin-link id)
                                                                   "racket")))

                           (define list-out (run-main/stdout '("list")))
                           (check-true
                            (string-contains? list-out
                                              "[default,active] release-8.18-cs-x86_64-linux-full"))
                           (check-false (string-contains? list-out "\n* "))
                           (check-false (string-contains? list-out "\n    tags: "))
                           (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
                           (dynamic-wind
                            (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
                            (lambda ()
                              (define stale-list-out (run-main/stdout '("list")))
                              (check-true
                               (string-contains?
                                stale-list-out
                                "Warning: RACKUP_TOOLCHAIN selects 'release-103-bc-i386-linux-full', but that toolchain is not installed."))
                              (check-true
                               (string-contains?
                                stale-list-out
                                "It overrides the default toolchain 'release-8.18-cs-x86_64-linux-full'."))
                              (check-true
                               (string-contains?
                                stale-list-out
                                "Clear it with: rackup switch --unset"))
                              (check-true
                               (string-contains?
                                stale-list-out
                                "Or unset it manually with: unset RACKUP_TOOLCHAIN"))
                              (check-true
                               (string-contains?
                                stale-list-out
                                "[default] release-8.18-cs-x86_64-linux-full")))
                            (lambda ()
                              (if old-env-id
                                  (putenv "RACKUP_TOOLCHAIN" old-env-id)
                                  (putenv "RACKUP_TOOLCHAIN" ""))))

                           (reshim!)
                           (check-true (link-exists? (build-path (rackup-shims-dir) "racket")))
                           (check-true (link-exists? (build-path (rackup-shims-dir) "rackup")))
                           (define dispatcher-src (file->string (rackup-shim-dispatcher)))
                           (check-true (string-contains? dispatcher-src "PLTHOME/.bin"))
                           (check-true
                            (string-contains? dispatcher-src "resolved underlying executable"))
                           (check-true
                            (string-contains?
                             dispatcher-src
                             "active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain"))
                           (check-true
                            (string-contains?
                             dispatcher-src
                             "if rackup_print_missing_loader_message \"$TARGET\"; then"))
                           (check-true
                            (string-contains? dispatcher-src "qemu-i386 via binfmt_misc"))
                           (define helper-src (shell-helper-script/private))
                           (check-true (string-contains? helper-src "_rackup_status"))
                           (check-true (string-contains? helper-src "return \"$_rackup_status\"")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define id "release-103-bc-i386-linux-full")
     (define install-root (build-path tmp "legacy-103"))
     (define plthome (build-path install-root "plt"))
     (define real-bin (build-path plthome "bin"))
     (make-directory* (rackup-toolchain-dir id))
     (make-directory* real-bin)
     (define mzscheme-exe (build-path real-bin "mzscheme"))
     (write-string-file
      mzscheme-exe
      @~a{#!/usr/bin/env bash
          set -euo pipefail
          printf 'PLTHOME=%s\n' "${PLTHOME:-}"
          })
     (file-or-directory-permissions mzscheme-exe #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (define env-vars (installed-toolchain-env-vars/private real-bin))
     (check-equal? env-vars (list (cons "PLTHOME" (path->string plthome))))
     (write-string-file (rackup-toolchain-env-file id)
                        (string-append "#!/usr/bin/env bash\n"
                                       "export PLTHOME="
                                       (format "'~a'\n" (path->string plthome))))
     (define meta
       (hash 'id
             id
             'kind
             'release
             'requested-spec
             "103"
             'resolved-version
             "103"
             'variant
             'bc
             'distribution
             'full
             'arch
             "i386"
             'platform
             "linux"
             'snapshot-site
             #f
             'snapshot-stamp
             #f
             'installer-url
             "http://download.plt-scheme.org/bundles/103/plt/plt-103-bin-i386-linux.tgz"
             'installer-filename
             "plt-103-bin-i386-linux.tgz"
             'install-root
             (path->string install-root)
             'bin-link
             (path->string (rackup-toolchain-bin-link id))
             'real-bin-dir
             (path->string real-bin)
             'env-vars
             (for/list ([kv (in-list env-vars)])
               (list (car kv) (cdr kv)))
             'executables
             '("mzscheme")
             'installed-at
             "2026-02-27T00:00:00Z"))
     (register-toolchain! id meta)
     (reshim!)
     (let-values ([(status out err) (run-program/capture (build-path (rackup-shims-dir) "mzscheme") '())])
       (check-equal? status 0)
       (check-equal? err "")
       (check-true (string-contains? out (format "PLTHOME=~a" (path->string plthome)))))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define id "release-103p1-bc-i386-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (define plthome (build-path install-root "plt"))
     (define legacy-bin (build-path plthome ".bin" "i386-linux"))
     (define archsys (build-path plthome "bin" "archsys"))
     (define fake-binfmt-dir (build-path tmp "binfmt"))
     (make-directory* real-bin)
     (make-directory* legacy-bin)
     (make-directory* (build-path plthome "bin"))
     (make-directory* fake-binfmt-dir)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\nexit 139\n")
     (file-or-directory-permissions racket-exe #o755)
     (write-string-file archsys "#!/bin/sh\necho i386-linux\n")
     (file-or-directory-permissions archsys #o755)
     (call-with-output-file (build-path legacy-bin "racket")
       (lambda (out)
         (write-bytes #"\177ELF\1" out)
         (write-bytes #"fake-legacy-racket\n" out))
       #:exists 'truncate/replace)
     (file-or-directory-permissions (build-path legacy-bin "racket") #o755)
     (write-string-file (build-path fake-binfmt-dir "qemu-i386")
                        "enabled\ninterpreter /usr/bin/qemu-i386\n")
     (write-string-file (rackup-toolchain-env-file id)
                        (format "#!/usr/bin/env bash\nexport PLTHOME='~a'\n"
                                (path->string plthome)))
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (register-toolchain!
      id
      (hash 'id id
            'kind 'release
            'requested-spec "103p1"
            'resolved-version "103p1"
            'variant 'bc
            'distribution 'full
            'arch "i386"
            'platform "linux"
            'install-root (path->string install-root)
            'bin-link (path->string (rackup-toolchain-bin-link id))
            'real-bin-dir (path->string real-bin)
            'executables '("racket")
            'installed-at "2026-02-28T00:00:00Z"))
     (set-default-toolchain! id)
     (reshim!)
     (define old-binfmt-dir (getenv "RACKUP_TEST_BINFMT_MISC_DIR"))
     (define old-host-machine (getenv "RACKUP_TEST_HOST_MACHINE"))
     (define old-assume-loader (getenv "RACKUP_TEST_ASSUME_I386_LOADER"))
     (dynamic-wind
      (lambda ()
        (putenv "RACKUP_TEST_BINFMT_MISC_DIR" (path->string fake-binfmt-dir))
        (putenv "RACKUP_TEST_HOST_MACHINE" "x86_64")
        (putenv "RACKUP_TEST_ASSUME_I386_LOADER" "1"))
      (lambda ()
        (let-values ([(status out err) (run-program/capture (build-path (rackup-shims-dir) "racket")
                                                            '("--version"))])
          (check-equal? status 139)
          (check-equal? out "")
          (check-true
           (string-contains?
            err
            "appears to be running through qemu-i386 via binfmt_misc on this host."))
          (check-true
           (string-contains?
            err
            "setarch i386 -R' only helps when the binary is running natively, not through qemu-user."))
          (check-true
           (string-contains?
            err
            "disable qemu-i386 binfmt_misc and retry, or use a true native i386 environment/VM."))))
      (lambda ()
        (if old-assume-loader
            (putenv "RACKUP_TEST_ASSUME_I386_LOADER" old-assume-loader)
            (putenv "RACKUP_TEST_ASSUME_I386_LOADER" ""))
        (if old-host-machine
            (putenv "RACKUP_TEST_HOST_MACHINE" old-host-machine)
            (putenv "RACKUP_TEST_HOST_MACHINE" ""))
        (if old-binfmt-dir
            (putenv "RACKUP_TEST_BINFMT_MISC_DIR" old-binfmt-dir)
            (putenv "RACKUP_TEST_BINFMT_MISC_DIR" ""))))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define real-bin (build-path tmp "plt" "bin"))
     (make-directory* real-bin)
     (define archsys (build-path real-bin "archsys"))
     (write-string-file
      archsys
      "#!/bin/sh\nif [ `file /bin/ls | grep ELF | wc -l` = 1 ]; then\n  SYS=i386-linux\nelse\n  SYS=i386-linux-aout\nfi\n")
     (file-or-directory-permissions archsys #o755)
     (maybe-modernize-legacy-archsys!/private real-bin)
     (define patched (file->string archsys))
     (check-true (string-contains? patched "file -L /bin/ls 2>/dev/null | grep ELF | wc -l"))
     (check-false (string-contains? patched "file /bin/ls | grep ELF | wc -l"))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define src-root (build-path tmp "fake-src"))
     (define plthome (build-path src-root "racket"))
     (define bin-dir (build-path plthome "bin"))
     (define collects-dir (build-path plthome "collects"))
     (define pkgs-dir (build-path src-root "pkgs"))
     (define addon-dir (build-path src-root "add-on" "development"))
     (define chez-bin-dir
       (build-path src-root "racket" "src" "build" "cs" "c" "ChezScheme" "pb" "bin" "pb"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)
     (make-directory* addon-dir)
     (make-directory* chez-bin-dir)

     (define (write-exe name body)
       (define p (build-path bin-dir name))
       (write-string-file p body)
       (file-or-directory-permissions p #o755)
       p)

     (write-exe "racket"
                @~a{#!/usr/bin/env bash
                    set -euo pipefail
                    if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
                      case "$2" in
                        *"(version)"*) printf '9.99-local'; exit 0 ;;
                        *"system-type 'vm"*) printf 'cs'; exit 0 ;;
                        *"find-system-path 'addon-dir"*) printf '@|addon-dir|'; exit 0 ;;
                      esac
                    fi
                    printf 'PLTHOME=%s\n' "${PLTHOME:-}"
                    printf 'PLTCOLLECTS=%s\n' "${PLTCOLLECTS:-}"
                    printf 'PLTADDONDIR=%s\n' "${PLTADDONDIR:-}"
                    printf 'ARGS=%s\n' "$*"
                    })
     (write-exe "raco"
                @~a{#!/usr/bin/env bash
                    set -euo pipefail
                    printf 'raco-ok\n'
                    })
     (for ([name '("scheme" "petite")])
       (define p (build-path chez-bin-dir name))
       (write-string-file p
                          @~a{#!/usr/bin/env bash
                              set -euo pipefail
                              printf '@|name|-ok %s\n' "$*"
                              })
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

     (write-exe "racket"
                @~a{#!/usr/bin/env bash
                    set -euo pipefail
                    if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
                      case "$2" in
                        *"(version)"*) printf '9.98-local'; exit 0 ;;
                        *"system-type 'vm"*) printf 'cs'; exit 0 ;;
                        *"find-system-path 'addon-dir"*) printf '@|addon-dir|'; exit 0 ;;
                      esac
                    fi
                    printf 'PLTHOME=%s\n' "${PLTHOME:-}"
                    printf 'PLTCOLLECTS=%s\n' "${PLTCOLLECTS:-}"
                    printf 'PLTADDONDIR=%s\n' "${PLTADDONDIR:-}"
                    printf 'ARGS=%s\n' "$*"
                    })
     (check-equal? (link-toolchain! "devsrc" (path->string src-root) '("--force")) linked-id)
     (check-equal? (hash-ref (read-toolchain-meta linked-id) 'resolved-version) "9.98-local")

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
                                                (path->string addon-dir))))
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
     (check-true (string-contains? activation (format "export PLTADDONDIR='~a'" (path->string addon-dir))))
     (check-equal? (run-main/stdout (list "switch" "devsrc")) activation)
     (check-equal? (run-main/stdout '("prompt")) "racket-local-9.98-local\n")
     (check-equal? (run-main/stdout '("prompt" "--short")) "racket-local-9.98-local\n")
     (check-equal? (run-main/stdout '("prompt" "--long")) "[rk:local-devsrc]\n")
     (void (putenv "RACKUP_TOOLCHAIN" linked-id))
     (define deactivation (emit-shell-deactivation))
     (check-true (string-contains? deactivation "unset PLTHOME"))
     (check-true (string-contains? deactivation "unset PLTCOLLECTS"))
     (check-equal? (run-main/stdout '("switch" "--unset")) deactivation)
     (void (putenv "RACKUP_TOOLCHAIN" ""))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define install-root (build-path tmp "fake-installed"))
     (define plthome (build-path install-root "racket"))
     (define bin-dir (build-path plthome "bin"))
     (define collects-dir (build-path plthome "share" "racket" "collects"))
     (define pkgs-dir (build-path plthome "share" "racket" "pkgs"))
     (define addon-dir (build-path install-root "add-on" "8.18-installed"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)
     (make-directory* addon-dir)

     (define (write-bin-exe name body)
       (define p (build-path bin-dir name))
       (write-string-file p body)
       (file-or-directory-permissions p #o755)
       p)

     (write-bin-exe "racket"
                    @~a{#!/usr/bin/env bash
                        set -euo pipefail
                        if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
                          case "$2" in
                            *"(version)"*) printf '8.18-installed'; exit 0 ;;
                            *"system-type 'vm"*) printf 'cs'; exit 0 ;;
                            *"find-system-path 'addon-dir"*) printf '@|addon-dir|'; exit 0 ;;
                          esac
                        fi
                        printf 'PLTHOME=%s\n' "${PLTHOME:-}"
                        printf 'PLTCOLLECTS=%s\n' "${PLTCOLLECTS:-}"
                        printf 'PLTADDONDIR=%s\n' "${PLTADDONDIR:-}"
                        })
     (write-bin-exe "raco"
                    @~a{#!/usr/bin/env bash
                        set -euo pipefail
                        printf 'raco-installed\n'
                        })
     (for ([name '("scheme" "petite")])
       (write-bin-exe name
                      @~a{#!/usr/bin/env bash
                          set -euo pipefail
                          printf '@|name|-installed %s\n' "$*"
                          }))

     (define linked-id (link-toolchain! "installed" (path->string install-root) '("--set-default")))
     (check-equal? linked-id "local-installed")

     (define linked-meta (read-toolchain-meta linked-id))
     (check-equal? (hash-ref linked-meta 'plthome) (path->string plthome))
     (check-equal? (hash-ref linked-meta 'source-root) #f)
     (check-not-false (member "racket" (hash-ref linked-meta 'executables)))
     (check-not-false (member "scheme" (hash-ref linked-meta 'executables)))
     (check-not-false (member "petite" (hash-ref linked-meta 'executables)))

     (define shim-out
       (parameterize ([current-output-port (open-output-string)]
                      [current-error-port (open-output-string)])
         (define out (current-output-port))
         (check-true (system* (build-path (rackup-shims-dir) "racket")))
         (get-output-string out)))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTHOME=~a" (path->string plthome))))
                                shim-out))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTCOLLECTS=~a:~a"
                                                              (path->string collects-dir)
                                                              (path->string pkgs-dir))))
                                shim-out))
     (check-true (regexp-match? (regexp (regexp-quote (format "PLTADDONDIR=~a"
                                                              (path->string addon-dir))))
                                shim-out))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define src-root (build-path tmp "linked-src"))
     (define plthome (build-path src-root "racket"))
     (define bin-dir (build-path plthome "bin"))
     (define collects-dir (build-path plthome "collects"))
     (define pkgs-dir (build-path src-root "pkgs"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)
     (define runtime-id "runtime-test")
     (define runtime-version-dir (rackup-runtime-version-dir runtime-id))
     (define runtime-real-bin (build-path tmp "runtime-real-bin"))
     (make-directory* runtime-real-bin)
     (make-file-or-directory-link (find-system-path 'exec-file)
                                  (build-path runtime-real-bin "racket"))
     (make-directory* runtime-version-dir)
     (make-file-or-directory-link runtime-real-bin (rackup-runtime-bin-link runtime-id))
     (make-file-or-directory-link runtime-version-dir (rackup-runtime-current-link))
     (define racket-bin (build-path bin-dir "racket"))
     (write-string-file racket-bin
                        @~a{#!/usr/bin/env bash
                            set -euo pipefail
                            if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
                              case "$2" in
                                *"(version)"*) printf '9.90-local'; exit 0 ;;
                                *"system-type 'vm"*) printf 'cs'; exit 0 ;;
                              esac
                            fi
                            printf 'linked-toolchain-racket\n'
                            })
     (file-or-directory-permissions racket-bin #o755)
     (define linked-id (link-toolchain! "devsrc-wrapper" (path->string src-root) '("--set-default")))
     (define poisoned-collects (build-path tmp "poisoned-collects"))
     (make-directory* (build-path poisoned-collects "racket"))
     (write-string-file (build-path poisoned-collects "racket" "runtime-config.rkt")
                        "#lang racket/base\n(error 'bad-runtime-config \"should not be loaded\")\n")
     (define current-collects
       (string-join (map path->string (current-library-collection-paths)) ":"))
     (define old-toolchain (getenv "RACKUP_TOOLCHAIN"))
     (define old-plthome (getenv "PLTHOME"))
     (define old-pltcollects (getenv "PLTCOLLECTS"))
     (define old-pltaddondir (getenv "PLTADDONDIR"))
     (dynamic-wind
      (lambda ()
        (putenv "RACKUP_TOOLCHAIN" linked-id)
        (putenv "PLTHOME" (path->string plthome))
        (putenv "PLTCOLLECTS"
                (string-append (path->string poisoned-collects) ":" current-collects))
        (putenv "PLTADDONDIR" (path->string (build-path tmp "poisoned-addon"))))
      (lambda ()
        (let-values ([(ok? out err) (run-bin-rackup/capture '("current" "id"))])
          (check-true ok?)
          (check-equal? out (format "~a\n" linked-id))
          (check-equal? err "")))
      (lambda ()
        (if old-toolchain
            (putenv "RACKUP_TOOLCHAIN" old-toolchain)
            (putenv "RACKUP_TOOLCHAIN" ""))
        (if old-plthome
            (putenv "PLTHOME" old-plthome)
            (putenv "PLTHOME" ""))
        (if old-pltcollects
            (putenv "PLTCOLLECTS" old-pltcollects)
            (putenv "PLTCOLLECTS" ""))
        (if old-pltaddondir
            (putenv "PLTADDONDIR" old-pltaddondir)
            (putenv "PLTADDONDIR" ""))))))

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

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-rackup-layout!)
     (define prefix (hidden-runtime-invocation-prefix/private "/tmp/fake-racket"))
     (check-equal? prefix
                   (list "/tmp/fake-racket"
                         "-U"
                         "-A"
                         (path->string (rackup-runtime-addon-dir))))
     (check-true (directory-exists? (rackup-runtime-addon-dir)))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-rackup-layout!)
     (define runtime-id "runtime-9.1-cs-x86_64-linux-minimal")
     (define version-dir (rackup-runtime-version-dir runtime-id))
     (define fake-bin-dir (build-path tmp "fake-hidden-runtime-bin"))
     (define captured-argv (build-path tmp "captured-hidden-runtime-argv.txt"))
     (make-directory* fake-bin-dir)
     (define fake-racket (build-path fake-bin-dir "racket"))
     (write-string-file fake-racket
                        (string-append
                         "#!/usr/bin/env bash\n"
                         "set -euo pipefail\n"
                         "printf '%s\\n' \"$@\" > "
                         (path->string captured-argv)
                         "\n"))
     (file-or-directory-permissions fake-racket #o755)
     (make-directory* version-dir)
     (make-file-or-directory-link fake-bin-dir (rackup-runtime-bin-link runtime-id))
     (make-file-or-directory-link version-dir (rackup-runtime-current-link))
     (let-values ([(ok? out err) (run-bin-rackup/capture '("current" "id"))])
       (check-true ok?)
       (check-equal? out "")
       (check-equal? err ""))
     (define argv
       (string-split (string-trim (file->string captured-argv)) "\n"))
     (check-equal? (take argv 3)
                   (list "-U"
                         "-A"
                         (path->string (rackup-runtime-addon-dir))))
     (check-true (string-suffix? (list-ref argv 3) "libexec/rackup-core.rkt"))
     (check-equal? (drop argv 4) '("current" "id"))))

  (let* ([rc-before (format "~a\n"
                            @~a{export FOO=1
                                # >>> rackup initialize >>>
                                export PATH="$HOME/.rackup/shims:$PATH"
                                # <<< rackup initialize <<<
                                export BAR=2
                                })]
         [expected-after "export FOO=1\nexport BAR=2\n"])
    (define-values (rc-after changed?) (strip-managed-block rc-before))
    (check-true changed?)
    (check-equal? rc-after expected-after))

  (define-values (unchanged changed?) (strip-managed-block "export PATH=/usr/bin\n"))
  (check-false changed?)
  (check-equal? unchanged "export PATH=/usr/bin\n")

  (let-values ([(spec opts)
                (split-install-command-args '("--distribution" "minimal" "stable"))])
    (check-equal? spec "stable")
    (check-equal? opts '("--distribution" "minimal")))
  (let-values ([(spec opts)
                (split-install-command-args '("stable" "--distribution" "minimal" "--force"))])
    (check-equal? spec "stable")
    (check-equal? opts '("--distribution" "minimal" "--force")))
  (let-values ([(spec opts)
                (split-install-command-args '("--quiet" "stable" "--distribution" "minimal"))])
    (check-equal? spec "stable")
    (check-equal? opts '("--quiet" "--distribution" "minimal")))
  (check-exn exn:fail?
             (lambda () (split-install-command-args '("stable" "8.18"))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define installer (build-path tmp "racket-textual-5.2-bin-x86_64-linux-fake.sh"))
     (define dest (build-path tmp "legacy-install"))
     (write-string-file
      installer
      @~a{#!/bin/sh
          set -eu
          if [ "$#" -ne 0 ]; then
            echo "unexpected args: $*" >&2
            exit 7
          fi
          read unixstyle || unixstyle=""
          read where || where=""
          read sysdir || sysdir=""
          if [ -z "$where" ]; then
            echo "missing destination" >&2
            exit 8
          fi
          mkdir -p "$where/bin" "$where/collects"
          printf '#!/bin/sh\nexit 0\n' > "$where/bin/racket"
          chmod +x "$where/bin/racket"
          exit 0
          })
     (file-or-directory-permissions installer #o755)
     (run-linux-installer! installer dest)
     (check-true (directory-exists? (build-path dest "bin")))
     (check-true (directory-exists? (build-path dest "collects")))
     (check-true (file-exists? (build-path dest "bin" "racket")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define installer (build-path tmp "racket-6.0-x86_64-linux-fake.sh"))
     (define dest (build-path tmp "legacy-6.0-install"))
     (write-string-file
      installer
      @~a{#!/bin/sh
          set -eu
          echo "This program will extract and install Racket v6.0."
          echo "Do you want a Unix-style distribution?"
          read unixstyle || unixstyle=""
          echo "Where do you want to install the \"racket\" directory tree?"
          read where || where=""
          echo "If you want to install new system links..."
          read sysdir || sysdir=""
          if [ "$#" -ne 0 ]; then
            echo "unexpected args: $*" >&2
            exit 7
          fi
          if [ "$unixstyle" != "n" ] && [ "$unixstyle" != "N" ]; then
            echo "expected in-place install answer" >&2
            exit 8
          fi
          if [ -z "$where" ]; then
            echo "missing destination" >&2
            exit 9
          fi
          mkdir -p "$where/bin" "$where/collects"
          printf '#!/bin/sh\nexit 0\n' > "$where/bin/racket"
          chmod +x "$where/bin/racket"
          exit 0
          })
     (file-or-directory-permissions installer #o755)
     (run-linux-installer! installer dest)
     (check-true (directory-exists? (build-path dest "bin")))
     (check-true (directory-exists? (build-path dest "collects")))
     (check-true (file-exists? (build-path dest "bin" "racket")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define installer (build-path tmp "racket-6.1.1-x86_64-linux-fake.sh"))
     (define dest (build-path tmp "modern-6.1.1-install"))
     (write-string-file
      installer
      @~a{#!/bin/sh
          set -eu
          echo "Command-line flags:"
          echo "  --dest <path>"
          echo "  --create-dir"
          echo "  --in-place"
          if [ "$#" -ne 4 ]; then
            echo "unexpected args: $*" >&2
            exit 7
          fi
          if [ "$1" != "--create-dir" ] || [ "$2" != "--in-place" ] || [ "$3" != "--dest" ]; then
            echo "unexpected flag protocol: $*" >&2
            exit 8
          fi
          where="$4"
          mkdir -p "$where/bin" "$where/collects"
          printf '#!/bin/sh\nexit 0\n' > "$where/bin/racket"
          chmod +x "$where/bin/racket"
          exit 0
          })
     (file-or-directory-permissions installer #o755)
     (run-linux-installer! installer dest)
     (check-true (directory-exists? (build-path dest "bin")))
     (check-true (directory-exists? (build-path dest "collects")))
     (check-true (file-exists? (build-path dest "bin" "racket")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define installer (build-path tmp "plt-209-bin-i386-linux-fake.sh"))
     (define dest (build-path tmp "legacy-basic-install"))
     (write-string-file
      installer
      @~a{#!/bin/sh
          set -eu
          if [ "$#" -ne 0 ]; then
            echo "unexpected args: $*" >&2
            exit 7
          fi
          read where || where=""
          read sysdir || sysdir=""
          if [ -z "$where" ]; then
            echo "missing destination" >&2
            exit 8
          fi
          mkdir -p "$where/bin" "$where/collects"
          printf '#!/bin/sh\nexit 0\n' > "$where/bin/mzscheme"
          chmod +x "$where/bin/mzscheme"
          exit 0
          })
     (file-or-directory-permissions installer #o755)
     (run-linux-installer! installer dest #:legacy-install-kind 'shell-basic)
     (check-true (directory-exists? (build-path dest "bin")))
     (check-true (directory-exists? (build-path dest "collects")))
     (check-true (file-exists? (build-path dest "bin" "mzscheme")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define installer (build-path tmp "plt-209-bin-i386-linux-fail.sh"))
     (define dest (build-path tmp "legacy-fail-install"))
     (write-string-file
      installer
      @~a{#!/bin/sh
          set -eu
          echo 'bad 100% format %s output' >&2
          exit 9
          })
     (file-or-directory-permissions installer #o755)
     (define msg
       (with-handlers ([exn:fail? exn-message])
         (run-linux-installer! installer dest #:legacy-install-kind 'shell-basic)
         #f))
     (check-true (string? msg))
     (check-true (string-contains? msg "linux-installer failed"))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define tar-exe (find-executable-path "tar"))
     (unless tar-exe
       (error 'state-shims "tar executable not found"))
     (define archive-root (build-path tmp "archive-root"))
     (define archive (build-path tmp "racket-minimal-9.1-riscv64-linux-cs.tgz"))
     (define dest (build-path tmp "tgz-install"))
     (make-directory* (build-path archive-root "racket" "bin"))
     (write-string-file (build-path archive-root "racket" "bin" "racket")
                        "#!/usr/bin/env bash\necho tgz-runtime\n")
     (file-or-directory-permissions (build-path archive-root "racket" "bin" "racket") #o755)
     (check-true (system* tar-exe "-czf" archive "-C" archive-root "."))
     (run-linux-tgz-installer! archive dest)
     (check-true (directory-exists? (build-path dest "racket" "bin")))
     (check-true (file-exists? (build-path dest "racket" "bin" "racket")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define install-root (build-path tmp "plt-archive"))
     (make-directory* (build-path install-root "plt" "bin"))
     (check-equal? (path->string (detect-bin-dir/private install-root))
                   (path->string (build-path install-root "plt" "bin")))))

  (check-equal? (run-main/stdout '("install" "--help"))
                (run-main/stdout '("help" "install")))
  (expect (display (run-main/stdout '("install" "--help")))
          @~a{
            Usage: rackup install <spec> [flags]

            Install a Racket toolchain from official release, pre-release, or snapshot installers.

            Specs:
              stable | pre-release | snapshot | snapshot:utah | snapshot:northwestern
              <numeric version> (examples: 9.1, 8.18, 7.9, 5.2)

            Flags:
              --variant cs|bc         Override VM variant (default depends on version).
              --distribution full|minimal  Install full or minimal distribution (default: full).
              --snapshot-site auto|utah|northwestern  Choose snapshot mirror (default: auto).
              --arch <arch>           Override target architecture (default: host arch).
              --set-default           Set installed toolchain as the global default.
              --force                 Reinstall if the same canonical toolchain is already installed.
              --no-cache              Redownload installer instead of using cache.
              --quiet                 Show minimal output (errors + final result lines).
              --verbose               Show detailed installer URL/path output.

            Examples:
              rackup install stable
              rackup install 8.18 --variant cs
              rackup install snapshot --snapshot-site utah
          })
  (check-equal? (run-main/stdout '("switch" "--help"))
                (run-main/stdout '("help" "switch")))
  (expect (display (run-main/stdout '("switch" "--help")))
          @~a{
            Usage: rackup switch <toolchain> | switch --unset

            Switch the active toolchain in the current shell without changing the default.
            When run via the shell integration installed by `rackup init`, this updates
            the current shell. Otherwise, it emits shell code that you can `eval`.

            Examples:
              rackup switch stable
              rackup switch 8.18
              rackup switch --unset
          })
  (check-equal? (run-main/stdout '("prompt" "--help"))
                (run-main/stdout '("help" "prompt")))
  (expect (display (run-main/stdout '("prompt" "--help")))
          @~a{
            Usage: rackup prompt [--long|--short|--raw|--source]

            Print prompt/status information for the active toolchain.
            Prints nothing when no active/default toolchain is configured.
            Handled by the shell wrapper without starting Racket when possible.

            Default output:
              racket-9.1

            Options:
              --long                  Print the long bracketed form: "[rk:<toolchain-id>]".
              --short                 Print a compact label like "racket-9.1" (same as default).
              --raw                   Print only the active toolchain id.
              --source                Print "<id><TAB><env|default>".

            Examples:
              rackup prompt
              rackup prompt --long
              rackup prompt --short
              rackup prompt --raw
              PS1='$(rackup prompt) '$PS1
          })
  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define-values (help-ok? help-out help-err)
       (run-bin-rackup/capture '("prompt" "--help")))
     (check-true help-ok?)
     (check-equal? help-err "")
     (check-true (string-contains? help-out "Usage: rackup prompt [--long|--short|--raw|--source]"))))
  (expect (display (run-main/stdout '("runtime" "--help")))
          @~a{
            Usage: rackup runtime status|install|upgrade

            Manage rackup's hidden internal runtime used to run rackup itself.

            Subcommands:
              status                  Show whether the hidden runtime is present and its metadata.
              install                 Install the hidden runtime if missing (or adopt existing).
              upgrade                 Install a newer hidden runtime if one is available.
          })
  (check-equal? (run-main/stdout '("self-upgrade" "--help"))
                (run-main/stdout '("help" "self-upgrade")))
  (expect (display (run-main/stdout '("self-upgrade" "--help")))
          @~a{
            Usage: rackup self-upgrade [--with-init]

            Upgrade rackup's code by rerunning the bootstrap installer into the current RACKUP_HOME.
            By default this skips shell init edits and keeps your current shell config unchanged.

            Options:
              --with-init             Allow the installer to run shell init updates (-y without --no-init).

            Environment overrides (advanced):
              RACKUP_SELF_UPGRADE_INSTALL_SH  Path or URL to install.sh (test/dev override).
          })

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define id "release-8.18-cs-x86_64-linux-full")
     (define tc-dir (rackup-toolchain-dir id))
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (write-string-file (build-path real-bin "racket") "#!/usr/bin/env bash\nexit 0\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (make-directory* tc-dir)
     (define meta
       (hash 'id
             id
             'kind
             'release
             'requested-spec
             "8.18"
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
     (check-equal? (run-main/stdout '("current" "id")) (format "~a\n" id))
     (check-equal? (run-main/stdout '("current" "source")) "default\n")
     (check-equal? (run-main/stdout '("current" "line")) (format "~a\tdefault\n" id))
     (check-equal? (run-main/stdout '("default" "id")) (format "~a\n" id))
     (check-equal? (run-main/stdout '("default" "status")) (format "set\t~a\n" id))
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" id))
      (lambda ()
        (check-equal? (run-main/stdout '("current" "source")) "env\n")
        (check-equal? (run-main/stdout '("current" "line")) (format "~a\tenv\n" id)))
     (lambda ()
        (if old-env-id
            (putenv "RACKUP_TOOLCHAIN" old-env-id)
            (putenv "RACKUP_TOOLCHAIN" ""))))
     (check-equal? (run-main/stdout '("default" "clear")) "Cleared default toolchain.\n")
     (check-equal? (run-main/stdout '("default" "status")) "unset\n")))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
      (lambda ()
        (define list-out (run-main/stdout '("list")))
        (check-true
         (string-contains?
          list-out
          "Warning: RACKUP_TOOLCHAIN selects 'release-103-bc-i386-linux-full', but that toolchain is not installed."))
        (check-true (string-contains? list-out "Clear it with: rackup switch --unset"))
        (check-true
         (string-contains? list-out "Or unset it manually with: unset RACKUP_TOOLCHAIN"))
        (check-true (string-contains? list-out "No toolchains installed.")))
      (lambda ()
        (if old-env-id
            (putenv "RACKUP_TOOLCHAIN" old-env-id)
            (putenv "RACKUP_TOOLCHAIN" ""))))))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define id "release-8.18-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
     (file-or-directory-permissions racket-exe #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (register-toolchain!
      id
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
     (reshim!)
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
      (lambda ()
        (define shim (build-path (rackup-shims-dir) "racket"))
        (let-values ([(status out err) (run-program/capture shim '("--version"))])
          (check-equal? status 127)
          (check-equal? out "")
          (check-true
           (string-contains?
            err
            "rackup: executable 'racket' not found in toolchain 'release-103-bc-i386-linux-full'"))
          (check-true
           (string-contains?
            err
            "rackup: active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain 'release-8.18-cs-x86_64-linux-full'."))
          (check-true (string-contains? err "Clear it with: rackup switch --unset"))
          (check-true
           (string-contains? err "Or unset it manually with: unset RACKUP_TOOLCHAIN"))
          (check-true
           (string-contains?
            err
            "Try: rackup which racket --toolchain release-103-bc-i386-linux-full"))))
      (lambda ()
        (if old-env-id
            (putenv "RACKUP_TOOLCHAIN" old-env-id)
            (putenv "RACKUP_TOOLCHAIN" ""))))))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define orphan-id "release-5.2-bc-x86_64-linux-full")
     (define tc-dir (rackup-toolchain-dir orphan-id))
     (define addon-dir (rackup-addon-dir orphan-id))
     (make-directory* (build-path tc-dir "install"))
     (write-string-file (build-path tc-dir "partial.txt") "leftover")
     (make-directory* addon-dir)
     (expect (display (run-main/stdout '("remove" "5.2")))
       (format "Removed orphan/partial toolchain directory ~a\n" orphan-id))
     (check-false (directory-exists? tc-dir))
     (check-false (directory-exists? addon-dir))
     (void)))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define fake-installer (build-path tmp "fake-install.sh"))
     (define args-log (build-path tmp "self-upgrade-args.log"))
     (define mode-log (build-path tmp "self-upgrade-mode.log"))
     (write-string-file
      fake-installer
      (format
       "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$@\" > ~s\nprintf '%s\\n' \"${RACKUP_BOOTSTRAP_MODE:-}\" > ~s\nexit 0\n"
       (path->string args-log)
       (path->string mode-log)))
     (file-or-directory-permissions fake-installer #o755)
     (define old-override (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" (path->string fake-installer)))
      (lambda ()
        (expect (display (run-main/stdout '("self-upgrade")))
                (format "Upgrading rackup code in ~a\nrackup code upgrade complete.\n"
                        (path->string (rackup-home))))
        (let ([args-lines
               (call-with-input-file args-log
                 (lambda (in) (filter (lambda (s) (not (string=? s ""))) (port->lines in))))])
          (check-equal? args-lines
                        (list "-y" "--no-init" "--prefix" (path->string (rackup-home)))))
        (let ([mode-lines
               (call-with-input-file mode-log
                 (lambda (in) (filter (lambda (s) (not (string=? s ""))) (port->lines in))))])
          (check-equal? mode-lines (list "self-upgrade"))))
      (lambda ()
        (if old-override
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" old-override)
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" ""))))))
