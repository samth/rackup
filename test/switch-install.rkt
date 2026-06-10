#lang racket/base

;; Regression test for `rackup switch <spec>` when the toolchain is not
;; installed and the user accepts the offer to install it.  The shell
;; integration function evals the stdout of `rackup switch`, so stdout
;; must carry only shell code; install progress must go to stderr.
;; (Reported by Matthias: zsh printed "(eval):1: command not found:
;; Installing" after accepting the install prompt.)
;;
;; The whole install runs offline: HTTP is stubbed via
;; current-http-sendrecv-proc and the /dev/tty prompt via
;; current-open-user-tty.

(require rackunit
         racket/file
         racket/port
         racket/string
         racket/system
         "../libexec/rackup/main.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/versioning.rkt"
         (only-in (submod "../libexec/rackup/main.rkt" for-testing)
                  current-open-user-tty)
         (only-in (submod "../libexec/rackup/remote.rkt" for-testing)
                  current-http-sendrecv-proc))

(define (run-main args)
  (let/ec escape
    (parameterize ([current-command-line-arguments (list->vector args)]
                   [exit-handler (lambda (v) (escape v))])
      (main))))

(define arch (normalized-host-arch))
(define platform (host-platform-token))
(define ext (if (equal? platform "macosx") "tgz" "sh"))
(define installer-filename (format "racket-9.1-~a-~a-cs.~a" arch platform ext))

;; A fake modern .sh installer: the header markers make
;; detect-shell-installer-mode classify it as 'modern, and it honors
;; --dest by creating a minimal bin/racket there.
(define fake-sh-installer
  (string-join
   '("#!/bin/sh"
     "# Command-line flags: --dest <dir> --in-place (fake test installer)"
     "dest="
     "while [ \"$#\" -gt 0 ]; do"
     "  case \"$1\" in"
     "    --dest) dest=\"$2\"; shift 2 ;;"
     "    *) shift ;;"
     "  esac"
     "done"
     "mkdir -p \"$dest/bin\""
     "printf '#!/bin/sh\\necho fake-racket\\n' > \"$dest/bin/racket\""
     "chmod 755 \"$dest/bin/racket\""
     "")
   "\n"))

;; A fake .tgz installer (used on macOS, where .tgz is preferred):
;; a real gzipped tarball containing bin/racket.
(define (make-fake-tgz-bytes)
  (define stage (make-temporary-file "rackup-fake-stage-~a" 'directory))
  (define bin (build-path stage "bin"))
  (make-directory* bin)
  (call-with-output-file* (build-path bin "racket")
    (lambda (out) (display "#!/bin/sh\necho fake-racket\n" out)))
  (file-or-directory-permissions (build-path bin "racket") #o755)
  (define tgz (make-temporary-file "rackup-fake-~a.tgz"))
  (unless (system* (find-executable-path "tar")
                   "-C" stage "-czf" tgz "bin")
    (error 'switch-install-test "failed to build fake tgz"))
  (define bs (file->bytes tgz))
  (delete-file tgz)
  (delete-directory/files stage)
  bs)

(define installer-bytes
  (if (equal? ext "tgz")
      (make-fake-tgz-bytes)
      (string->bytes/utf-8 fake-sh-installer)))

(define table-rktd-text
  (format "~s" (hash 'installer installer-filename)))

(define (fake-http-response target)
  (cond
    [(string-suffix? target "/version.txt")
     (string->bytes/utf-8 "(stable \"9.1\")")]
    [(string-suffix? target "table.rktd")
     (string->bytes/utf-8 table-rktd-text)]
    [(string-suffix? target installer-filename)
     installer-bytes]
    [(regexp-match? #px"/releases/" target)
     #"<html></html>"]
    [else (error 'switch-install-test "unexpected HTTP request: ~a" target)]))

(define fake-http-sendrecv
  (make-keyword-procedure
   (lambda (_kws _kw-args _host target . _rest)
     (values #"HTTP/1.1 200 OK"
             null
             (open-input-bytes (fake-http-response target))))))

(define (with-temp-rackup-home proc)
  (define tmp-home (make-temporary-file "rackup-switch-home-~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string tmp-home)))
  (environment-variables-set! env #"RACKUP_TOOLCHAIN" #f)
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-environment-variables env])
       (proc tmp-home)))
   (lambda ()
     (delete-directory/files tmp-home #:must-exist? #f))))

(with-temp-rackup-home
 (lambda (_tmp-home)
   (define stdout-str (open-output-string))
   (define stderr-str (open-output-string))
   (define exit-code
     (parameterize ([current-http-sendrecv-proc fake-http-sendrecv]
                    [current-open-user-tty
                     (lambda ()
                       (values (open-input-string "Y\n") (open-output-nowhere)))]
                    [current-output-port stdout-str]
                    [current-error-port stderr-str]
                    [current-input-port (open-input-string "")])
       (run-main '("switch" "stable"))))
   (define out (get-output-string stdout-str))
   (define err (get-output-string stderr-str))
   (check-equal? exit-code (void)
                 (format "switch exited non-zero; stderr: ~s" err))
   (define expected-id (format "release-9.1-cs-~a-~a-full" arch platform))
   ;; The toolchain really was installed and registered.
   (check-true (toolchain-exists? expected-id)
               (format "expected ~a to be installed; stderr: ~a" expected-id err))
   ;; stdout carries the activation shell code...
   (check-true (string-contains? out (format "export RACKUP_TOOLCHAIN='~a'" expected-id))
               (format "activation code missing from stdout: ~s" out))
   ;; ...and nothing else: the install progress must not leak into the
   ;; eval'd output (every stdout line must be shell code).
   (for ([line (in-list (string-split out "\n"))]
         #:unless (string=? (string-trim line) ""))
     (check-true (regexp-match? #px"^(if |  case |fi$|export |unset )" line)
                 (format "non-shell-code line on switch stdout: ~s" line)))
   ;; The progress messages still reach the user, on stderr.
   (check-true (string-contains? err "Installing")
               (format "install progress missing from stderr: ~s" err))))
