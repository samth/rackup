#lang racket/base

(require racket/file)

(provide ensure-directory*
         replace-path!)

(define (ensure-directory* p)
  (make-directory* p)
  p)

;; Replace whatever is at `dest` (link, file, or directory) with `src`,
;; using `mode` to choose how to materialize `src`. The destination is
;; cleared first; if creation fails, `dest` is left absent.
(define (replace-path! dest src #:mode [mode 'link])
  (when (link-exists? dest)
    (delete-file dest))
  (when (file-exists? dest)
    (delete-file dest))
  (when (directory-exists? dest)
    (delete-directory/files dest))
  (case mode
    [(link) (make-file-or-directory-link src dest)]
    [(file) (copy-file src dest #t)]
    [(directory) (copy-directory/files src dest #t)]
    [else
     (raise-argument-error 'replace-path! "(or/c 'link 'file 'directory)" mode)]))
