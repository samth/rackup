#lang at-exp racket/base

(require rackunit
         recspecs
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         "../libexec/rackup/main.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/state.rkt"
         (submod "../libexec/rackup/main.rkt" for-testing))

(define-runtime-path repo-root "..")

(define tmp-root (string->path "/tmp"))

(define (with-temp-rackup-home proc)
  (define tmp-home (make-temporary-file "rackup-uninstall-home-~a" 'directory tmp-root))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string tmp-home)))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-environment-variables env])
       (proc tmp-home)))
   (lambda ()
     (delete-directory/files tmp-home #:must-exist? #f))))


(module+ test
  (check-exn #px"unsafe rackup home target: /"
             (lambda () (validate-uninstall-home-path! (string->path "/"))))
  (check-exn #px"unsafe rackup home target equal to your home directory"
             (lambda () (validate-uninstall-home-path! (find-system-path 'home-dir))))
  (let ([env (environment-variables-copy (current-environment-variables))]
        [env-home (build-path repo-root "tmp-uninstall-home-guard")])
    (environment-variables-set! env #"HOME" (string->bytes/utf-8 (path->string env-home)))
    (parameterize ([current-environment-variables env])
      (check-exn #px"unsafe rackup home target equal to your home directory"
                 (lambda () (validate-uninstall-home-path! env-home)))))
  (parameterize ([current-directory repo-root])
    (check-exn #px"unsafe rackup home target equal to the current directory"
               (lambda () (validate-uninstall-home-path! (string->path ".")))))

  (define delete-home (make-temporary-file "rackup-uninstall-delete-~a" 'directory tmp-root))
  (call-with-output-file* (build-path delete-home "keep.txt")
    #:exists 'truncate/replace
    (lambda (out)
      (display "ok" out)))
  (delete-rackup-home!/external delete-home)
  (check-false (directory-exists? delete-home))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn #px"refusing to uninstall without interactive confirmation"
                (lambda ()
                  (parameterize ([current-input-port (open-input-string "")])
                    (cmd-uninstall null))))))

  (with-temp-rackup-home
   (lambda (tmp-home)
     (ensure-index!)
     (define removed-rcs null)
     (define rm-args #f)
     (make-directory* tmp-home)
      (let-values ([(out err)
                   (parameterize ([current-remove-shell-init-blocks-proc
                                   (lambda ()
                                     (set! removed-rcs (list (build-path tmp-home "dummy.rc")))
                                     removed-rcs)]
                                  [current-uninstall-system*-proc
                                   (lambda args
                                     (set! rm-args args)
                                     #t)])
                     (capture-output/split (lambda () (cmd-uninstall '("--yes")))))])
       (check-equal? (map (lambda (v) (if (path? v) (path->string v) v)) rm-args)
                     (list (path->string (or (find-executable-path "rm") (string->path "/bin/rm")))
                           "-rf"
                           (path->string (rackup-home))))
       (check-true (string-contains? out "rackup uninstalled."))
       (check-true (string-contains? out "Rackup home deletion completed synchronously."))
       (check-false (string-contains? out "Final file deletion may complete shortly"))
       (check-true (string-contains? out "dummy.rc"))
       (check-true (string-contains? err "WARNING:")))))

  (with-temp-rackup-home
   (lambda (tmp-home)
     (ensure-index!)
     (make-directory* tmp-home)
     (define uninstall-out
       (capture-output
        (lambda ()
          (parameterize ([current-remove-shell-init-blocks-proc (lambda () null)]
                         [current-uninstall-system*-proc (lambda _args #f)])
            (check-exn #px"failed to delete rackup home synchronously"
                       (lambda () (cmd-uninstall '("--yes"))))))))
     (check-false (string-contains? uninstall-out "rackup uninstalled."))))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (ensure-index!)
     (define id "local-dev")
     (define source-path "/tmp/external-racket-tree")
     (register-toolchain!
      id
      (hash 'id id
            'kind 'local
            'requested-spec "dev"
            'resolved-version "local"
            'variant 'cs
            'distribution 'in-place
            'arch "x86_64"
            'platform "linux"
            'source-path source-path
            'executables '("racket")
            'installed-at "2026-02-28T00:00:00Z"))
     (let-values ([(out err)
                   (parameterize ([current-remove-shell-init-blocks-proc (lambda () null)]
                                  [current-uninstall-system*-proc (lambda _args #t)])
                     (capture-output/split (lambda () (cmd-uninstall '("--yes")))))])
       (check-true (string-contains? err "Linked local source trees will NOT be deleted"))
       (check-true (string-contains? err source-path))
       (check-true (string-contains? out "rackup uninstalled.")))))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (ensure-index!)
     (register-toolchain!
      "release-good"
      (hash 'id "release-good"
            'kind 'release
            'resolved-version "9.1"
            'variant 'cs
            'distribution 'full
            'arch "x86_64"
            'platform "linux"
            'executables '("racket")
            'installed-at "2026-02-28T00:00:00Z"))
     (register-toolchain!
      "release-bad"
      (hash 'id "release-bad"
            'kind 'release
            'resolved-version "8.18"
            'variant 'cs
            'distribution 'full
            'arch "x86_64"
            'platform "linux"
            'executables '("racket")
            'installed-at "2026-02-28T00:00:00Z"))
     (write-string-file (rackup-toolchain-meta-file "release-bad") "not-rktd")
     (define metas (installed-toolchain-metas/safe))
     (check-equal? (length metas) 1)
     (check-true (hash? (car metas))))))
