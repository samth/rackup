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
      (check-not-exn
       (lambda ()
         (verify-installer-checksum! tmp #:sha1 "a9993e364706816aba3e25717850c26c9cd0d89d")))
      (check-not-exn
       (lambda ()
         (verify-installer-checksum!
          tmp
          #:sha256 "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
      (check-exn #px"checksum mismatch"
                 (lambda () (verify-installer-checksum! tmp #:sha1 "bad")))
      (check-exn #px"checksum mismatch"
                 (lambda () (verify-installer-checksum! tmp #:sha256 "bad")))
      ;; No checksum supplied: no-op.
      (check-not-exn (lambda () (verify-installer-checksum! tmp))))
    (lambda () (delete-file tmp))))
