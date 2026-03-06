#lang racket/base

(require rackunit
         "../libexec/rackup/versioning.rkt")

(module+ test
  (check-equal? (hash-ref (parse-install-spec "stable") 'kind) 'stable)
  (check-equal? (hash-ref (parse-install-spec "8.18") 'kind) 'release)
  (check-equal? (hash-ref (parse-install-spec "103p1") 'kind) 'release)
  (check-equal? (hash-ref (parse-install-spec "snapshot") 'kind) 'snapshot)
  (check-equal? (hash-ref (parse-install-spec "snapshot:utah") 'snapshot-site) 'utah)

  (check-equal? (cmp-versions "8.18" "8.17") 1)
  (check-equal? (cmp-versions "7.9" "8.0") -1)
  (check-equal? (cmp-versions "206p1" "206") 1)
  (check-equal? (cmp-versions "103p1" "103") 1)
  (check-equal? (cmp-versions "current" "8.18") 1)
  (check-equal? (cmp-versions "pre-release" "8.18") 1)

  (check-equal? (default-variant-for-version "7.9") 'bc)
  (check-equal? (default-variant-for-version "8.0") 'cs)
  (check-true (cs-supported? "7.4"))
  (check-false (cs-supported? "7.3"))
  (check-equal? (arch-token->normalized "arm64") "aarch64")
  (check-equal? (arch-token->normalized "aarch64") "aarch64")
  (check-equal? (arch-token->normalized "x86_64") "x86_64")
  (check-equal? (arch-token->normalized "i386") "i386")
  (check-equal? (arch-token->normalized "riscv64") "riscv64")
  (check-equal? (arch-token->normalized "ppc") "ppc")
  (check-equal? (arch-token->normalized "ppc64le") "ppc")

  (check-equal? (canonical-toolchain-id 'release
                                        #:resolved-version "8.18"
                                        #:variant 'cs
                                        #:arch "x86_64"
                                        #:platform "linux"
                                        #:distribution 'full)
                "release-8.18-cs-x86_64-linux-full")

  (check-equal? (canonical-toolchain-id 'snapshot
                                        #:resolved-version "8.19.0.1"
                                        #:variant 'cs
                                        #:arch "x86_64"
                                        #:platform "linux"
                                        #:distribution 'full
                                        #:snapshot-site 'utah
                                        #:snapshot-stamp "20260225-abcd")
                "snapshot-utah-20260225-abcd-8.19.0.1-cs-x86_64-linux-full")

  ;; host-platform-token returns a recognized platform string
  (check-true (member (host-platform-token) '("linux" "macosx"))
              "host-platform-token must return a recognized platform")

  ;; macOS canonical IDs use "macosx" platform token
  (check-equal? (canonical-toolchain-id 'release
                                        #:resolved-version "9.1"
                                        #:variant 'cs
                                        #:arch "aarch64"
                                        #:platform "macosx"
                                        #:distribution 'full)
                "release-9.1-cs-aarch64-macosx-full")

  (check-equal? (canonical-toolchain-id 'release
                                        #:resolved-version "8.18"
                                        #:variant 'cs
                                        #:arch "x86_64"
                                        #:platform "macosx"
                                        #:distribution 'minimal)
                "release-8.18-cs-x86_64-macosx-minimal"))
