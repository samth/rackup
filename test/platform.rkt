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
     (lambda () (delete-directory/files tmp #:must-exist? #f)))))
