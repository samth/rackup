#lang racket/base

(require rackunit
         racket/path
         "../libexec/rackup/util.rkt")

(module+ test
  (check-true (string-blank? ""))
  (check-true (string-blank? " \t\n"))
  (check-false (string-blank? "x"))

  (check-not-exn (lambda () (require-checksummed-http-installer! "https://example.invalid/racket.sh" #f)))
  (check-not-exn
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh"
                                          "abc123")))
  (check-exn
   #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh" #f)))
  (check-exn
   #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
   (lambda ()
     (require-checksummed-http-installer! "http://download.plt-scheme.org/example.sh" "")))

  (check-true (file-exists? (shell-exe)))

  (define base-env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! base-env #"RACKUP_TEST_CAPTURE" #"outer")
  (parameterize ([current-environment-variables base-env])
    (check-equal?
     (capture-program-output (shell-exe) "-c" "printf '%s' \"$RACKUP_TEST_CAPTURE\"")
     "outer")
    (check-equal?
     (capture-program-output #:env '(("RACKUP_TEST_CAPTURE" . "inner"))
                             (shell-exe)
                             "-c"
                             "printf '%s' \"$RACKUP_TEST_CAPTURE\"")
     "inner")
    (check-equal?
     (capture-program-output #:env '(("RACKUP_TEST_CAPTURE" . #f))
                             (shell-exe)
                             "-c"
                             "if [ \"${RACKUP_TEST_CAPTURE+x}\" = x ]; then printf set; else printf unset; fi")
     "unset")
    (check-equal?
     (capture-program-output (shell-exe) "-c" "printf '%s' \"$RACKUP_TEST_CAPTURE\"")
     "outer"))

  (check-equal? (path-basename-string (string->path "/")) "/")
  (check-equal? (path-basename-string (string->path "/tmp/")) "/tmp/"))
