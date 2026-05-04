#lang racket/base

(require rackunit
         "../libexec/rackup/security.rkt")

(module+ test
  (check-not-exn
   (lambda () (require-checksummed-http-installer! "https://example.invalid/racket.sh" #f)))
  (check-not-exn
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh" "abc123")))
  (check-exn
   #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh" #f)))
  (check-exn
   #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh" ""))))
