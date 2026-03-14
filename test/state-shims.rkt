#lang at-exp racket/base

(require rackunit
         recspecs
         recspecs/shell
         racket/file
         racket/format
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/legacy.rkt"
         "../libexec/rackup/main.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/runtime.rkt"
         "../libexec/rackup/shell.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt"
         "../libexec/rackup/util.rkt"
         "../libexec/rackup/versioning.rkt"
         (only-in (submod "../libexec/rackup/install.rkt" for-testing)
                  detect-bin-dir)
         (only-in (submod "../libexec/rackup/runtime.rkt" for-testing)
                  hidden-runtime-invocation-prefix)
         (submod "../libexec/rackup/shell.rkt" for-testing))

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

(define (run-main args)
  (let/ec escape
    (parameterize ([current-command-line-arguments (list->vector args)]
                   [exit-handler (lambda (v) (escape v))])
      (main))))

(define-runtime-path rackup-bin "../bin/rackup")



(module+ test
  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (with-state-lock (reshim!))
     (define shims-dir (rackup-shims-dir))
     (for ([exe '("racket" "raco")])
       (define shim (build-path shims-dir exe))
       (check-true (link-exists? shim))
       (define-values (proc stdout stdin stderr)
         (subprocess #f #f #f shim))
       (close-output-port stdin)
       (subprocess-wait proc)
       (check-equal? (subprocess-status proc) 2)
       (check-equal? (port->string stdout) "")
       (define err-str (port->string stderr))
       (expect (display err-str)
               (format "rackup: '~a' is managed by rackup, but no active toolchain is configured." exe)
               #:match 'contains)
       (expect (display err-str) "Install one with: rackup install stable" #:match 'contains)
       (expect (display err-str) "Or select one with: rackup default <toolchain>" #:match 'contains)
       (expect (display err-str)
               "Inspect choices with: rackup list | rackup available --limit 20"
               #:match 'contains)))))

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
     (with-state-lock
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
       (reshim!))
     (expect/shell (list (path->string (build-path (rackup-shims-dir) "racket")) "--version")
                   #:status 23 "")))

  ;; Test that the shim resolves the bin symlink physically, so that
  ;; wrapper scripts see a canonical path via $0.  Before the fix,
  ;; TARGET went through the bin symlink; the fix uses cd -P to resolve it.
  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define id "release-9.1-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     ;; Create a script that prints the path it was invoked as ($0)
     (write-string-file (build-path real-bin "racket")
                        "#!/usr/bin/env bash\necho \"$0\"\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     ;; Create a launcher script like macOS bin/drracket: resolves symlinks
     ;; on the file but uses `pwd` (not `pwd -P`) for the directory.
     ;; This mimics Racket's make-mred-launcher output.
     (define app-dir (build-path install-root "DrRacket.app"))
     (make-directory* app-dir)
     (write-string-file (build-path app-dir "DrRacket")
                        "#!/usr/bin/env bash\necho ok\n")
     (file-or-directory-permissions (build-path app-dir "DrRacket") #o755)
     (write-string-file
      (build-path real-bin "drracket")
      (string-append "#!/bin/sh\n"
                     "# Mimics Racket's make-mred-launcher script.\n"
                     "# Uses pwd (not pwd -P) to resolve the directory.\n"
                     "saveD=`pwd`\n"
                     "D=`dirname \"$0\"`\n"
                     "cd \"$D\"\n"
                     "D=`pwd`\n"
                     "cd \"$saveD\"\n"
                     "bindir=\"$D/..\"\n"
                     "exec \"${bindir}/DrRacket.app/DrRacket\" ${1+\"$@\"}\n"))
     (file-or-directory-permissions (build-path real-bin "drracket") #o755)
     ;; bin is a symlink to install/bin — this is the normal rackup layout
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (with-state-lock
       (register-toolchain!
        id
        (hash 'id id
              'kind 'release
              'requested-spec "stable"
              'resolved-version "9.1"
              'variant 'cs
              'distribution 'full
              'arch "x86_64"
              'platform "linux"
              'executables '("racket" "drracket")
              'installed-at "2026-03-10T00:00:00Z"))
       (set-default-toolchain! id)
       (reshim!))
     ;; Test 1: racket shim invokes through the resolved path
     (define-values (proc stdout stdin stderr)
       (subprocess #f #f #f (build-path (rackup-shims-dir) "racket")))
     (close-output-port stdin)
     (subprocess-wait proc)
     (define out (string-trim (port->string stdout)))
     (close-input-port stdout)
     (close-input-port stderr)
     (check-true (string-contains? out "install/bin/racket")
                 (format "expected resolved path through install/bin, got: ~a" out))
     (check-false (regexp-match? #px"/toolchains/[^/]+/bin/racket$" out)
                  (format "path should not end with unresolved bin symlink: ~a" out))
     ;; Test 2: drracket launcher script resolves bindir correctly.
     ;; The launcher uses `pwd` (not `pwd -P`), so if the shim doesn't
     ;; resolve the bin symlink, the launcher computes a wrong bindir
     ;; and fails to find DrRacket.app.
     (define-values (proc2 stdout2 stdin2 stderr2)
       (subprocess #f #f #f (build-path (rackup-shims-dir) "drracket")))
     (close-output-port stdin2)
     (subprocess-wait proc2)
     (define out2 (string-trim (port->string stdout2)))
     (define err2 (port->string stderr2))
     (close-input-port stdout2)
     (close-input-port stderr2)
     (check-equal? (subprocess-status proc2) 0
                   (format "drracket launcher should succeed, stderr: ~a" err2))
     (check-equal? out2 "ok")))

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
                           (with-state-lock (register-toolchain! id meta))
                           (check-equal? (get-default-toolchain) id)
                           (check-equal? (find-local-toolchain "release-8.18") id)
                           @expect[(run-main '("prompt"))]{racket-8.18
}
                           @expect[(run-main '("prompt" "--short"))]{racket-8.18
}
                           @expect[(run-main '("prompt" "--long"))]{[rk:release-8.18-cs-x86_64-linux-full]
}
                           @expect/shell[(list (path->string rackup-bin) "prompt" "--short")]{racket-8.18
}
                           @expect/shell[(list (path->string rackup-bin) "prompt")]{racket-8.18
}
                           (check-equal? (path->string (resolve-executable-path "racket"))
                                         (path->string (build-path (rackup-toolchain-bin-link id)
                                                                   "racket")))

                           (define list-out (capture-output (lambda () (run-main '("list")))))
                           (check-true
                            (string-contains? list-out
                                              "[default,active,stable] release-8.18-cs-x86_64-linux-full"))
                           (check-false (string-contains? list-out "\n* "))
                           (check-false (string-contains? list-out "\n    tags: "))
                           (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
                           (dynamic-wind
                            (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
                            (lambda ()
                              (define stale-list-out (capture-output (lambda () (run-main '("list")))))
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
                                "[default,stable] release-8.18-cs-x86_64-linux-full")))
                            (lambda ()
                              (if old-env-id
                                  (putenv "RACKUP_TOOLCHAIN" old-env-id)
                                  (putenv "RACKUP_TOOLCHAIN" ""))))

                           (with-state-lock (reshim!))
                           (check-true (link-exists? (build-path (rackup-shims-dir) "racket")))
                           (check-true (link-exists? (build-path (rackup-shims-dir) "rackup")))
                           (define dispatcher-src (file->string (rackup-shim-dispatcher)))
                           (check-true (string-contains? dispatcher-src "install_root/.bin"))
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
                           (define helper-src (shell-helper-script "bash"))
                           (check-true (string-contains? helper-src "_rackup_status"))
                           (check-true (string-contains? helper-src "return \"$_rackup_status\""))

                           ;; User-scope addon bin executables
                           ;; Racket nests user-scope packages under the installation
                           ;; name inside $PLTADDONDIR, e.g. $PLTADDONDIR/9.1/bin/resyntax.
                           (define addon-inst-bin
                             (build-path (rackup-addon-dir id) "9.1" "bin"))
                           (make-directory* addon-inst-bin)
                           (define fake-exe (build-path addon-inst-bin "resyntax"))
                           (display-to-file "#!/bin/sh\necho ok\n" fake-exe)
                           (file-or-directory-permissions fake-exe #o755)
                           (check-equal? (path->string (resolve-executable-path "resyntax"))
                                         (path->string fake-exe))
                           ;; reshim picks up addon-bin executables
                           (with-state-lock (reshim!))
                           (check-true (link-exists? (build-path (rackup-shims-dir) "resyntax")))
                           ;; dispatcher source includes addon fallback
                           (check-true (string-contains? dispatcher-src "ADDON_TARGET"))))

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
             '()
             'executables
             '("mzscheme")
             'installed-at
             "2026-02-27T00:00:00Z"))
     (with-state-lock
       (register-toolchain! id meta)
       (reshim!))
     (define mzscheme-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "mzscheme")))))
     ;; PLTHOME should NOT be set by the shim (it is not a Racket env var)
     (check-true (string-contains? mzscheme-out "PLTHOME="))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define id "release-103p1-bc-i386-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     ;; In a real PLT 103 installation, the layout is plt/bin/ and plt/.bin/.
     ;; The dispatcher derives the install root from dirname(BIN_REAL) to find .bin/.
     (define plthome (build-path install-root "plt"))
     (define real-bin (build-path plthome "bin"))
     (define legacy-bin (build-path plthome ".bin" "i386-linux"))
     (define archsys (build-path plthome "bin" "archsys"))
     (define fake-binfmt-dir (build-path tmp "binfmt"))
     (make-directory* real-bin)
     (make-directory* legacy-bin)
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
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (with-state-lock
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
       (reshim!))
     (define old-binfmt-dir (getenv "RACKUP_TEST_BINFMT_MISC_DIR"))
     (define old-host-machine (getenv "RACKUP_TEST_HOST_MACHINE"))
     (define old-assume-loader (getenv "RACKUP_TEST_ASSUME_I386_LOADER"))
     (dynamic-wind
      (lambda ()
        (putenv "RACKUP_TEST_BINFMT_MISC_DIR" (path->string fake-binfmt-dir))
        (putenv "RACKUP_TEST_HOST_MACHINE" "x86_64")
        (putenv "RACKUP_TEST_ASSUME_I386_LOADER" "1"))
      (lambda ()
        (define shim-cmd (list (path->string (build-path (rackup-shims-dir) "racket")) "--version"))
        (expect/shell shim-cmd #:status 139
                      #:port 'stderr #:match 'contains
                      "appears to be running through qemu-i386 via binfmt_misc on this host.")
        (expect/shell shim-cmd #:status 139
                      #:port 'stderr #:match 'contains
                      "setarch i386 -R' only helps when the binary is running natively, not through qemu-user.")
        (expect/shell shim-cmd #:status 139
                      #:port 'stderr #:match 'contains
                      "disable qemu-i386 binfmt_misc and retry, or use a true native i386 environment/VM."))
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
     (maybe-modernize-legacy-archsys! real-bin)
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
     (define boot-dir (build-path plthome "lib" "racket"))
     (define petite-boot (build-path boot-dir "petite.boot"))
     (define scheme-boot (build-path boot-dir "scheme.boot"))
     (define chez-bin-dir
       (build-path src-root "racket" "src" "build" "cs" "c" "ChezScheme" "ta6le" "bin" "ta6le"))
     (make-directory* bin-dir)
     (make-directory* collects-dir)
     (make-directory* pkgs-dir)
     (make-directory* addon-dir)
     (make-directory* boot-dir)
     (make-directory* chez-bin-dir)
     (write-string-file petite-boot "fake petite boot\n")
     (write-string-file scheme-boot "fake scheme boot\n")

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
     (define old-plthome (getenv "PLTHOME"))
     (define old-pltcollects (getenv "PLTCOLLECTS"))
     (void (putenv "PLTADDONDIR" ""))
     (void (putenv "PLTHOME" ""))
     (void (putenv "PLTCOLLECTS" ""))
     (define shim-out
       (capture-output (lambda () (system* shim-racket))))
     (void (if old-pltaddon
               (putenv "PLTADDONDIR" old-pltaddon)
               (putenv "PLTADDONDIR" "")))
     (void (if old-plthome
               (putenv "PLTHOME" old-plthome)
               (putenv "PLTHOME" "")))
     (void (if old-pltcollects
               (putenv "PLTCOLLECTS" old-pltcollects)
               (putenv "PLTCOLLECTS" "")))
     ;; PLTHOME and PLTCOLLECTS should NOT be set by the shim — they are not
     ;; Racket env vars, and the binary finds its own collects.
     (check-true (string-contains? shim-out "PLTHOME=\n"))
     (check-true (string-contains? shim-out "PLTCOLLECTS=\n"))
     (check-true (regexp-match?
                  (regexp (regexp-quote (format "PLTADDONDIR=~a"
                                                (path->string addon-dir))))
                  shim-out))

     (define scheme-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "scheme") "--version"))))
     (define petite-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "petite") "--version"))))
     (check-true (string-contains? scheme-out (format "scheme-ok -B ~a -B ~a --version"
                                                      (path->string petite-boot)
                                                      (path->string scheme-boot))))
     (check-true (string-contains? petite-out (format "petite-ok -B ~a --version"
                                                      (path->string petite-boot))))

     (define activation (emit-shell-activation linked-id))
     (check-false (string-contains? activation "export PLTHOME="))
     (check-false (string-contains? activation "export PLTCOLLECTS="))
     (check-true (string-contains? activation (format "export PLTADDONDIR='~a'" (path->string addon-dir))))
     (expect (run-main (list "switch" "devsrc")) activation)
     @expect[(run-main '("prompt"))]{devsrc
}
     @expect[(run-main '("prompt" "--short"))]{devsrc
}
     @expect[(run-main '("prompt" "--long"))]{[rk:local-devsrc]
}
     @expect/shell[(list (path->string rackup-bin) "prompt" "--short")]{devsrc
}
     @expect/shell[(list (path->string rackup-bin) "prompt")]{devsrc
}
     (void (putenv "RACKUP_TOOLCHAIN" linked-id))
     (define deactivation (emit-shell-deactivation))
     (check-false (string-contains? deactivation "unset PLTHOME"))
     (check-false (string-contains? deactivation "unset PLTCOLLECTS"))
     (expect (run-main '("switch" "--unset")) deactivation)
     (void (putenv "RACKUP_TOOLCHAIN" ""))))

  ;; Test: linking a real source tree and running raco through the shim
  ;; should produce no "tool registered twice" warnings.
  ;; This test requires that the Racket running the tests is a source build;
  ;; if not, it is silently skipped.
  (let ()
    (define real-racket
      (simplify-path (resolve-path (find-system-path 'exec-file)) #t))
    (define real-bin-dir (let-values ([(d _ __) (split-path real-racket)]) d))
    (define plthome (and (path? real-bin-dir)
                         (let-values ([(d _ __) (split-path (simplify-path real-bin-dir))])
                           (and d (simplify-path d)))))
    (define source-root (and plthome
                             (let-values ([(d _ __) (split-path plthome)])
                               (and d (simplify-path d)))))
    (define pkgs-dir (and source-root (build-path source-root "pkgs")))
    (when (and source-root (directory-exists? (or pkgs-dir "")))
      (with-temp-rackup-home
       (lambda (_tmp)
         (ensure-index!)
         (define linked-id
           (link-toolchain! "realsrc" (path->string source-root) '("--set-default")))
         (with-state-lock (reshim!))
         (define raco-shim (build-path (rackup-shims-dir) "raco"))
         (define old-pltaddon (getenv "PLTADDONDIR"))
         (define old-pltcollects (getenv "PLTCOLLECTS"))
         (define old-toolchain (getenv "RACKUP_TOOLCHAIN"))
         (dynamic-wind
           (lambda ()
             (putenv "PLTADDONDIR" "")
             (putenv "PLTCOLLECTS" "")
             (putenv "RACKUP_TOOLCHAIN" ""))
           (lambda ()
             (define-values (proc stdout stdin stderr)
               (subprocess #f #f #f raco-shim "pkg" "show" "NOTAPACKAGE"))
             (close-output-port stdin)
             (subprocess-wait proc)
             (define err-str (port->string stderr))
             (close-input-port stdout)
             (close-input-port stderr)
             (check-false (regexp-match? #rx"warning:" err-str)
                          (format "raco through shim produced warnings:\n~a" err-str)))
           (lambda ()
             (if old-pltaddon (putenv "PLTADDONDIR" old-pltaddon) (putenv "PLTADDONDIR" ""))
             (if old-pltcollects (putenv "PLTCOLLECTS" old-pltcollects) (putenv "PLTCOLLECTS" ""))
             (if old-toolchain (putenv "RACKUP_TOOLCHAIN" old-toolchain)
                 (putenv "RACKUP_TOOLCHAIN" ""))))))))

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

     (define old-plthome (getenv "PLTHOME"))
     (define old-pltcollects (getenv "PLTCOLLECTS"))
     (void (putenv "PLTHOME" ""))
     (void (putenv "PLTCOLLECTS" ""))
     (define shim-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "racket")))))
     (void (if old-plthome
               (putenv "PLTHOME" old-plthome)
               (putenv "PLTHOME" "")))
     (void (if old-pltcollects
               (putenv "PLTCOLLECTS" old-pltcollects)
               (putenv "PLTCOLLECTS" "")))
     ;; PLTHOME and PLTCOLLECTS should NOT be set for linked toolchains
     (check-true (string-contains? shim-out "PLTHOME=\n"))
     (check-true (string-contains? shim-out "PLTCOLLECTS=\n"))
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
     (define old-pltcollects (getenv "PLTCOLLECTS"))
     (define old-pltaddondir (getenv "PLTADDONDIR"))
     (dynamic-wind
      (lambda ()
        (putenv "RACKUP_TOOLCHAIN" linked-id)
        (putenv "PLTCOLLECTS"
                (string-append (path->string poisoned-collects) ":" current-collects))
        (putenv "PLTADDONDIR" (path->string (build-path tmp "poisoned-addon"))))
      (lambda ()
        (expect (begin (system* rackup-bin "current" "id") (void))
                (format "~a\n" linked-id)))
      (lambda ()
        (if old-toolchain
            (putenv "RACKUP_TOOLCHAIN" old-toolchain)
            (putenv "RACKUP_TOOLCHAIN" ""))
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
       (capture-output (lambda () (cmd-runtime '("status")))))
     (check-true (string-contains? runtime-status-out "present: yes"))
     (check-true (string-contains? runtime-status-out (format "id: ~a" runtime-id)))

     (define doctor-out
       (capture-output (lambda () (doctor-report))))
     (check-true (string-contains? doctor-out "runtime-present: #t"))
     (check-true (string-contains? doctor-out (format "runtime-id: ~a" runtime-id)))))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-rackup-layout!)
     (define prefix (hidden-runtime-invocation-prefix "/tmp/fake-racket"))
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
     @expect/shell[(list (path->string rackup-bin) "current" "id")]{}
     (define argv
       (string-split (string-trim (file->string captured-argv)) "\n"))
     (check-equal? (take argv 3)
                   (list "-U"
                         "-A"
                         (path->string (rackup-runtime-addon-dir))))
     (check-true (string-suffix? (list-ref argv 3) "libexec/rackup-core.rkt"))
     (check-equal? (drop argv 4) '("current" "id"))))

  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-rackup-layout!)
     (define fake-bin-dir (build-path tmp "fake-system-bin"))
     (define captured-argv (build-path tmp "captured-system-runtime-argv.txt"))
     (define captured-env (build-path tmp "captured-system-runtime-env.txt"))
     (make-directory* fake-bin-dir)
     (define fake-racket (build-path fake-bin-dir "racket"))
     (write-string-file fake-racket
                        (string-append
                         "#!/usr/bin/env bash\n"
                         "set -euo pipefail\n"
                         "printf '%s\\n' \"$@\" > "
                         (path->string captured-argv)
                         "\n"
                         "printf 'PLTHOME=%s\\nPLTCOLLECTS=%s\\nPLTADDONDIR=%s\\n' "
                         "\"${PLTHOME:-}\" "
                         "\"${PLTCOLLECTS:-}\" "
                         "\"${PLTADDONDIR:-}\" > "
                         (path->string captured-env)
                         "\n"))
     (file-or-directory-permissions fake-racket #o755)
     (define env (environment-variables-copy (current-environment-variables)))
     (environment-variables-set! env
                                 #"PATH"
                                 (string->bytes/utf-8
                                  (string-append (path->string fake-bin-dir)
                                                 ":"
                                                 (or (getenv "PATH") "/usr/bin:/bin"))))
     ;; PLTHOME is not a Racket env var, so bin/rackup does not save/unset it.
     ;; It passes through to the subprocess unchanged.
     (environment-variables-set! env #"PLTHOME" #"poison-plthome")
     (environment-variables-set! env #"PLTCOLLECTS" #"poison-collects")
     (environment-variables-set! env #"PLTADDONDIR" #"poison-addon")
     (expect (parameterize ([current-environment-variables env])
               (system* rackup-bin "current" "id")
               (void))
             "" #:port 'both)
     (define argv
       (string-split (string-trim (file->string captured-argv)) "\n"))
     (check-equal? (take argv 4)
                   (list "-y"
                         "-U"
                         "-A"
                         (list-ref argv 3)))
     (check-false (string-prefix? (path->string (rackup-home)) (list-ref argv 3)))
     (check-true (directory-exists? (string->path (list-ref argv 3))))
     (check-true (string-suffix? (list-ref argv 4) "libexec/rackup-core.rkt"))
     (check-equal? (drop argv 5) '("current" "id"))
     (define env-lines (string-split (string-trim (file->string captured-env)) "\n"))
     ;; PLTHOME passes through (not a Racket env var); PLTCOLLECTS and
     ;; PLTADDONDIR are cleared by bin/rackup to protect its own runtime.
     (check-equal? env-lines
                   '("PLTHOME=poison-plthome"
                     "PLTCOLLECTS="
                     "PLTADDONDIR="))))

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
     (check-true (string-contains? msg "installer failed"))))

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
     (run-tgz-installer! archive dest)
     (check-true (directory-exists? (build-path dest "racket" "bin")))
     (check-true (file-exists? (build-path dest "racket" "bin" "racket")))))

  (with-temp-rackup-home
   (lambda (tmp)
     (define install-root (build-path tmp "plt-archive"))
     (make-directory* (build-path install-root "plt" "bin"))
     (check-equal? (path->string (detect-bin-dir install-root))
                   (path->string (build-path install-root "plt" "bin")))))

  ;; `rackup help <cmd>` and `rackup <cmd> --help` produce the same output.
  (check-equal? (capture-output (lambda () (run-main '("install" "--help"))))
                (capture-output (lambda () (run-main '("help" "install")))))
  (check-equal? (capture-output (lambda () (run-main '("switch" "--help"))))
                (capture-output (lambda () (run-main '("help" "switch")))))
  (check-equal? (capture-output (lambda () (run-main '("prompt" "--help"))))
                (capture-output (lambda () (run-main '("help" "prompt")))))
  (check-equal? (capture-output (lambda () (run-main '("self-upgrade" "--help"))))
                (capture-output (lambda () (run-main '("help" "self-upgrade")))))

  ;; Help output includes key flags/args for each command.
  (expect (run-main '("install" "--help")) "--variant" #:match 'contains)
  (expect (run-main '("install" "--help")) "--set-default" #:match 'contains)
  (expect (run-main '("install" "--help")) "--short-aliases" #:match 'contains)
  (expect (run-main '("install" "--help")) "<spec>" #:match 'contains)
  (expect (run-main '("switch" "--help")) "--unset" #:match 'contains)
  (expect (run-main '("prompt" "--help")) "--long" #:match 'contains)
  (expect (run-main '("prompt" "--help")) "--short" #:match 'contains)
  (expect (run-main '("prompt" "--help")) "--raw" #:match 'contains)
  (expect (run-main '("runtime" "--help")) "<subcommand>" #:match 'contains)
  (expect (run-main '("self-upgrade" "--help")) "--with-init" #:match 'contains)
  (expect (run-main '("self-upgrade" "--help")) "--exe" #:match 'contains)
  (expect (run-main '("self-upgrade" "--help")) "--source" #:match 'contains)

  ;; --help with other flags still shows help (original bug: reshim --help --short-aliases)
  (expect (run-main '("reshim" "--help" "--short-aliases")) "--short-aliases" #:match 'contains)
  (check-equal? (capture-output (lambda () (run-main '("reshim" "--help" "--short-aliases"))))
                (capture-output (lambda () (run-main '("reshim" "--help")))))

  ;; `rackup available --all` shows PLT Scheme versions section
  (let ([out (capture-output (lambda () (run-main '("available" "--all"))))])
    (check-true (string-contains? out "PLT Scheme versions")
                "available --all should include PLT Scheme section")
    (check-true (string-contains? out "4.2.5")
                "available --all should include legacy version 4.2.5")
    (check-true (string-contains? out "053")
                "available --all should include legacy version 053"))

  ;; `rackup available` (default limit) does NOT show PLT Scheme versions
  (let ([out (capture-output (lambda () (run-main '("available"))))])
    (check-false (string-contains? out "PLT Scheme versions")
                 "available without --all should not include PLT Scheme section"))

  ;; install accepts flags before or after the spec
  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     ;; spec before flag
     (expect (run-main '("install" "stable" "--set-default")) "Installed" #:match 'contains)
     ;; flag before spec
     (expect (run-main '("install" "--force" "stable")) "Installed" #:match 'contains)
     ;; interleaved flags around spec
     (expect (run-main '("install" "--force" "stable" "--set-default")) "Installed" #:match 'contains)))

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
     (with-state-lock (register-toolchain! id meta))
     (expect (run-main '("current" "id")) (format "~a\n" id))
     @expect[(run-main '("current" "source"))]{default
}
     (expect (run-main '("current" "line")) (format "~a\tdefault\n" id))
     (expect (run-main '("default" "id")) (format "~a\n" id))
     (expect (run-main '("default" "status")) (format "set\t~a\n" id))
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" id))
      (lambda ()
        @expect[(run-main '("current" "source"))]{env
}
        (expect (run-main '("current" "line")) (format "~a\tenv\n" id)))
     (lambda ()
        (if old-env-id
            (putenv "RACKUP_TOOLCHAIN" old-env-id)
            (putenv "RACKUP_TOOLCHAIN" ""))))
     @expect[(run-main '("default" "clear"))]{Cleared default toolchain.
}
     @expect[(run-main '("default" "status"))]{unset
}))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
      (lambda ()
        (define list-out (capture-output (lambda () (run-main '("list")))))
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
     (with-state-lock
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
       (reshim!))
     (define old-env-id (getenv "RACKUP_TOOLCHAIN"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_TOOLCHAIN" "release-103-bc-i386-linux-full"))
      (lambda ()
        (define shim-cmd (list (path->string (build-path (rackup-shims-dir) "racket")) "--version"))
        (expect/shell shim-cmd #:status 127
                      #:port 'stderr #:match 'contains
                      "rackup: executable 'racket' not found in toolchain 'release-103-bc-i386-linux-full'")
        (expect/shell shim-cmd #:status 127
                      #:port 'stderr #:match 'contains
                      "rackup: active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain 'release-8.18-cs-x86_64-linux-full'.")
        (expect/shell shim-cmd #:status 127
                      #:port 'stderr #:match 'contains
                      "Clear it with: rackup switch --unset")
        (expect/shell shim-cmd #:status 127
                      #:port 'stderr #:match 'contains
                      "Or unset it manually with: unset RACKUP_TOOLCHAIN")
        (expect/shell shim-cmd #:status 127
                      #:port 'stderr #:match 'contains
                      "Try: rackup which racket --toolchain release-103-bc-i386-linux-full"))
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
     (expect (run-main '("remove" "5.2"))
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
        (expect (run-main '("self-upgrade"))
                "Checking for updates...\n")
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

  ;; self-upgrade prints completion message when SHA changes (i.e. actual update)
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define fake-installer (build-path tmp "fake-install-update.sh"))
     (define sha-file (build-path tmp ".installed-sha256"))
     (write-string-file sha-file "old-sha")
     (write-string-file
      fake-installer
      (format
       "#!/bin/sh\nset -eu\nprintf 'new-sha' > ~s\nexit 0\n"
       (path->string sha-file)))
     (file-or-directory-permissions fake-installer #o755)
     (define old-override (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" (path->string fake-installer)))
      (lambda ()
        (expect (run-main '("self-upgrade"))
                "Checking for updates...\nrackup code upgrade complete.\n"))
      (lambda ()
        (if old-override
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" old-override)
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" ""))))))

  ;; self-upgrade --exe forwards to install.sh
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define fake-installer (build-path tmp "fake-install-exe.sh"))
     (define args-log (build-path tmp "self-upgrade-exe-args.log"))
     (write-string-file
      fake-installer
      (format
       "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$@\" > ~s\nexit 0\n"
       (path->string args-log)))
     (file-or-directory-permissions fake-installer #o755)
     (define old-override (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" (path->string fake-installer)))
      (lambda ()
        (run-main '("self-upgrade" "--exe"))
        (let ([args-lines
               (call-with-input-file args-log
                 (lambda (in) (filter (lambda (s) (not (string=? s ""))) (port->lines in))))])
          (check-equal? args-lines
                        (list "-y" "--no-init" "--exe" "--prefix" (path->string (rackup-home)))))
        ;; Also verify --source
        (run-main '("self-upgrade" "--source"))
        (let ([args-lines
               (call-with-input-file args-log
                 (lambda (in) (filter (lambda (s) (not (string=? s ""))) (port->lines in))))])
          (check-equal? args-lines
                        (list "-y" "--no-init" "--source" "--prefix" (path->string (rackup-home))))))
      (lambda ()
        (if old-override
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" old-override)
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" ""))))))

  ;; Metadata-parts matching: "9.0-minimal" should resolve when both full and minimal exist
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (define (register-fake-toolchain! id version variant distribution)
       (define tc-dir (rackup-toolchain-dir id))
       (define install-root (rackup-toolchain-install-dir id))
       (define real-bin (build-path install-root "bin"))
       (make-directory* real-bin)
       (define racket-exe (build-path real-bin "racket"))
       (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
       (file-or-directory-permissions racket-exe #o755)
       (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
       (with-state-lock
         (register-toolchain! id
                              (hash 'id id
                                    'kind 'release
                                    'requested-spec version
                                    'resolved-version version
                                    'variant variant
                                    'distribution distribution
                                    'arch "x86_64"
                                    'platform "linux"
                                    'executables '("racket")
                                    'installed-at "2026-02-26T00:00:00Z"))))

     (define id-full "release-9.0-cs-x86_64-linux-full")
     (define id-minimal "release-9.0-cs-x86_64-linux-minimal")
     (register-fake-toolchain! id-full "9.0" 'cs 'full)
     (register-fake-toolchain! id-minimal "9.0" 'cs 'minimal)

     ;; "9.0" alone matches both, but prefers "full" distribution
     (check-equal? (find-local-toolchain "9.0") id-full)
     ;; "9.0-minimal" disambiguates via metadata parts
     (check-equal? (find-local-toolchain "9.0-minimal") id-minimal)
     ;; "9.0-full" disambiguates the other way
     (check-equal? (find-local-toolchain "9.0-full") id-full)
     ;; "9.0-cs-minimal" also works
     (check-equal? (find-local-toolchain "9.0-cs-minimal") id-minimal)
     ;; "9.0-bc" doesn't match anything (no bc toolchain installed)
     (check-false (find-local-toolchain "9.0-bc"))
     ;; Exact match still works
     (check-equal? (find-local-toolchain id-full) id-full)
     (check-equal? (find-local-toolchain id-minimal) id-minimal)))

  ;; Unit test: restore-saved-racket-env-vars! restores saved vars and cleans up
  (let ([env (environment-variables-copy (current-environment-variables))])
    ;; Simulate what bin/rackup does: save as _RACKUP_ORIG_*, clear originals
    (environment-variables-set! env #"PLTCOMPILEDROOTS" #f)
    (environment-variables-set! env #"PLTUSERHOME" #f)
    (environment-variables-set! env #"_RACKUP_ORIG_PLTCOMPILEDROOTS" #"test-roots")
    (environment-variables-set! env #"_RACKUP_ORIG_PLTUSERHOME" #"test-home")
    (restore-saved-racket-env-vars! env)
    (check-equal? (environment-variables-ref env #"PLTCOMPILEDROOTS") #"test-roots"
                  "PLTCOMPILEDROOTS should be restored")
    (check-equal? (environment-variables-ref env #"PLTUSERHOME") #"test-home"
                  "PLTUSERHOME should be restored")
    (check-false (environment-variables-ref env #"_RACKUP_ORIG_PLTCOMPILEDROOTS")
                 "_RACKUP_ORIG_ prefix should be removed")
    (check-false (environment-variables-ref env #"_RACKUP_ORIG_PLTUSERHOME")
                 "_RACKUP_ORIG_ prefix should be removed"))

  ;; Unit test: restore cleans _RACKUP_ORIG_ even when no saved value exists
  (let ([env (environment-variables-copy (current-environment-variables))])
    (environment-variables-set! env #"PLTCOMPILEDROOTS" #f)
    (environment-variables-set! env #"_RACKUP_ORIG_PLTCOMPILEDROOTS" #f)
    (restore-saved-racket-env-vars! env)
    (check-false (environment-variables-ref env #"PLTCOMPILEDROOTS")
                 "unsaved var should remain unset")
    (check-false (environment-variables-ref env #"_RACKUP_ORIG_PLTCOMPILEDROOTS")
                 "_RACKUP_ORIG_ should be cleaned up"))

  ;; Helper: set up a hidden runtime in temp RACKUP_HOME so bin/rackup
  ;; can find a real racket binary (the system racket may be a wrapper
  ;; script that requires PLTHOME).
  (define (setup-hidden-runtime! tmp)
    (define runtime-id "runtime-test-env")
    (define runtime-version-dir (rackup-runtime-version-dir runtime-id))
    (define runtime-real-bin (build-path tmp "runtime-real-bin"))
    (make-directory* runtime-real-bin)
    (make-file-or-directory-link (find-system-path 'exec-file)
                                 (build-path runtime-real-bin "racket"))
    (make-directory* runtime-version-dir)
    (make-file-or-directory-link runtime-real-bin (rackup-runtime-bin-link runtime-id))
    (make-file-or-directory-link runtime-version-dir (rackup-runtime-current-link)))

  ;; Integration test: poisoned Racket env vars don't affect rackup itself
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (setup-hidden-runtime! tmp)
     (define id "release-9.0-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
     (file-or-directory-permissions racket-exe #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (with-state-lock
       (register-toolchain! id
                            (hash 'id id 'kind 'release 'requested-spec "9.0"
                                  'resolved-version "9.0" 'variant 'cs 'distribution 'full
                                  'arch "x86_64" 'platform "linux"
                                  'executables '("racket") 'installed-at "2026-02-26T00:00:00Z")))

     ;; Poison all sanitized Racket env vars
     (define saved-vars
       (for/list ([var (in-list sanitized-racket-env-vars)])
         (cons var (getenv var))))
     (dynamic-wind
      (lambda ()
        (for ([var sanitized-racket-env-vars])
          (putenv var "/nonexistent/poisoned")))
      (lambda ()
        ;; rackup list should still work
        (expect (begin (system* rackup-bin "list") (void))
                "release-9.0" #:match 'contains))
      (lambda ()
        (for ([kv saved-vars])
          (if (cdr kv)
              (putenv (car kv) (cdr kv))
              (putenv (car kv) "")))))))

  ;; ---- Upgrade path tests ----
  ;; Simulate a 9.0 installation, then "upgrade" by adding 9.1 alongside it.
  ;; Verify both toolchains coexist and the default can be changed.
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     ;; Helper to register a fake toolchain with a working shim
     (define (register-fake-versioned-toolchain! id version spec)
       (define install-root (rackup-toolchain-install-dir id))
       (define real-bin (build-path install-root "bin"))
       (make-directory* real-bin)
       (define racket-exe (build-path real-bin "racket"))
       (write-string-file racket-exe
                          (format "#!/usr/bin/env bash\nprintf '~a'\n" version))
       (file-or-directory-permissions racket-exe #o755)
       (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
       (with-state-lock
         (register-toolchain! id
                              (hash 'id id
                                    'kind 'release
                                    'requested-spec spec
                                    'resolved-version version
                                    'variant 'cs
                                    'distribution 'full
                                    'arch "x86_64"
                                    'platform "linux"
                                    'snapshot-site #f
                                    'snapshot-stamp #f
                                    'installer-url (format "https://example.invalid/racket-~a.sh" version)
                                    'installer-filename (format "racket-~a-x86_64-linux-cs.sh" version)
                                    'install-root (path->string install-root)
                                    'bin-link (path->string (rackup-toolchain-bin-link id))
                                    'real-bin-dir (path->string real-bin)
                                    'executables '("racket")
                                    'installed-at "2026-01-15T00:00:00Z"))))

     ;; Step 1: Install 9.0 as the initial toolchain (simulating prior state)
     (define id-90 "release-9.0-cs-x86_64-linux-full")
     (register-fake-versioned-toolchain! id-90 "9.0" "stable")
     (check-equal? (get-default-toolchain) id-90)
     (check-equal? (installed-toolchain-ids) (list id-90))

     ;; Verify 9.0 state is consistent
     (define meta-90 (read-toolchain-meta id-90))
     (check-equal? (hash-ref meta-90 'resolved-version) "9.0")
     (check-equal? (hash-ref meta-90 'kind) 'release)

     ;; Step 2: "Upgrade" by installing 9.1 alongside 9.0
     (define id-91 "release-9.1-cs-x86_64-linux-full")
     (register-fake-versioned-toolchain! id-91 "9.1" "stable")

     ;; Both should be present
     (check-equal? (installed-toolchain-ids)
                   (sort (list id-90 id-91) string<?))

     ;; Default should still be 9.0 (first installed)
     (check-equal? (get-default-toolchain) id-90)

     ;; Switch default to 9.1
     (with-state-lock (set-default-toolchain! id-91))
     (check-equal? (get-default-toolchain) id-91)

     ;; Verify both toolchains have valid metadata
     (define meta-91 (read-toolchain-meta id-91))
     (check-equal? (hash-ref meta-91 'resolved-version) "9.1")

     ;; list command should show both
     (define list-out (capture-output (lambda () (run-main '("list")))))
     (check-true (string-contains? list-out "release-9.0-cs-x86_64-linux-full"))
     (check-true (string-contains? list-out "release-9.1-cs-x86_64-linux-full"))
     (check-true (string-contains? list-out "[default,active,stable]"))

     ;; Reshim and verify shim dispatches to 9.1 (the new default)
     (with-state-lock (reshim!))
     (define shim-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "racket")))))
     (check-true (string-contains? shim-out "9.1"))

     ;; Remove 9.0 and verify 9.1 remains as default
     (remove-toolchain! id-90)
     (check-equal? (installed-toolchain-ids) (list id-91))
     (check-equal? (get-default-toolchain) id-91)

     ;; Prompt should reflect 9.1
     @expect[(run-main '("prompt"))]{racket-9.1
}))

  ;; Upgrade path: verify old-format index (missing keys) is handled gracefully
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-rackup-layout!)
     ;; Write a minimal old-format index that lacks the 'aliases key
     (write-rktd-file (rackup-index-file)
                      (hash 'installed-toolchains (hash) 'default-toolchain #f))
     ;; load-index should normalize it without error
     (define idx (load-index))
     (check-true (hash? idx))
     (check-equal? (hash-ref idx 'aliases) (hash))
     (check-equal? (installed-toolchain-ids idx) null)

     ;; Write an even more minimal index (just a hash with installed-toolchains)
     (write-rktd-file (rackup-index-file)
                      (hash 'installed-toolchains (hash)))
     (define idx2 (load-index))
     (check-true (hash? idx2))
     (check-equal? (hash-ref idx2 'aliases) (hash))
     (check-equal? (hash-ref idx2 'default-toolchain) #f)

     ;; ensure-index! on top of existing state should preserve it
     (define id "release-9.0-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (write-string-file (build-path real-bin "racket") "#!/usr/bin/env bash\nexit 0\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (with-state-lock
       (register-toolchain! id
                            (hash 'id id 'kind 'release 'requested-spec "9.0"
                                  'resolved-version "9.0" 'variant 'cs 'distribution 'full
                                  'arch "x86_64" 'platform "linux"
                                  'executables '("racket") 'installed-at "2026-01-15T00:00:00Z")))
     ;; Re-run ensure-index! (simulating what happens after self-upgrade)
     (define idx3 (ensure-index!))
     (check-true (toolchain-exists? id idx3))
     (check-equal? (get-default-toolchain idx3) id)))

  ;; Upgrade path: self-upgrade preserves state when install.sh reruns
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     ;; Set up a pre-existing 9.0 installation
     (define id-90 "release-9.0-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id-90))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (write-string-file (build-path real-bin "racket") "#!/usr/bin/env bash\necho 9.0\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id-90))
     (with-state-lock
       (register-toolchain! id-90
                            (hash 'id id-90 'kind 'release 'requested-spec "stable"
                                  'resolved-version "9.0" 'variant 'cs 'distribution 'full
                                  'arch "x86_64" 'platform "linux"
                                  'snapshot-site #f 'snapshot-stamp #f
                                  'installer-url "https://example.invalid/racket-9.0.sh"
                                  'installer-filename "racket-9.0-x86_64-linux-cs.sh"
                                  'install-root (path->string install-root)
                                  'bin-link (path->string (rackup-toolchain-bin-link id-90))
                                  'real-bin-dir (path->string real-bin)
                                  'executables '("racket")
                                  'installed-at "2026-01-15T00:00:00Z")))

     ;; Fake the self-upgrade: a script that just touches a marker file
     ;; but doesn't modify state (simulating install.sh --prefix preserving state)
     (define fake-installer (build-path tmp "fake-upgrade-install.sh"))
     (define marker-file (build-path tmp "upgrade-ran.marker"))
     (write-string-file
      fake-installer
      (format "#!/bin/sh\nset -eu\ntouch ~s\n" (path->string marker-file)))
     (file-or-directory-permissions fake-installer #o755)

     (define old-override (getenv "RACKUP_SELF_UPGRADE_INSTALL_SH"))
     (dynamic-wind
      (lambda () (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" (path->string fake-installer)))
      (lambda ()
        (run-main '("self-upgrade"))
        ;; Verify the upgrade script ran
        (check-true (file-exists? marker-file))
        ;; Verify state is preserved after upgrade
        (check-equal? (get-default-toolchain) id-90)
        (check-true (toolchain-exists? id-90))
        (define meta (read-toolchain-meta id-90))
        (check-equal? (hash-ref meta 'resolved-version) "9.0"))
      (lambda ()
        (if old-override
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" old-override)
            (putenv "RACKUP_SELF_UPGRADE_INSTALL_SH" ""))))))

  ;; ---- Snapshot site tests: Utah and Northwestern ----
  ;; Test that both Utah and Northwestern snapshot toolchains can be registered
  ;; and coexist with correct metadata
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)

     (define (register-fake-snapshot! site stamp version)
       (define id (canonical-toolchain-id 'snapshot
                                          #:resolved-version version
                                          #:variant 'cs
                                          #:arch "x86_64"
                                          #:distribution 'full
                                          #:snapshot-site site
                                          #:snapshot-stamp stamp))
       (define install-root (rackup-toolchain-install-dir id))
       (define real-bin (build-path install-root "bin"))
       (make-directory* real-bin)
       (define racket-exe (build-path real-bin "racket"))
       (write-string-file racket-exe
                          (format "#!/usr/bin/env bash\nprintf '~a (~a)'\n" version site))
       (file-or-directory-permissions racket-exe #o755)
       (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
       (with-state-lock
         (register-toolchain! id
                              (hash 'id id
                                    'kind 'snapshot
                                    'requested-spec (format "snapshot:~a" site)
                                    'resolved-version version
                                    'variant 'cs
                                    'distribution 'full
                                    'arch "x86_64"
                                    'platform "linux"
                                    'snapshot-site site
                                    'snapshot-stamp stamp
                                    'installer-url (format "https://~a.example/snapshots/~a/racket.sh" site stamp)
                                    'installer-filename (format "racket-~a-x86_64-linux-cs.sh" version)
                                    'install-root (path->string install-root)
                                    'bin-link (path->string (rackup-toolchain-bin-link id))
                                    'real-bin-dir (path->string real-bin)
                                    'executables '("racket")
                                    'installed-at "2026-03-01T00:00:00Z")))
       id)

     ;; Register a Utah snapshot
     (define utah-id
       (register-fake-snapshot! 'utah "2026-02-26-26be534ac9" "9.1.0.7"))

     ;; Register a Northwestern snapshot
     (define nw-id
       (register-fake-snapshot! 'northwestern "2026-02-25-abcdef1234" "9.1.0.6"))

     ;; Both should be registered with distinct IDs
     (check-not-equal? utah-id nw-id)
     (check-true (string-contains? utah-id "utah"))
     (check-true (string-contains? nw-id "northwestern"))

     ;; Both should be in the installed list
     (check-true (toolchain-exists? utah-id))
     (check-true (toolchain-exists? nw-id))
     (check-equal? (length (installed-toolchain-ids)) 2)

     ;; Verify metadata distinguishes them
     (define utah-meta (read-toolchain-meta utah-id))
     (define nw-meta (read-toolchain-meta nw-id))
     (check-equal? (hash-ref utah-meta 'snapshot-site) 'utah)
     (check-equal? (hash-ref utah-meta 'snapshot-stamp) "2026-02-26-26be534ac9")
     (check-equal? (hash-ref utah-meta 'resolved-version) "9.1.0.7")
     (check-equal? (hash-ref nw-meta 'snapshot-site) 'northwestern)
     (check-equal? (hash-ref nw-meta 'snapshot-stamp) "2026-02-25-abcdef1234")
     (check-equal? (hash-ref nw-meta 'resolved-version) "9.1.0.6")

     ;; Set Utah as default, verify shim resolves to it
     (with-state-lock
       (set-default-toolchain! utah-id)
       (reshim!))
     (define shim-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "racket")))))
     (check-true (string-contains? shim-out "9.1.0.7 (utah)"))

     ;; Switch to Northwestern, verify
     (with-state-lock
       (set-default-toolchain! nw-id)
       (reshim!))
     (define shim-out2
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "racket")))))
     (check-true (string-contains? shim-out2 "9.1.0.6 (northwestern)"))

     ;; list output should show both snapshots
     (define list-out (capture-output (lambda () (run-main '("list")))))
     (check-true (string-contains? list-out "snapshot-utah"))
     (check-true (string-contains? list-out "snapshot-northwestern"))

     ;; prompt should reflect snapshot
     @expect[(run-main '("prompt" "--short"))]{racket-snapshot-9.1.0.6
}))

  ;; Test upgrade path with snapshots: old Utah snapshot -> new Utah snapshot
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)

     (define (make-snapshot-toolchain! stamp version)
       (define id (canonical-toolchain-id 'snapshot
                                          #:resolved-version version
                                          #:variant 'cs
                                          #:arch "x86_64"
                                          #:distribution 'full
                                          #:snapshot-site 'utah
                                          #:snapshot-stamp stamp))
       (define install-root (rackup-toolchain-install-dir id))
       (define real-bin (build-path install-root "bin"))
       (make-directory* real-bin)
       (write-string-file (build-path real-bin "racket")
                          (format "#!/usr/bin/env bash\nprintf '~a'\n" version))
       (file-or-directory-permissions (build-path real-bin "racket") #o755)
       (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
       (with-state-lock
         (register-toolchain! id
                              (hash 'id id
                                    'kind 'snapshot
                                    'requested-spec "snapshot:utah"
                                    'resolved-version version
                                    'variant 'cs
                                    'distribution 'full
                                    'arch "x86_64"
                                    'platform "linux"
                                    'snapshot-site 'utah
                                    'snapshot-stamp stamp
                                    'installer-url (format "https://utah.example/snapshots/~a/racket.sh" stamp)
                                    'installer-filename (format "racket-~a-x86_64-linux-cs.sh" version)
                                    'install-root (path->string install-root)
                                    'bin-link (path->string (rackup-toolchain-bin-link id))
                                    'real-bin-dir (path->string real-bin)
                                    'executables '("racket")
                                    'installed-at "2026-03-01T00:00:00Z")))
       id)

     ;; Install old snapshot
     (define old-id (make-snapshot-toolchain! "2026-02-20-old1234" "9.1.0.3"))
     (check-equal? (get-default-toolchain) old-id)

     ;; "Upgrade" by installing newer snapshot
     (define new-id (make-snapshot-toolchain! "2026-02-26-new5678" "9.1.0.7"))

     ;; Both should exist with distinct IDs (different stamps)
     (check-not-equal? old-id new-id)
     (check-equal? (length (installed-toolchain-ids)) 2)

     ;; Switch to new snapshot
     (with-state-lock
       (set-default-toolchain! new-id)
       (reshim!))
     (define shim-out
       (capture-output
        (lambda () (system* (build-path (rackup-shims-dir) "racket")))))
     (check-true (string-contains? shim-out "9.1.0.7"))

     ;; Remove old snapshot, verify new one is unaffected
     (remove-toolchain! old-id)
     (check-equal? (installed-toolchain-ids) (list new-id))
     (check-equal? (get-default-toolchain) new-id)))

  ;; Integration test: env vars pass through to rackup run subprocesses
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (setup-hidden-runtime! tmp)
     (define id "release-9.0-cs-x86_64-linux-full")
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
     (file-or-directory-permissions racket-exe #o755)
     (define print-env (build-path real-bin "print-compiled-roots"))
     (write-string-file print-env
                        "#!/usr/bin/env bash\nprintf 'PLTCOMPILEDROOTS=%s\\n' \"${PLTCOMPILEDROOTS:-}\"\n")
     (file-or-directory-permissions print-env #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (with-state-lock
       (register-toolchain! id
                            (hash 'id id 'kind 'release 'requested-spec "9.0"
                                  'resolved-version "9.0" 'variant 'cs 'distribution 'full
                                  'arch "x86_64" 'platform "linux"
                                  'executables '("racket" "print-compiled-roots")
                                  'installed-at "2026-02-26T00:00:00Z")))

     (define old-cr (getenv "PLTCOMPILEDROOTS"))
     (dynamic-wind
      (lambda ()
        (putenv "PLTCOMPILEDROOTS" "test-compiled-roots-passthrough"))
      (lambda ()
        (expect (begin (apply system* rackup-bin (list "run" id "--" "print-compiled-roots")) (void))
                "PLTCOMPILEDROOTS=test-compiled-roots-passthrough" #:match 'contains))
      (lambda ()
        (if old-cr
            (putenv "PLTCOMPILEDROOTS" old-cr)
            (putenv "PLTCOMPILEDROOTS" ""))))))
