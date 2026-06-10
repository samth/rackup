#lang racket/base

(require racket/file
         racket/path
         racket/port
         racket/string)

(provide read-rktd/port
         read-rktd-file
         write-rktd-file
         read-string-file
         write-string-file)

(define (read-string-file path [default #f])
  (if (file-exists? path)
      (string-trim (file->string path))
      default))

(define (read-rktd/port in)
  (parameterize ([read-accept-reader #f]
                 [read-accept-lang #f]
                 [read-accept-compiled #f])
    (read in)))

(define (read-rktd-file path [default #f])
  (if (file-exists? path)
      (with-handlers ([exn:fail?
                       (lambda (e)
                         (raise-user-error
                          'rackup
                          (format "failed to read .rktd file ~a: ~a"
                                  path
                                  (exn-message e))))])
        (call-with-input-file* path read-rktd/port))
      default))

;; Atomic write via racket/file's call-with-atomic-output-file
;; (temp file + rename), additionally preserving the permission bits of
;; an existing file at `path` — the stdlib temp file starts with
;; default permissions.
(define (write-file-atomically path writer)
  (define perms (and (file-exists? path) (file-or-directory-permissions path 'bits)))
  (make-directory* (or (path-only path) (current-directory)))
  (call-with-atomic-output-file path (lambda (out _tmp) (writer out)))
  (when perms
    (file-or-directory-permissions path perms)))

(define (write-string-file path s)
  (write-file-atomically path
    (lambda (out)
      (display s out)
      (newline out))))

(define (write-rktd-file path v)
  (write-file-atomically path
    (lambda (out)
      (write v out)
      (newline out))))
