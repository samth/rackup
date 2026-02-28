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

(define (call-with-atomic-output-file path writer)
  (define dir (or (path-only path) (current-directory)))
  (define perms (and (file-exists? path) (file-or-directory-permissions path 'bits)))
  (make-directory* dir)
  (define tmp (make-temporary-file "rackup-write-~a" #f dir))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file* tmp
       #:exists 'truncate/replace
       (lambda (out)
         (writer out)
         (flush-output out)))
     (when perms
       (file-or-directory-permissions tmp perms))
     (rename-file-or-directory tmp path #t))
   (lambda ()
     (when (file-exists? tmp)
       (delete-file tmp)))))

(define (write-string-file path s)
  (call-with-atomic-output-file path
    (lambda (out)
      (display s out)
      (newline out))))

(define (write-rktd-file path v)
  (call-with-atomic-output-file path
    (lambda (out)
      (write v out)
      (newline out))))
