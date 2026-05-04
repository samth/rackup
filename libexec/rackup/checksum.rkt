#lang racket/base

(require file/sha1
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "text.rkt")

(provide file-sha256
         file-sha1
         verify-installer-sha256!
         verify-installer-checksum!)

;; FIXME: These hashing helpers are likely available via Racket stdlib libraries;
;; prefer a direct stdlib implementation over shelling out when we can verify parity.
(define (sha256-exe)
  (cond
    [(find-executable-path "sha256sum") => (lambda (p) (cons 'sha256sum p))]
    [(find-executable-path "shasum") => (lambda (p) (cons 'shasum p))]
    [(find-executable-path "openssl") => (lambda (p) (cons 'openssl p))]
    [else #f]))

(define (sha256-capture-string who . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (if (apply system* args)
        (string-trim (get-output-string out))
        (rackup-error "~a failed: ~a~a"
                      who
                      (string-join (map path->string* args) " ")
                      (let ([e (string-trim (get-output-string err))])
                        (if (string-blank? e) "" (string-append "\n" e)))))))

(define (file-sha256 p)
  (match (sha256-exe)
    [(cons 'sha256sum exe)
     (car (string-split (sha256-capture-string 'sha256sum exe p)))]
    [(cons 'shasum exe)
     (car (string-split (sha256-capture-string 'shasum exe "-a" "256" p)))]
    [(cons 'openssl exe)
     (last (string-split (sha256-capture-string 'openssl exe "dgst" "-sha256" p)))]
    [_ (rackup-error "could not find sha256sum, shasum, or openssl to verify downloads")]))

(define (verify-installer-sha256! installer-path expected-sha256)
  (when expected-sha256
    (define actual-sha256 (file-sha256 installer-path))
    (unless (equal? (string-downcase actual-sha256) (string-downcase expected-sha256))
      (rackup-error "download checksum mismatch for ~a\nexpected: ~a\nactual:   ~a"
                    (path->string* installer-path)
                    expected-sha256
                    actual-sha256))))

(define (file-sha1 p)
  (call-with-input-file p sha1))

(define (verify-installer-checksum! installer-path #:sha256 [expected-sha256 #f] #:sha1 [expected-sha1 #f])
  (cond
    [expected-sha256 (verify-installer-sha256! installer-path expected-sha256)]
    [expected-sha1
     (define actual (file-sha1 installer-path))
     (unless (equal? (string-downcase actual) (string-downcase expected-sha1))
       (rackup-error "download checksum mismatch (SHA1) for ~a\nexpected: ~a\nactual:   ~a"
                     (path->string* installer-path)
                     expected-sha1
                     actual))]))
