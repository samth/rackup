#lang racket/base

(require (only-in file/sha1 bytes->hex-string sha1)
         "error.rkt"
         "text.rkt")

(provide verify-installer-checksum!)

(define (file-sha256-hex p)
  (call-with-input-file p
    (lambda (in) (bytes->hex-string (sha256-bytes in)))))

(define (file-sha1-hex p)
  (call-with-input-file p (lambda (in) (sha1 in))))

(define (verify-installer-checksum! path
                                    #:sha256 [expected-sha256 #f]
                                    #:sha1 [expected-sha1 #f])
  (cond
    [expected-sha256 (check! path expected-sha256 (file-sha256-hex path) "")]
    [expected-sha1   (check! path expected-sha1   (file-sha1-hex path)   " (SHA1)")]))

(define (check! path expected actual label)
  (unless (equal? (string-downcase actual) (string-downcase expected))
    (rackup-error "download checksum mismatch~a for ~a\nexpected: ~a\nactual:   ~a"
                  label (path->string* path) expected actual)))
