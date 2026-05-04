#lang racket/base

(require racket/string
         (only-in pkg/name package-source->name)
         "error.rkt"
         "text.rkt")

(provide http-url?
         require-checksummed-http-installer!
         valid-toolchain-id?
         ensure-valid-toolchain-id!
         valid-pkg-name?
         string-has-control-char?
         ensure-string-without-control-chars!
         ensure-path-without-control-chars!)

(define (http-url? s)
  (and (string? s) (regexp-match? #px"(?i:^http://)" s)))

(define (require-checksummed-http-installer! installer-url expected-sha256)
  (when (and (http-url? installer-url)
             (or (not (string? expected-sha256))
                 (string-blank? expected-sha256)))
    (rackup-error
     "refusing to download installer over HTTP without a hardcoded SHA-256 checksum: ~a"
     installer-url)))

(define (valid-toolchain-id? s)
  (and (string? s) (regexp-match? #px"^[A-Za-z0-9._-]+$" s)))

(define (ensure-valid-toolchain-id! s [what "toolchain id"])
  (unless (valid-toolchain-id? s)
    (rackup-error "invalid ~a: ~v" what s))
  s)

(define (valid-pkg-name? s)
  (and (string? s)
       (let ([name (package-source->name s 'name)])
         (and name (equal? name s)))))

(define (string-has-control-char? s)
  (and (string? s)
       (for/or ([ch (in-string s)])
         (or (char<? ch #\space) (char=? ch #\rubout)))))

(define (ensure-string-without-control-chars! s what)
  (when (string-has-control-char? s)
    (rackup-error "refusing unsafe ~a with control characters" what))
  s)

(define (ensure-path-without-control-chars! p what)
  (ensure-string-without-control-chars! (path->string* p) what)
  p)
