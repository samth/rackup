#lang racket/base

(require racket/list
         racket/match
         racket/string
         "legacy-plt-catalog.rkt"
         "util.rkt")

(provide parse-install-spec
         cmp-versions
         version-token->number
         numeric-version?
         cs-supported?
         default-variant-for-version
         canonical-toolchain-id
         sanitize-id-part
         normalized-host-arch
         linux-platform-token
         arch-token->normalized
         variant->string
         distribution->string)

(define (numeric-version? s)
  (and (string? s) (regexp-match? #px"^[0-9]+(?:\\.[0-9]+){0,3}(?:p[0-9]+)?$" s)))

(define (version-token->number v)
  (cond
    [(equal? v "current") 'current]
    [(equal? v "pre-release") 'pre-release]
    [else
     (match (regexp-match #px"^([0-9]+(?:\\.[0-9]+){0,3})(?:p([0-9]+))?$" v)
       [(list _ base patch-s)
        (define patch (if patch-s (string->number patch-s) 0))
        (match (string-split base ".")
          [(list a b c d)
           (+ (* (string->number a) (expt 10 10))
              (* (string->number b) (expt 10 7))
              (* (string->number c) (expt 10 4))
              (* (string->number d) 10)
              patch)]
          [(list a b c)
           (+ (* (string->number a) (expt 10 10))
              (* (string->number b) (expt 10 7))
              (* (string->number c) (expt 10 4))
              patch)]
          [(list a b)
           (+ (* (string->number a) (expt 10 10))
              (* (string->number b) (expt 10 7))
              patch)]
          [(list a)
           (+ (* (string->number a) (expt 10 10)) patch)]
          [_ 0])]
       [_ 0])]))

(define (cmp-versions a b)
  (define av (version-token->number a))
  (define bv (version-token->number b))
  (cond
    [(equal? av bv) 0]
    [(equal? av 'current) 1]
    [(equal? bv 'current) -1]
    [(equal? av 'pre-release) 1]
    [(equal? bv 'pre-release) -1]
    [(> av bv) 1]
    [else -1]))

(define (cs-supported? version)
  (>= (cmp-versions version "7.4") 0))

(define (default-variant-for-version version)
  (if (>= (cmp-versions version "8.0") 0) 'cs 'bc))

(define (parse-install-spec spec)
  (cond
    [(equal? spec "stable") (hash 'input spec 'kind 'stable)]
    [(or (equal? spec "pre-release") (equal? spec "pre")) (hash 'input spec 'kind 'pre-release)]
    [(or (equal? spec "snapshot") (equal? spec "current"))
     (hash 'input spec 'kind 'snapshot 'snapshot-site 'auto)]
    [(regexp-match #px"^snapshot:(utah|northwestern)$" spec)
     =>
     (lambda (m) (hash 'input spec 'kind 'snapshot 'snapshot-site (string->symbol (list-ref m 1))))]
    [(or (numeric-version? spec) (legacy-plt-version? spec)) (hash 'input spec 'kind 'release 'version spec)]
    [else (rackup-error "invalid version spec '~a'" spec)]))

(define (sanitize-id-part s)
  (regexp-replace* #px"[^A-Za-z0-9._-]+" (format "~a" s) "_"))

(define (variant->string v)
  (match v
    ['cs "cs"]
    ['bc "bc"]
    [(? string? s) (string-downcase s)]
    [_ (format "~a" v)]))

(define (distribution->string d)
  (match d
    ['full "full"]
    ['minimal "minimal"]
    [(? string? s) (string-downcase s)]
    [_ (format "~a" d)]))

(define (canonical-toolchain-id kind
                                #:resolved-version resolved-version
                                #:variant variant
                                #:arch arch
                                #:platform [platform "linux"]
                                #:distribution [distribution 'full]
                                #:snapshot-site [snapshot-site #f]
                                #:snapshot-stamp [snapshot-stamp #f])
  (define prefix
    (match kind
      ['release "release"]
      ['stable "release"]
      ['pre-release "pre"]
      ['snapshot "snapshot"]
      [_ (sanitize-id-part kind)]))
  (define parts
    (append (list prefix)
            (if (eq? kind 'snapshot)
                (list (sanitize-id-part (or snapshot-site "unknown"))
                      (sanitize-id-part (or snapshot-stamp "unstamped")))
                null)
            (list (sanitize-id-part resolved-version)
                  (sanitize-id-part (variant->string variant))
                  (sanitize-id-part arch)
                  (sanitize-id-part platform)
                  (sanitize-id-part (distribution->string distribution)))))
  (string-join parts "-"))

(define (normalized-host-arch)
  (define raw (system-type 'machine))
  (define m*
    (if (symbol? raw)
        (symbol->string raw)
        (format "~a" raw)))
  (define m (string-downcase m*))
  (cond
    [(regexp-match? #px"x86_64|amd64" m) "x86_64"]
    [(regexp-match? #px"aarch64|arm64" m) "aarch64"]
    [(regexp-match? #px"(?:^|[^a-z0-9])(?:i[3-6]86|x86)(?:[^a-z0-9]|$)" m) "i386"]
    [(regexp-match? #px"arm32|armv7|armv6|(?:^|[^a-z0-9])arm(?:[^a-z0-9]|$)" m) "arm"]
    [(regexp-match? #px"riscv64" m) "riscv64"]
    [(regexp-match? #px"ppc|powerpc" m) "ppc"]
    [else m*]))

(define (linux-platform-token)
  "linux")

(define (arch-token->normalized token)
  (cond
    [(equal? token "x86_64") "x86_64"]
    [(equal? token "aarch64") "aarch64"]
    [(equal? token "arm64") "aarch64"]
    [(equal? token "i386") "i386"]
    [(equal? token "arm") "arm"]
    [(equal? token "riscv64") "riscv64"]
    [(or (equal? token "ppc")
         (equal? token "powerpc")
         (equal? token "ppc64")
         (equal? token "ppc64le")
         (equal? token "powerpc64")
         (equal? token "powerpc64le"))
     "ppc"]
    [else token]))
