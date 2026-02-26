#lang racket/base

(require rackunit
         "../libexec/rackup/remote.rkt")

(module+ test
  (define p1 (parse-installer-filename "racket-8.18-x86_64-linux-cs.sh"))
  (check-equal? (hash-ref p1 'distribution) 'full)
  (check-equal? (hash-ref p1 'variant) 'cs)
  (check-equal? (hash-ref p1 'arch) "x86_64")
  (check-equal? (hash-ref p1 'platform) "linux")
  (check-equal? (hash-ref p1 'platform-family) "linux")
  (check-equal? (hash-ref p1 'ext) "sh")

  (define p1b (parse-installer-filename "racket-9.1-x86_64-linux-buster-cs.sh"))
  (check-equal? (hash-ref p1b 'platform) "linux-buster")
  (check-equal? (hash-ref p1b 'platform-family) "linux")

  (define p2 (parse-installer-filename "racket-minimal-7.9-x86_64-linux.sh"))
  (check-equal? (hash-ref p2 'distribution) 'minimal)
  (check-equal? (hash-ref p2 'variant) 'bc)
  (check-equal? (hash-ref p2 'version-token) "7.9")

  (define fake-table
    (hash 'a "racket-8.18-x86_64-linux-cs.sh"
          'b "racket-minimal-8.18-x86_64-linux-cs.sh"
          'c "racket-8.18-x86_64-linux-bc.sh"
          'd "racket-current-x86_64-linux-cs.sh"
          'e "racket-minimal-current-x86_64-linux-cs.sh"))

  (check-equal?
   (select-installer-filename fake-table
                              #:version-token "8.18"
                              #:variant 'cs
                              #:distribution 'full
                              #:arch "x86_64")
   "racket-8.18-x86_64-linux-cs.sh")

  (define fake-table-precise
    (hash 'a "racket-9.1.0.7-x86_64-linux-cs.sh"))
  (check-equal?
   (select-installer-filename fake-table-precise
                              #:version-token "9.1"
                              #:variant 'cs
                              #:distribution 'full
                              #:arch "x86_64"
                              #:allow-version-prefix? #t)
   "racket-9.1.0.7-x86_64-linux-cs.sh")

  (define fake-table-linux-flavors
    (hash 'a "racket-9.1-x86_64-linux-buster-cs.sh"
          'b "racket-9.1-x86_64-linux-natipkg-cs.sh"))
  (check-equal?
   (select-installer-filename fake-table-linux-flavors
                              #:version-token "9.1"
                              #:variant 'cs
                              #:distribution 'full
                              #:arch "x86_64"
                              #:allow-version-prefix? #t)
   "racket-9.1-x86_64-linux-buster-cs.sh")

  (check-equal?
   (select-installer-filename fake-table
                              #:version-token "current"
                              #:variant 'cs
                              #:distribution 'minimal
                              #:arch "x86_64")
   "racket-minimal-current-x86_64-linux-cs.sh"))
