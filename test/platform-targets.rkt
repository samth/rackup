#lang at-exp racket/base

(require rackunit
         racket/list
         racket/match
         "../libexec/rackup/remote.rkt")

(module+ test
  ;; Derived from current stable/pre-release published unix-like target families:
  ;; platforms: linux, macosx
  ;; architectures: x86_64, aarch64, i386, arm, ppc, riscv64
  ;; extensions: sh, tgz, dmg
  (define combos
    (list
     ;; linux + sh
     (list "9.1" 'cs 'full "x86_64" "linux" "sh" "racket-9.1-x86_64-linux-cs.sh")
     (list "9.1" 'cs 'minimal "x86_64" "linux" "sh" "racket-minimal-9.1-x86_64-linux-cs.sh")
     (list "9.1" 'cs 'minimal "aarch64" "linux" "sh" "racket-minimal-9.1-aarch64-linux-cs.sh")
     (list "9.1" 'cs 'minimal "arm" "linux" "sh" "racket-minimal-9.1-arm-linux-cs.sh")
     (list "9.1" 'bc 'minimal "i386" "linux" "sh" "racket-minimal-9.1-i386-linux-bc.sh")
     (list "9.1" 'cs 'minimal "riscv64" "linux" "sh" "racket-minimal-9.1-riscv64-linux-cs.sh")
     ;; linux + tgz
     (list "9.1" 'cs 'full "x86_64" "linux" "tgz" "racket-9.1-x86_64-linux-cs.tgz")
     (list "9.1" 'cs 'full "aarch64" "linux" "tgz" "racket-9.1-aarch64-linux-cs.tgz")
     (list "9.1" 'cs 'minimal "arm" "linux" "tgz" "racket-minimal-9.1-arm-linux-cs.tgz")
     (list "9.1" 'bc 'minimal "i386" "linux" "tgz" "racket-minimal-9.1-i386-linux-bc.tgz")
     (list "9.1" 'bc 'minimal "ppc" "linux" "tgz" "racket-minimal-9.1-ppc-linux-bc.tgz")
     (list "9.1" 'cs 'minimal "riscv64" "linux" "tgz" "racket-minimal-9.1-riscv64-linux-cs.tgz")
     ;; macosx + dmg
     (list "9.1" 'cs 'full "x86_64" "macosx" "dmg" "racket-9.1-x86_64-macosx-cs.dmg")
     (list "9.1" 'cs 'minimal "x86_64" "macosx" "dmg" "racket-minimal-9.1-x86_64-macosx-cs.dmg")
     (list "9.1" 'cs 'full "aarch64" "macosx" "dmg" "racket-9.1-aarch64-macosx-cs.dmg")
     (list "9.1" 'cs 'minimal "aarch64" "macosx" "dmg" "racket-minimal-9.1-aarch64-macosx-cs.dmg")
     (list "9.1" 'bc 'minimal "i386" "macosx" "dmg" "racket-minimal-9.1-i386-macosx-bc.dmg")
     ;; macosx + tgz
     (list "9.1" 'cs 'full "x86_64" "macosx" "tgz" "racket-9.1-x86_64-macosx-cs.tgz")
     (list "9.1" 'cs 'minimal "x86_64" "macosx" "tgz" "racket-minimal-9.1-x86_64-macosx-cs.tgz")
     (list "9.1" 'cs 'full "aarch64" "macosx" "tgz" "racket-9.1-aarch64-macosx-cs.tgz")
     (list "9.1" 'cs 'minimal "aarch64" "macosx" "tgz" "racket-minimal-9.1-aarch64-macosx-cs.tgz")
     (list "9.1" 'bc 'minimal "i386" "macosx" "tgz" "racket-minimal-9.1-i386-macosx-bc.tgz")))

  (define extra-linux-non-targets
    (list "racket-minimal-9.1-x86_64-linux-natipkg-cs.sh"
          "racket-minimal-9.1-x86_64-linux-pkg-build-cs.sh"))

  (define table
    (for/hash ([f (in-list (append (map last combos) extra-linux-non-targets))]
               [i (in-naturals)])
      (values i f)))

  (for ([combo (in-list combos)])
    (match-define (list version-token variant distribution arch platform ext expected) combo)
    (define selected
      (select-installer-filename table
                                 #:version-token version-token
                                 #:variant variant
                                 #:distribution distribution
                                 #:arch arch
                                 #:platform platform
                                 #:ext ext
                                 #:allow-version-prefix? #t))
    (check-equal? selected expected))

  ;; Linux natipkg/pkg-build installers must not outrank normal installers.
  (check-equal? (select-installer-filename table
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'minimal
                                           #:arch "x86_64"
                                           #:platform "linux"
                                           #:ext "sh")
                "racket-minimal-9.1-x86_64-linux-cs.sh"))
