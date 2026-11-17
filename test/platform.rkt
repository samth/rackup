#lang racket/base

;; Host-OS helpers.  CI runs these on Unix; the Windows branches are
;; exercised by the windows-e2e job.

(require rackunit
         racket/file
         "../libexec/rackup/fs.rkt"
         "../libexec/rackup/platform.rkt")

(module+ test
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
