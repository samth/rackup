#lang racket/base

(require rackunit
         "../libexec/rackup/versioning.rkt")

(module+ test
  (check-equal? (hash-ref (parse-install-spec "stable") 'kind) 'stable)
  (check-equal? (hash-ref (parse-install-spec "8.18") 'kind) 'release)
  (check-equal? (hash-ref (parse-install-spec "snapshot") 'kind) 'snapshot)
  (check-equal? (hash-ref (parse-install-spec "snapshot:utah") 'snapshot-site) 'utah)

  (check-equal? (cmp-versions "8.18" "8.17") 1)
  (check-equal? (cmp-versions "7.9" "8.0") -1)
  (check-equal? (cmp-versions "current" "8.18") 1)
  (check-equal? (cmp-versions "pre-release" "8.18") 1)

  (check-equal? (default-variant-for-version "7.9") 'bc)
  (check-equal? (default-variant-for-version "8.0") 'cs)
  (check-true (cs-supported? "7.4"))
  (check-false (cs-supported? "7.3"))

  (check-equal?
   (canonical-toolchain-id 'release
                           #:resolved-version "8.18"
                           #:variant 'cs
                           #:arch "x86_64"
                           #:platform "linux"
                           #:distribution 'full)
   "release-8.18-cs-x86_64-linux-full")

  (check-equal?
   (canonical-toolchain-id 'snapshot
                           #:resolved-version "8.19.0.1"
                           #:variant 'cs
                           #:arch "x86_64"
                           #:platform "linux"
                           #:distribution 'full
                           #:snapshot-site 'utah
                           #:snapshot-stamp "20260225-abcd")
   "snapshot-utah-20260225-abcd-8.19.0.1-cs-x86_64-linux-full"))
