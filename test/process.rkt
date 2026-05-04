#lang racket/base

(require rackunit
         "../libexec/rackup/process.rkt")

(module+ test
  (check-true (file-exists? (shell-exe)))
  (check-true (path? (find-executable-path/default "definitely-no-such-binary-xyz" "/fallback")))
  (check-equal? (find-executable-path/default "definitely-no-such-binary-xyz" "/fallback")
                (string->path "/fallback"))

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
     "outer")))
