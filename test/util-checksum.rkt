#lang racket/base

(require rackunit
         racket/file
         "../libexec/rackup/checksum.rkt")

(module+ test
  (define tmp (make-temporary-file "rackup-checksum-~a.txt"))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file tmp #:exists 'truncate/replace
        (lambda (out) (display "abc" out)))
      (check-equal? (file-sha1 tmp) "a9993e364706816aba3e25717850c26c9cd0d89d")
      (check-not-exn (lambda () (verify-installer-checksum! tmp #:sha1 "a9993e364706816aba3e25717850c26c9cd0d89d")))
      (check-exn #px"checksum mismatch" (lambda () (verify-installer-checksum! tmp #:sha1 "bad"))))
    (lambda () (delete-file tmp))))
