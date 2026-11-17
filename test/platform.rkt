#lang racket/base

;; Host-OS helpers.  CI runs these on Unix; the Windows branches are
;; exercised by the windows-e2e job.

(require rackunit
         racket/file
         racket/string
         "../libexec/rackup/commands-data.rkt"
         "../libexec/rackup/fs.rkt"
         "../libexec/rackup/platform.rkt"
         "../libexec/rackup/windows-env.rkt"
         (submod "../libexec/rackup/windows-env.rkt" for-testing)
         (submod "../libexec/rackup/shell.rkt" for-testing))

;; Windows paths built from "/"-separated strings, to keep backslashes out
;; of the test source.
(define (w s) (string-replace s "/" "\\"))

(module+ test
  ;; Removing rackup's shims from the user Path (rackup uninstall).
  (check-equal? (remove-path-list-entry (w "C:/a;C:/Users/x/rackup/shims/;%USERPROFILE%/bin")
                                        (w "c:/users/X/rackup/shims"))
                (w "C:/a;%USERPROFILE%/bin"))
  (check-equal? (remove-path-list-entry (w "C:/rk/shims") (w "C:/rk/shims")) "")
  (check-false (remove-path-list-entry (w "C:/a;C:/b") (w "C:/rk/shims")))
  (check-false (remove-path-list-entry "" (w "C:/rk/shims")))
  (let ([s (string #\a (integer->char #xE9) (integer->char #x1F600) #\b)])
    (check-equal? (utf-16le->string (string->utf-16le s)) s))

  ;; The PowerShell helper: PATH, the `rackup` function that evaluates
  ;; `rackup switch`, and completion of every command.
  (define ps (shell-helper-script "powershell"))
  (check-true (string-contains? ps "function rackup {"))
  (check-true (string-contains? ps "$env:RACKUP_SHELL = 'powershell'"))
  (check-true (string-contains? ps "Invoke-Expression"))
  (check-true (string-contains? ps "Register-ArgumentCompleter -Native -CommandName rackup"))
  (for ([c (in-list (map car rackup-commands))])
    (check-true (string-contains? ps (format "'~a'" c)) c))

  (unless (windows?)
    (check-equal? (exe-file-name "racket") "racket")
    (check-true (executable-name? "raco"))
    (check-equal? (exe-file->tool-name "/x/DrRacket") "DrRacket")
    (check-equal? (path-list-separator) ":")
    (check-equal? (prepend-path-list-entry "/s" "/a:/b") "/s:/a:/b")
    (check-equal? (prepend-path-list-entry "/s" "/a:/s") "/a:/s")
    (check-equal? (prepend-path-list-entry "/s" "") "/s")

    ;; A directory pointer is a symlink on Unix, so reads go straight
    ;; through it.
    (define tmp (make-temporary-file "rackup-platform-test~a" 'directory))
    (dynamic-wind
     void
     (lambda ()
       (define target (build-path tmp "target"))
       (make-directory target)
       (define ptr (build-path tmp "ptr"))
       (check-false (dir-pointer-target ptr))
       (replace-dir-pointer! ptr target)
       (check-true (link-exists? ptr))
       (check-equal? (dir-pointer-target ptr) target)
       (check-equal? (follow-dir-pointer ptr) ptr)
       ;; Replacing repoints it.
       (define target2 (build-path tmp "target2"))
       (make-directory target2)
       (replace-dir-pointer! ptr target2)
       (check-equal? (dir-pointer-target ptr) target2))
     (lambda () (delete-directory/files tmp #:must-exist? #f))))

  ;; The Subsystem field of a PE header, which the GUI-tool shims flip so
  ;; launching DrRacket from Explorer opens no console window.
  (define (fake-pe subsystem)
    (define bs (make-bytes 512 0))
    (bytes-set! bs 0 (char->integer #\M))
    (bytes-set! bs 1 (char->integer #\Z))
    (integer->integer-bytes #x80 4 #f #f bs #x3C)
    (bytes-copy! bs #x80 #"PE\0\0")
    (integer->integer-bytes subsystem 2 #f #f bs (+ #x80 4 20 68))
    bs)
  (define console-pe (fake-pe pe-subsystem-console))
  (check-equal? (pe-subsystem console-pe) pe-subsystem-console)
  (define gui-pe (pe-with-subsystem console-pe pe-subsystem-gui))
  (check-equal? (pe-subsystem gui-pe) pe-subsystem-gui)
  (check-equal? (pe-subsystem console-pe) pe-subsystem-console "copy, not in place")
  (check-equal? (bytes-length gui-pe) (bytes-length console-pe))
  (check-false (pe-subsystem #"#!/bin/sh\nexec racket\n"))
  (check-exn exn:fail? (lambda () (pe-with-subsystem #"not an exe" pe-subsystem-gui)))
  (let ([dir (make-temporary-directory)])
    (define (put name bs)
      (define p (build-path dir name))
      (call-with-output-file p (lambda (o) (write-bytes bs o)))
      p)
    (check-true (gui-executable? (put "gui.exe" gui-pe)))
    (check-false (gui-executable? (put "console.exe" console-pe)))
    (check-false (gui-executable? (build-path dir "missing.exe")))
    (delete-directory/files dir))

  ;; Git Bash on Windows: the helper and rc block find RACKUP_HOME as a
  ;; POSIX path and call the rackup.exe shim.
  (parameterize ([git-bash? #t])
    (define sh (shell-helper-script "bash"))
    (check-true (string-contains? sh "_rackup_home() {"))
    (check-true (string-contains? sh "cygpath -u"))
    (check-true (string-contains? sh "$(_rackup_home)/shims/rackup.exe"))
    (check-true (string-contains? sh "export PATH=\"$(_rackup_home)/shims:$PATH\""))
    (check-false (string-contains? sh "$HOME/.rackup"))
    (define rc (posix-managed-rc-block "bash"))
    (check-true (string-contains? rc "$LOCALAPPDATA/rackup"))
    (check-true (string-contains? rc "/shell/rackup.bash")))
  (parameterize ([git-bash? #f])
    (check-false (string-contains? (shell-helper-script "bash") "_rackup_home"))))
