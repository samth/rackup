#lang at-exp racket/base

(require rackunit
         recspecs
         racket/file
         racket/format
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
                @~a{#!/usr/bin/env bash
                    set -euo pipefail
                    if [[ "$#" -ge 2 && "$1" == "-e" ]]; then
                      case "$2" in
                        *"(version)"*) printf '9.99-local'; exit 0 ;;
                        *"system-type 'vm"*) printf 'cs'; exit 0 ;;
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
     (check-equal? (run-main/stdout (list "switch" "devsrc")) activation)
     (check-equal? (run-main/stdout '("prompt")) "racket-local-9.99-local\n")
     (check-equal? (run-main/stdout '("prompt" "--short")) "racket-local-9.99-local\n")
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
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)

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
                          esac
                        fi
                        printf 'PLTHOME=%s\n' "${PLTHOME:-}"
                        printf 'PLTCOLLECTS=%s\n' "${PLTCOLLECTS:-}"
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
                                shim-out)))))

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
