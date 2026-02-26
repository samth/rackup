#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "util.rkt"
         "versioning.rkt")

(provide lookup-stable-version
         fetch-table-rktd
         fetch-version-rktd
         fetch-snapshot-stamp
         parse-installer-filename
         select-installer-filename
         resolve-install-request
         download-url->file)

(define release-version-url "https://download.racket-lang.org/version.txt")
(define pre-release-installers-base "https://pre-release.racket-lang.org/installers/")
(define snapshot-sites
  (hash 'utah "https://users.cs.utah.edu/plt" 'northwestern "https://plt.cs.northwestern.edu"))

(define (status-code headers)
  (define h
    (if (bytes? headers)
        (bytes->string/utf-8 headers)
        headers))
  (match (regexp-match #px"^HTTP/[0-9.]+ ([0-9][0-9][0-9])" h)
    [(list _ code) (string->number code)]
    [_ #f]))

(define net/url:string->url #f)
(define net/url:get-pure-port/headers #f)
(define net/url:loaded? #f)

(define (ensure-net/url!)
  (unless net/url:loaded?
    (set! net/url:string->url (dynamic-require 'net/url 'string->url))
    (set! net/url:get-pure-port/headers (dynamic-require 'net/url 'get-pure-port/headers))
    (set! net/url:loaded? #t)))

(define (http-external-tool)
  (cond
    [(find-executable-path "curl") => (lambda (p) (cons 'curl p))]
    [(find-executable-path "wget") => (lambda (p) (cons 'wget p))]
    [else #f]))

(define (command-display-string args)
  (string-join (map path->string* args) " "))

(define (system*/capture who . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (if (apply system* args)
        (get-output-string out)
        (rackup-error "~a failed: ~a~a"
                      who
                      (command-display-string args)
                      (let ([e (string-trim (get-output-string err))])
                        (if (string-blank? e) "" (string-append "\n" e)))))))

(define (external-http-get-string url-str)
  (match (http-external-tool)
    [(cons 'curl exe) (system*/capture 'curl exe "-fsSL" url-str)]
    [(cons 'wget exe) (system*/capture 'wget exe "-qO-" url-str)]
    [_ #f]))

(define (external-download-url->file url-str dest-path)
  (make-directory* (or (path-only dest-path) "."))
  (match (http-external-tool)
    [(cons 'curl exe)
     (system*/check 'curl-download exe "-fsSL" url-str "-o" dest-path)
     dest-path]
    [(cons 'wget exe)
     (system*/check 'wget-download exe "-qO" dest-path url-str)
     dest-path]
    [_ #f]))

(define (http-open/racket url-str)
  (ensure-net/url!)
  (define u
    (if (string? url-str)
        (net/url:string->url url-str)
        url-str))
  (define-values (in headers) (net/url:get-pure-port/headers u #:redirections 5 #:status? #t))
  (define code (status-code headers))
  (unless (equal? code 200)
    (close-input-port in)
    (rackup-error "HTTP request failed (~a): ~a"
                  code
                  (path->string* url-str)))
  in)

(define (http-get-string url-str)
  (or (external-http-get-string url-str)
      (let ([in (http-open/racket url-str)])
        (begin0 (port->string in)
          (close-input-port in)))))

(define (http-get-rktd url-str)
  (define s (http-get-string url-str))
  (define in (open-input-string s))
  (begin0 (read in)
    (close-input-port in)))

(define (download-url->file url-str dest-path)
  (or (external-download-url->file url-str dest-path)
      (let ()
        (make-directory* (or (path-only dest-path) "."))
        (define in (http-open/racket url-str))
        (call-with-output-file* dest-path
          #:exists 'truncate/replace
          (lambda (out) (copy-port in out)))
        (close-input-port in)
        dest-path)))

(define version-re #px"\\(stable \"([^\"]+)\"\\)")

(define (lookup-stable-version)
  (match (regexp-match version-re (http-get-string release-version-url))
    [(list _ v) v]
    [_ (rackup-error "failed to parse stable version from ~a" release-version-url)]))

(define (installers-base-url-for-release version)
  (format "https://download.racket-lang.org/installers/~a/" version))

(define (fetch-table-rktd installers-base)
  (http-get-rktd (string-append installers-base "table.rktd")))

(define (fetch-version-rktd installers-base)
  (http-get-rktd (string-append installers-base "version.rktd")))

(define (fetch-snapshot-stamp site)
  (http-get-string (format "~a/snapshots/current/stamp.txt" (hash-ref snapshot-sites site))))

(define installer-rx #px"^(racket(?:-minimal)?)-([^-]+)-(.+?)(?:-(bc|cs))?\\.([A-Za-z0-9]+)$")

(define (parse-installer-filename s)
  (match (regexp-match installer-rx s)
    [(list _ prefix version-token platform-token variant-s ext)
     (define variant
       (if variant-s
           (string->symbol variant-s)
           'bc))
     (define distribution (if (equal? prefix "racket-minimal") 'minimal 'full))
     (define parts (string-split platform-token "-"))
     (define arch-token
       (if (pair? parts)
           (car parts)
           platform-token))
     (define platform-parts
       (if (>= (length parts) 2)
           (cdr parts)
           null))
     (define platform
       (if (pair? platform-parts)
           (string-join platform-parts "-")
           ""))
     (define platform-family
       (if (pair? platform-parts)
           (car platform-parts)
           platform))
     (hash 'filename
           s
           'distribution
           distribution
           'version-token
           version-token
           'platform-token
           platform-token
           'arch-token
           arch-token
           'arch
           (arch-token->normalized arch-token)
           'platform
           platform
           'platform-family
           platform-family
           'platform-parts
           platform-parts
           'variant
           variant
           'ext
           (string-downcase ext))]
    [_ #f]))

(define (table-filenames table)
  (cond
    [(hash? table)
     (for/list ([v (in-hash-values table)]
                #:when (string? v))
       v)]
    [(list? table) (filter string? table)]
    [else (rackup-error "unexpected table.rktd format: ~a" table)]))

(define (table-version-tokens table)
  (remove-duplicates
   (for/list ([p (in-list (filter values (map parse-installer-filename (table-filenames table))))])
     (hash-ref p 'version-token))
   string=?))

(define (best-version-token-from-table table [default "current"])
  (define tokens (table-version-tokens table))
  (define numeric-tokens (filter numeric-version? tokens))
  (cond
    [(pair? numeric-tokens) (car (sort numeric-tokens (lambda (a b) (> (cmp-versions a b) 0))))]
    [(member "current" tokens) "current"]
    [(pair? tokens) (car (sort tokens string<?))]
    [else default]))

(define (select-installer-filename table
                                   #:version-token version-token
                                   #:variant variant
                                   #:distribution distribution
                                   #:arch arch
                                   #:platform [platform "linux"]
                                   #:ext [ext "sh"]
                                   #:allow-version-prefix? [allow-version-prefix? #f])
  (define (version-token-match? token wanted)
    (or (equal? token wanted)
        (and allow-version-prefix?
             (regexp-match? (pregexp (string-append "^" (regexp-quote wanted) "(?:[.]|$)")) token))))
  (define parsed (filter values (map parse-installer-filename (table-filenames table))))
  (define (normal-platform-installer? p)
    (define parts (hash-ref p 'platform-parts null))
    (cond
      [(equal? platform "linux")
       (and (pair? parts)
            (equal? (car parts) "linux")
            (not (member "natipkg" parts))
            (not (member "pkg-build" parts)))]
      [else (equal? (hash-ref p 'platform-family (hash-ref p 'platform "")) platform)]))
  (define matches
    (for/list ([p parsed]
               #:when (and (version-token-match? (hash-ref p 'version-token) version-token)
                           (equal? (hash-ref p 'variant) variant)
                           (equal? (hash-ref p 'distribution) distribution)
                           (equal? (hash-ref p 'arch) arch)
                           (normal-platform-installer? p)
                           (equal? (hash-ref p 'ext) ext)))
      (hash-ref p 'filename)))
  (cond
    [(pair? matches) (car (sort matches string<?))]
    [else
     (rackup-error
      "no installer found in table for version-token=~a variant=~a distro=~a arch=~a platform=~a ext=~a"
      version-token
      variant
      distribution
      arch
      platform
      ext)]))

(define (symbol-site s)
  (cond
    [(symbol? s) s]
    [(string? s) (string->symbol s)]
    [else s]))

(define (parse-variant v)
  (cond
    [(or (equal? v 'cs) (equal? v "cs") (equal? v "CS")) 'cs]
    [(or (equal? v 'bc) (equal? v "bc") (equal? v "BC")) 'bc]
    [else (rackup-error "invalid variant: ~a (expected cs|bc)" v)]))

(define (parse-distribution d)
  (cond
    [(or (equal? d 'full) (equal? d "full")) 'full]
    [(or (equal? d 'minimal) (equal? d "minimal")) 'minimal]
    [else (rackup-error "invalid distribution: ~a (expected full|minimal)" d)]))

(define (normalize-site-option spec-site cli-site)
  (define s1 (and spec-site (symbol-site spec-site)))
  (define s2 (and cli-site (symbol-site cli-site)))
  (define (valid-site? s)
    (member s '(auto utah northwestern)))
  (unless (or (not s1) (valid-site? s1))
    (rackup-error "invalid snapshot site: ~a" s1))
  (unless (or (not s2) (valid-site? s2))
    (rackup-error "invalid snapshot site: ~a" s2))
  (cond
    [(and s1 (not (equal? s1 'auto))) s1]
    [(and s2 (not (equal? s2 'auto))) s2]
    [else 'auto]))

(define (snapshot-installers-base site)
  (format "~a/snapshots/current/installers/" (hash-ref snapshot-sites site)))

(define (try-resolve-snapshot-site sites #:distribution distribution #:arch arch #:variant variant)
  (define results
    (for/list ([site sites])
      (with-handlers ([exn:fail? (lambda (_)
                                   (hash 'site site 'ok? #f 'stamp "" 'table #f 'version #f))])
        (define stamp (string-trim (fetch-snapshot-stamp site)))
        (define base (snapshot-installers-base site))
        (define version-rktd (fetch-version-rktd base))
        (define table (fetch-table-rktd base))
        ;; Ensure the requested combo exists before choosing this site.
        (void (select-installer-filename table
                                         #:version-token "current"
                                         #:variant variant
                                         #:distribution distribution
                                         #:arch arch))
        (hash 'site site 'ok? #t 'stamp stamp 'table table 'version version-rktd))))
  (define ok-results (filter (lambda (r) (hash-ref r 'ok? #f)) results))
  (unless (pair? ok-results)
    (rackup-error "no live snapshot sites with a matching installer for this request"))
  (car (sort ok-results (lambda (a b) (string>? (hash-ref a 'stamp "") (hash-ref b 'stamp ""))))))

(define (resolved-version-from-version-rktd v default)
  (cond
    [(string? v) v]
    [(and (hash? v) (string? (hash-ref v 'version #f))) (hash-ref v 'version)]
    [(and (pair? v) (list? v)) default]
    [else default]))

(define (resolve-install-request spec
                                 #:variant [variant-override #f]
                                 #:distribution [distribution 'full]
                                 #:arch [arch (normalized-host-arch)]
                                 #:snapshot-site [snapshot-site-opt 'auto])
  (define spec*
    (if (string? spec)
        (parse-install-spec spec)
        spec))
  (define kind (hash-ref spec* 'kind))
  (define distribution* (parse-distribution distribution))
  (define requested-spec (hash-ref spec* 'input ""))
  (define platform "linux")
  (define (variant-for version)
    (define v
      (if variant-override
          (parse-variant variant-override)
          (default-variant-for-version version)))
    (when (and (equal? v 'cs) (not (cs-supported? version)))
      (rackup-error "Racket CS is not available for version ~a" version))
    v)
  (match kind
    ['stable
     (define resolved-version (lookup-stable-version))
     (define variant (variant-for resolved-version))
     (define base (installers-base-url-for-release resolved-version))
     (define table (fetch-table-rktd base))
     (define filename
       (select-installer-filename table
                                  #:version-token resolved-version
                                  #:variant variant
                                  #:distribution distribution*
                                  #:arch arch
                                  #:platform platform
                                  #:ext "sh"
                                  #:allow-version-prefix? #t))
     (hash 'kind
           'release
           'requested-spec
           requested-spec
           'resolved-version
           resolved-version
           'version-token
           resolved-version
           'variant
           variant
           'distribution
           distribution*
           'arch
           arch
           'platform
           platform
           'snapshot-site
           #f
           'snapshot-stamp
           #f
           'installers-base
           base
           'installer-filename
           filename
           'installer-url
           (string-append base filename))]
    ['release
     (define resolved-version (hash-ref spec* 'version))
     (define variant (variant-for resolved-version))
     (define base (installers-base-url-for-release resolved-version))
     (define table (fetch-table-rktd base))
     (define filename
       (select-installer-filename table
                                  #:version-token resolved-version
                                  #:variant variant
                                  #:distribution distribution*
                                  #:arch arch
                                  #:platform platform
                                  #:ext "sh"
                                  #:allow-version-prefix? #t))
     (hash 'kind
           'release
           'requested-spec
           requested-spec
           'resolved-version
           resolved-version
           'version-token
           resolved-version
           'variant
           variant
           'distribution
           distribution*
           'arch
           arch
           'platform
           platform
           'snapshot-site
           #f
           'snapshot-stamp
           #f
           'installers-base
           base
           'installer-filename
           filename
           'installer-url
           (string-append base filename))]
    ['pre-release
     (define table (fetch-table-rktd pre-release-installers-base))
     ;; pre-release.racket-lang.org may not publish installers/version.rktd.
     ;; Derive a usable version from table.rktd when that metadata is absent.
     (define maybe-version-rktd
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (fetch-version-rktd pre-release-installers-base)))
     (define resolved-version
       (let ([from-rktd (and maybe-version-rktd
                             (resolved-version-from-version-rktd maybe-version-rktd #f))])
         (cond
           [(and (string? from-rktd) (not (equal? from-rktd "current"))) from-rktd]
           [else (best-version-token-from-table table "current")])))
     (define variant (variant-for resolved-version))
     (define (select-pre-release token #:allow-prefix? [allow-prefix? #f])
       (select-installer-filename table
                                  #:version-token token
                                  #:variant variant
                                  #:distribution distribution*
                                  #:arch arch
                                  #:platform platform
                                  #:ext "sh"
                                  #:allow-version-prefix? allow-prefix?))
     (define filename
       (with-handlers ([exn:fail? (lambda (e)
                                    (if (numeric-version? resolved-version)
                                        (select-pre-release resolved-version #:allow-prefix? #t)
                                        (raise e)))])
         (select-pre-release "current")))
     (hash 'kind
           'pre-release
           'requested-spec
           requested-spec
           'resolved-version
           resolved-version
           'version-token
           "current"
           'variant
           variant
           'distribution
           distribution*
           'arch
           arch
           'platform
           platform
           'snapshot-site
           #f
           'snapshot-stamp
           #f
           'installers-base
           pre-release-installers-base
           'installer-filename
           filename
           'installer-url
           (string-append pre-release-installers-base filename))]
    ['snapshot
     (define requested-site
       (normalize-site-option (hash-ref spec* 'snapshot-site #f) snapshot-site-opt))
     (define sites-to-try
       (if (equal? requested-site 'auto)
           '(utah northwestern)
           (list requested-site)))
     ;; For snapshots, default variant assumes latest stream; override still allowed.
     (define variant
       (if variant-override
           (parse-variant variant-override)
           'cs))
     (define picked
       (try-resolve-snapshot-site sites-to-try
                                  #:distribution distribution*
                                  #:arch arch
                                  #:variant variant))
     (define site (hash-ref picked 'site))
     (define base (snapshot-installers-base site))
     (define table (hash-ref picked 'table))
     (define version-rktd (hash-ref picked 'version))
     (define stamp (hash-ref picked 'stamp))
     (define resolved-version (resolved-version-from-version-rktd version-rktd "current"))
     (when (and (equal? variant 'cs) (not (cs-supported? resolved-version)))
       (rackup-error "snapshot resolved to version without CS support: ~a" resolved-version))
     (define filename
       (select-installer-filename table
                                  #:version-token "current"
                                  #:variant variant
                                  #:distribution distribution*
                                  #:arch arch
                                  #:platform platform
                                  #:ext "sh"))
     (hash 'kind
           'snapshot
           'requested-spec
           requested-spec
           'resolved-version
           resolved-version
           'version-token
           "current"
           'variant
           variant
           'distribution
           distribution*
           'arch
           arch
           'platform
           platform
           'snapshot-site
           site
           'snapshot-stamp
           stamp
           'installers-base
           base
           'installer-filename
           filename
           'installer-url
           (string-append base filename))]
    [_ (rackup-error "unsupported install kind: ~a" kind)]))
