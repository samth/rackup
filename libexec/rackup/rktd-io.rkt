#lang racket/base

(require racket/file
         racket/path
         racket/port
         racket/string)

(provide read-rktd-file
         write-rktd-file
         read-string-file
         write-string-file)

(define (read-string-file path [default #f])
  (if (file-exists? path)
      (string-trim (file->string path))
      default))

(define (read-rktd-file path [default #f])
  (if (file-exists? path)
      (call-with-input-file* path read)
      default))

(define (write-string-file path s)
  (make-directory* (or (path-only path) "."))
  (call-with-output-file* path
                          #:exists 'truncate/replace
                          (lambda (out)
                            (display s out)
                            (newline out))))

(define (write-rktd-file path v)
  (make-directory* (or (path-only path) "."))
  (call-with-output-file* path
                          #:exists 'truncate/replace
                          (lambda (out)
                            (write v out)
                            (newline out))))
