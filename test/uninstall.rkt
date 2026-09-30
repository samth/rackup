#lang at-exp racket/base

(require rackunit
         recspecs
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         "../libexec/rackup/main.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt"
         (submod "../libexec/rackup/main.rkt" for-testing))

(define-runtime-path repo-root "..")

(define tmp-root (string->path "/tmp"))

(define-runtime-path rackup-bin "../bin/rackup")

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

;; Run cmd-uninstall with shell-init and mac-app cleanup stubbed out.
;; Returns (values exit-status out err); exit-status is the status
;; cmd-uninstall asked to exit with, or #f if it returned without one.
(define (run-uninstall args
                       #:tty [tty #f]
                       #:remove-rcs [remove-rcs (lambda () null)])
  (define status #f)
  (define-values (out err)
    (parameterize ([current-remove-shell-init-blocks-proc remove-rcs]
                   [current-uninstall-system*-proc (lambda _args #t)]
                   [current-uninstall-exit-proc (lambda (c) (set! status c))]
                   [current-open-user-tty
                    (or tty (lambda () (error "no /dev/tty in tests")))]
                   [current-input-port (open-input-string "")])
      (capture-output/split (lambda () (cmd-uninstall args)))))
  (values status out err))

(define (flag-args home)
  (list "--dangerously-delete-without-prompting" (path->string home)))

;; A fake /dev/tty whose user types `answer`; the prompt goes to `prompt-out`.
(define (fake-tty answer prompt-out)
  (lambda () (values (open-input-string (string-append answer "\n")) prompt-out)))

;; The code the next (random 9000) under `seed` produces in the prompt.
(define (expected-code seed)
  (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
    (random-seed seed)
    (format "DELETE-~a" (+ 1000 (random 9000)))))


(module+ test
  ;; Regression: RACKUP_UNINSTALL_REQUEST_FILE env var should have no effect
  (with-temp-rackup-home
   (lambda (tmp-home)
     (ensure-index!)
     (define env (current-environment-variables))
     (environment-variables-set! env #"RACKUP_UNINSTALL_REQUEST_FILE" #"/tmp/evil-sink")
     (run-uninstall (flag-args tmp-home))
     ;; The poisoned file should NOT have been written
     (check-false (file-exists? (string->path "/tmp/evil-sink")))))

  ;; Path validation
  (check-exn #px"control characters"
             (lambda () (validate-uninstall-home-path! (string->path "/tmp/x\n/etc"))))
  (check-exn #px"control characters"
             (lambda () (validate-uninstall-home-path! (string->path "/tmp/x\ty"))))
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

  ;; delete-rackup-home!/external actually deletes
  (define delete-home (make-temporary-file "rackup-uninstall-delete-~a" 'directory tmp-root))
  (call-with-output-file* (build-path delete-home "keep.txt")
    #:exists 'truncate/replace
    (lambda (out)
      (display "ok" out)))
  (delete-rackup-home!/external delete-home)
  (check-false (directory-exists? delete-home))

  ;; No terminal: refuse, and never signal the wrapper to delete.
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn #px"refusing to uninstall without an interactive terminal"
                (lambda () (run-uninstall null)))))

  ;; Piping or typing a fixed word does not confirm: the code changes per run.
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn #px"uninstall aborted"
                (lambda ()
                  (run-uninstall null #:tty (fake-tty "DELETE" (open-output-nowhere)))))))

  ;; Typing the prompted code on the terminal confirms.
  (with-temp-rackup-home
   (lambda (tmp-home)
     (ensure-index!)
     (define prompt (open-output-string))
     (define-values (status out _err)
       (parameterize ([current-pseudo-random-generator (make-pseudo-random-generator)])
         (random-seed 7)
         (run-uninstall null #:tty (fake-tty (expected-code 7) prompt))))
     (check-true (string-contains? (get-output-string prompt) (expected-code 7))
                 "the prompt shows the code on the terminal")
     (check-equal? status uninstall-confirmed-exit-code)
     (check-true (string-contains? out "rackup uninstalled."))))

  ;; The flag must name RACKUP_HOME exactly.
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn #px"pass that exact path to confirm"
                (lambda () (run-uninstall (flag-args (string->path "/tmp/not-rackup-home")))))))
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn #px"option needs 1 argument"
                (lambda () (run-uninstall '("--dangerously-delete-without-prompting"))))))

  ;; cmd-uninstall does confirmation + RC cleanup + output, then signals the
  ;; wrapper (which does the deletion).
  (with-temp-rackup-home
   (lambda (tmp-home)
     (ensure-index!)
     (make-directory* tmp-home)
     (define-values (status out err)
       (run-uninstall (flag-args tmp-home)
                      #:remove-rcs (lambda () (list (build-path tmp-home "dummy.rc")))))
     (check-equal? status uninstall-confirmed-exit-code)
     (check-true (string-contains? out "rackup uninstalled."))
     (check-true (string-contains? out "dummy.rc"))
     (check-true (string-contains? err "WARNING:"))))

  ;; Linked local toolchain warning
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (ensure-index!)
     (define id "local-dev")
     (define source-path "/tmp/external-racket-tree")
     (with-state-lock
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
             'installed-at "2026-02-28T00:00:00Z")))
     (define-values (_status out err) (run-uninstall (flag-args _tmp-home)))
     (check-true (string-contains? err "Linked local source trees will NOT be deleted"))
     (check-true (string-contains? err source-path))
     (check-true (string-contains? out "rackup uninstalled."))))

  ;; Corrupt meta test
  (with-temp-rackup-home
   (lambda (_tmp-home)
     (ensure-index!)
     (with-state-lock
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
             'installed-at "2026-02-28T00:00:00Z")))
     (write-string-file (rackup-toolchain-meta-file "release-bad") "not-rktd")
     (define metas (installed-toolchain-metas/safe))
     (check-equal? (length metas) 1)
     (check-true (hash? (car metas)))))

  ;; --- bin/rackup deletes RACKUP_HOME only on a confirmed uninstall -------
  ;; Regression: the wrapper used to rm -rf RACKUP_HOME whenever the Racket
  ;; side exited 0, so `rackup uninstall --help` deleted everything.
  (define racket-dir
    (let-values ([(dir _name _dir?) (split-path (find-system-path 'exec-file))])
      (if (path? dir) dir (current-directory))))
  (define (run-wrapper home . args)
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
    (environment-variables-set! env #"RACKUP_ALLOW_SYSTEM_RACKET" #"1")
    (environment-variables-set!
     env #"PATH"
     (string->bytes/utf-8
      (string-append (path->string (path->complete-path racket-dir)) ":/usr/bin:/bin")))
    (parameterize ([current-environment-variables env]
                   [current-output-port (open-output-nowhere)]
                   [current-error-port (open-output-nowhere)]
                   [current-input-port (open-input-string "")])
      (apply system*/exit-code (find-executable-path "sh") (path->string rackup-bin)
             "uninstall" args)))
  (define (fresh-home)
    (define home (make-temporary-file "rackup-uninstall-wrap-~a" 'directory tmp-root))
    (write-string-file (build-path home "marker") "keep")
    home)
  (when (find-executable-path "sh")
    (for ([args (in-list '(("--help") ("-h") () ("--bogus")))])
      (define home (fresh-home))
      (define status (apply run-wrapper home args))
      (check-true (file-exists? (build-path home "marker"))
                  (format "`rackup uninstall ~a` must not delete RACKUP_HOME (exit ~a)"
                          (string-join args " ") status))
      (delete-directory/files home #:must-exist? #f))
    (let ([home (fresh-home)])
      (check-equal? (run-wrapper home "--dangerously-delete-without-prompting"
                                 (path->string home))
                    0)
      (check-false (directory-exists? home) "a confirmed uninstall deletes RACKUP_HOME"))))
