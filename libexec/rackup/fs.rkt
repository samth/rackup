#lang racket/base

(require racket/file
         racket/string
         "platform.rkt")

(provide ensure-directory*
         delete-path!
         dir-or-link-exists?
         replace-path!
         replace-dir-pointer!
         follow-dir-pointer
         dir-pointer-target)

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

;; A "directory pointer" names another directory.  On Unix it is a
;; symbolic link, so a path through it works like the target.  Windows
;; symlinks need Developer Mode or an admin privilege (and junctions
;; are not portable to every filesystem), so there the pointer is a
;; plain file whose one line is the target's absolute path, and code
;; that reads through it must call `follow-dir-pointer` first.
(define (replace-dir-pointer! dest target)
  (cond
    [(windows?)
     (delete-path! dest)
     (call-with-output-file* dest #:exists 'truncate/replace
       (lambda (out)
         (write-string (path->string (path->complete-path target)) out)
         (newline out)))]
    [else (replace-path! dest target #:mode 'link)]))

;; The target that pointer `p` names, or #f when `p` is missing or (on
;; Unix) is not a link.
(define (dir-pointer-target p)
  (cond
    [(and (windows?) (file-exists? p))
     (define s (string-trim (file->string p)))
     (and (not (string=? s "")) (string->path s))]
    [(link-exists? p) (resolve-path p)]
    [else #f]))

;; The directory to read through pointer `p`: its target on Windows,
;; `p` itself elsewhere (the OS follows the link).  A real directory at
;; `p` (an overlay, or a layout from before pointers) is returned as is.
(define (follow-dir-pointer p)
  (cond
    [(and (windows?) (file-exists? p)) (or (dir-pointer-target p) p)]
    [else p]))
