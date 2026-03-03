#lang racket/base

(require rackunit
         racket/port
         racket/string
         "../libexec/rackup/main.rkt")

(module+ test
  (define output (string-trim (with-output-to-string cmd-version)))

  (check-true (string-prefix? output "rackup "))
  ;; In a git repo, we should get a commit hash
  (check-true (regexp-match? #px"^rackup [0-9a-f]+" output)))
