#lang racket/base

(require racket/file)

(provide ensure-directory*
         delete-path!
         dir-or-link-exists?
         replace-path!)

(define (ensure-directory* p)
  (make-directory* p)
  p)

;; Delete whatever is at `p` — link, file, or directory.  A no-op when
;; nothing exists there.
(define (delete-path! p)
  (cond
    [(or (link-exists? p) (file-exists? p)) (delete-file p)]
    [(directory-exists? p) (delete-directory/files p)]))

(define (dir-or-link-exists? p)
  (or (link-exists? p) (directory-exists? p)))

;; Replace whatever is at `dest` (link, file, or directory) with `src`,
;; using `mode` to choose how to materialize `src`. The destination is
;; cleared first; if creation fails, `dest` is left absent.
(define (replace-path! dest src #:mode [mode 'link])
  (delete-path! dest)
  (case mode
    [(link) (make-file-or-directory-link src dest)]
    [(file) (copy-file src dest #t)]
    [(directory) (copy-directory/files src dest #t)]
    [else
     (raise-argument-error 'replace-path! "(or/c 'link 'file 'directory)" mode)]))
