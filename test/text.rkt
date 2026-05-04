#lang racket/base

(require rackunit
         "../libexec/rackup/text.rkt")

(module+ test
  ;; sh-single-quote handles a literal single quote by closing, escaping, reopening.
  (check-equal? (sh-single-quote "abc") "'abc'")
  (check-equal? (sh-single-quote "a'b") "'a'\"'\"'b'")

  ;; current-iso8601 ends in "Z" since racket/date's iso-8601 omits the timezone.
  (check-regexp-match #px"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
                      (current-iso8601)))
