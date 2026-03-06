#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         net/http-client
         net/url
         "legacy-plt-catalog.rkt"
         "legacy.rkt"
         "rktd-io.rkt"
         "util.rkt"
         "versioning.rkt")

(provide lookup-stable-version
         parse-all-versions-html
         fetch-all-release-versions
         fetch-table-rktd
         fetch-version-rktd
         fetch-snapshot-stamp
         parse-installer-filename
         parse-legacy-installer-filename
         parse-legacy-installers-index-html
         parse-plt-version-page-html
         select-installer-filename
         select-installer-filename/by-ext
         select-legacy-installer-filename
         select-plt-generated-page-url
         plt-generated-page-url->installer-filename
         resolve-install-request
         download-url->file)

(define release-version-url "https://download.racket-lang.org/version.txt")
(define all-versions-url "https://download.racket-lang.org/all-versions.html")
(define pre-release-installers-base "https://pre-release.racket-lang.org/installers/")
(define snapshot-sites
  (hash 'utah "https://users.cs.utah.edu/plt" 'northwestern "https://plt.cs.northwestern.edu"))

(define current-http-sendrecv-proc
  (make-parameter http-sendrecv))

(define (status-code status-line)
  (define h
    (if (bytes? status-line)
        (bytes->string/utf-8 status-line)
        status-line))
  (match (regexp-match #px"^HTTP/[0-9.]+ ([0-9][0-9][0-9])" h)
    [(list _ code) (string->number code)]
    [_ #f]))

(define (header-ref headers field)
  (for/or ([header (in-list headers)])
    (define s (bytes->string/utf-8 header))
    (match (regexp-match (regexp (format "(?i:^~a:)[\t ]*(.*)$" (regexp-quote field))) s)
      [(list _ value) (string-trim value)]
      [_ #f])))

(define (url->request-target u)
  (define s (url->string u))
  (match (regexp-match #px"^[a-z]+://[^/]+([^#]*)" s)
    [(list _ path+query)
     (cond
       [(string=? path+query "") "/"]
       [(string-prefix? path+query "/") path+query]
       [else (string-append "/" path+query)])]
    [_ "/"]))

(define (redirect-url base-url location)
  (if (regexp-match? #px"^[a-zA-Z][a-zA-Z0-9+.-]*://" location)
      (string->url location)
      (combine-url/relative base-url location)))

(define (http-open/input url-str [redirects-left 5])
  (define u (if (url? url-str) url-str (string->url url-str)))
  (define scheme (url-scheme u))
  (define host (url-host u))
  (define port (url-port u))
  (unless (and scheme host)
    (rackup-error "invalid URL: ~a" (if (url? url-str) (url->string url-str) url-str)))
  (define ssl? (equal? scheme "https"))
  (define-values (status-line headers in)
    ((current-http-sendrecv-proc) host
                                  (url->request-target u)
                                  #:ssl? ssl?
                                  #:port (or port (if ssl? 443 80))
                                  #:content-decode '(gzip deflate)))
  (define code (status-code status-line))
  (cond
    [(not code)
     (close-input-port in)
     (rackup-error "could not parse HTTP status line while fetching ~a" (url->string u))]
    [(member code '(301 302 303 307 308))
     (define location (header-ref headers "Location"))
     (close-input-port in)
     (unless location
       (rackup-error "HTTP request redirected without Location header (~a): ~a"
                     code
                     (url->string u)))
     (unless (positive? redirects-left)
       (rackup-error "too many HTTP redirects while fetching ~a" (url->string u)))
     (http-open/input (redirect-url u location) (sub1 redirects-left))]
    [(equal? code 200) in]
    [else
     (close-input-port in)
     (rackup-error "HTTP request failed (~a): ~a" code (url->string u))]))

(define (http-get-string url-str)
  (define in (http-open/input url-str))
  (dynamic-wind void
                (lambda ()
                  (port->string in))
                (lambda ()
                  (close-input-port in))))

(define (http-get-rktd url-str)
  (define in (http-open/input url-str))
  (dynamic-wind
   void
   (lambda ()
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (rackup-error "failed to read .rktd response from ~a: ~a"
                                      url-str
                                      (exn-message e)))])
       (read-rktd/port in)))
   (lambda ()
     (close-input-port in))))

(define (download-url->file url-str dest-path)
  (make-directory* (or (path-only dest-path) "."))
  (define in (http-open/input url-str))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file* dest-path
       #:exists 'truncate/replace
       (lambda (out)
         (copy-port in out))))
   (lambda ()
     (close-input-port in)))
  dest-path)

(define version-re #px"\\(stable \"([^\"]+)\"\\)")

(define (lookup-stable-version)
  (match (regexp-match version-re (http-get-string release-version-url))
    [(list _ v) v]
    [_ (rackup-error "failed to parse stable version from ~a" release-version-url)]))

(define (parse-all-versions-html html)
  (define (extract rx)
    (for/list ([m (in-list (regexp-match* rx html #:match-select cdr))])
      (car m)))
  ;; Prefer versions that appear in release/installers links.
  (define from-links
    (append
     (extract #px"href=\"(?:[^\"]*/)?(?:releases|installers)/([0-9]+(?:\\.[0-9]+){1,3})/?(?:[\"#?])")
     (extract
      #px"https?://download[.]racket-lang[.]org/(?:releases|installers)/([0-9]+(?:\\.[0-9]+){1,3})/?")))
  ;; Current page uses table rows like `<strong>Version 9.1</strong>`.
  (define from-version-labels (extract #px"\\bVersion\\s+([0-9]+(?:\\.[0-9]+){1,3})\\b"))
  ;; Fall back to anchored text if link formats drift.
  (define from-anchor-text (extract #px"<a[^>]*>\\s*([0-9]+(?:\\.[0-9]+){1,3})\\s*</a>"))
  (define candidates (append from-links from-version-labels from-anchor-text))
  (define versions (remove-duplicates (filter numeric-version? candidates) string=?))
  (sort versions (lambda (a b) (> (cmp-versions a b) 0))))

(define (fetch-all-release-versions)
  (define html (http-get-string all-versions-url))
  (define versions (parse-all-versions-html html))
  (unless (pair? versions)
    (rackup-error "failed to parse release versions from ~a" all-versions-url))
  versions)

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

(define (fetch-plt-scheme-installer-filename version
                                             #:distribution distribution
                                             #:arch arch
                                             #:platform [platform "linux"])
  (unless (eq? distribution 'full)
    (rackup-error "PLT Scheme releases (~a) do not support --distribution ~a" version distribution))
  (define page-html (http-get-string (plt-version-page-url version)))
  (define generated-urls (parse-plt-version-page-html page-html))
  (define generated-url
    (select-plt-generated-page-url generated-urls #:version version #:arch arch #:platform platform))
  (define filename (plt-generated-page-url->installer-filename generated-url version))
  (values (format "~abundles/~a/plt/" plt-scheme-download-base version) filename))

(define (fetch-legacy-installer-filename version
                                         #:distribution distribution
                                         #:arch arch
                                         #:platform [platform "linux"])
  (define base (legacy-installers-base-url-for-release version distribution))
  (define html (http-get-string base))
  (define filenames (parse-legacy-installers-index-html html))
  (values base
          (select-legacy-installer-filename filenames
                                            #:version-token version
                                            #:distribution distribution
                                            #:arch arch
                                            #:platform platform
                                            #:ext "sh")))

(define (release-request-hash requested-spec
                              resolved-version
                              variant
                              distribution*
                              arch
                              platform
                              base
                              filename)
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
        (string-append base filename)))

(define (exn-message-looks-like-404? e)
  (regexp-match? #px"\\b404\\b" (exn-message e)))

(define (resolve-release-request/fallback requested-spec
                                          resolved-version
                                          variant
                                          distribution*
                                          arch
                                          platform
                                          preferred-exts)
  (cond
    [(version-maybe-plt-scheme? resolved-version)
     (define plt-request
       (legacy-plt-request-info resolved-version
                                #:distribution distribution*
                                #:arch arch
                                #:platform platform))
     (define filename* (hash-ref plt-request 'filename))
     (define url* (hash-ref plt-request 'url))
     (define base* (substring url* 0 (- (string-length url*) (string-length filename*))))
     (hash-set*
      (release-request-hash requested-spec
                            resolved-version
                            variant
                            distribution*
                            arch
                            platform
                            base*
                            filename*)
      'installer-sha256
      (hash-ref plt-request 'sha256)
      'legacy-install-kind
      (hash-ref plt-request 'install-kind))]
    [else
     (define base (installers-base-url-for-release resolved-version))
     (define table
       (with-handlers ([exn:fail? (lambda (e)
                                    (if (exn-message-looks-like-404? e)
                                        #f
                                        (raise e)))])
         (fetch-table-rktd base)))
     (cond
       [table
     (define filename
       (select-installer-filename/by-ext table
                                         #:version-token resolved-version
                                         #:variant variant
                                         #:distribution distribution*
                                         #:arch arch
                                         #:platform platform
                                         #:exts preferred-exts
                                         #:allow-version-prefix? #t))
     (release-request-hash requested-spec
                           resolved-version
                           variant
                           distribution*
                           arch
                           platform
                           base
                           filename)]
       [else
        ;; Older Racket releases may use Apache index listings (e.g. 5.2).
        (define legacy-result
          (call-with-values (lambda ()
                              (fetch-legacy-installer-filename resolved-version
                                                               #:distribution distribution*
                                                               #:arch arch
                                                               #:platform platform))
                            list))
        (define base* (first legacy-result))
        (define filename* (second legacy-result))
        (release-request-hash requested-spec
                              resolved-version
                              variant
                              distribution*
                              arch
                              platform
                              base*
                              filename*)])]))

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

(define (select-installer-filename/by-ext table
                                          #:version-token version-token
                                          #:variant variant
                                          #:distribution distribution
                                          #:arch arch
                                          #:platform [platform "linux"]
                                          #:exts [exts '("sh")]
                                          #:allow-version-prefix? [allow-version-prefix? #f])
  (let loop ([rest exts]
             [last-exn #f])
    (cond
      [(null? rest)
       (if last-exn
           (raise last-exn)
           (rackup-error
            "no installer found in table for version-token=~a variant=~a distro=~a arch=~a platform=~a exts=~a"
            version-token
            variant
            distribution
            arch
            platform
            exts))]
      [else
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (loop (cdr rest) e))])
         (select-installer-filename table
                                    #:version-token version-token
                                    #:variant variant
                                    #:distribution distribution
                                    #:arch arch
                                    #:platform platform
                                    #:ext (car rest)
                                    #:allow-version-prefix? allow-version-prefix?))])))

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

(define (select-snapshot-installer-filename table
                                            version-rktd
                                            #:variant variant
                                            #:distribution distribution
                                            #:arch arch
                                            #:platform [platform "linux"]
                                            #:exts [exts '("sh" "tgz")])
  (define resolved-version (resolved-version-from-version-rktd version-rktd "current"))
  (define fallback-token
    (if (and (string? resolved-version) (not (equal? resolved-version "current")))
        resolved-version
        (best-version-token-from-table table "current")))
  (define (select token #:allow-prefix? [allow-prefix? #f])
    (select-installer-filename/by-ext table
                                      #:version-token token
                                      #:variant variant
                                      #:distribution distribution
                                      #:arch arch
                                      #:platform platform
                                      #:exts exts
                                      #:allow-version-prefix? allow-prefix?))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (cond
                       [(numeric-version? fallback-token) (select fallback-token #:allow-prefix? #t)]
                       [(not (equal? fallback-token "current")) (select fallback-token)]
                       [else (raise e)]))])
    (select "current")))

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
        (void (select-snapshot-installer-filename table
                                                  version-rktd
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
                                 #:platform [platform-override #f]
                                 #:snapshot-site [snapshot-site-opt 'auto]
                                 #:installer-ext [installer-ext-override #f])
  (define spec*
    (if (string? spec)
        (parse-install-spec spec)
        spec))
  (define kind (hash-ref spec* 'kind))
  (define distribution* (parse-distribution distribution))
  (define requested-spec (hash-ref spec* 'input ""))
  (define platform (or platform-override (host-platform-token)))
  (define preferred-exts
    (if installer-ext-override
        (list installer-ext-override)
        (match platform
          ["macosx"  '("tgz" "dmg")]
          ["linux"   '("sh" "tgz")]
          [_ (rackup-error "no installer extension preferences for platform: ~a" platform)])))
  (define (variant-for version)
    (define legacy-plt? (version-maybe-plt-scheme? version))
    (define v
      (if variant-override
          (parse-variant variant-override)
          (if legacy-plt?
              'bc
              (default-variant-for-version version))))
    (when (and legacy-plt? (equal? v 'cs))
      (rackup-error "Racket CS is not available for PLT Scheme version ~a" version))
    (when (and (not legacy-plt?) (equal? v 'cs) (not (cs-supported? version)))
      (rackup-error "Racket CS is not available for version ~a" version))
    v)
  (match kind
    ['stable
     (define resolved-version (lookup-stable-version))
     (define variant (variant-for resolved-version))
     (resolve-release-request/fallback requested-spec
                                       resolved-version
                                       variant
                                       distribution*
                                       arch
                                       platform
                                       preferred-exts)]
    ['release
     (define resolved-version (hash-ref spec* 'version))
     (define variant (variant-for resolved-version))
     (resolve-release-request/fallback requested-spec
                                       resolved-version
                                       variant
                                       distribution*
                                       arch
                                       platform
                                       preferred-exts)]
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
       (select-installer-filename/by-ext table
                                         #:version-token token
                                         #:variant variant
                                         #:distribution distribution*
                                         #:arch arch
                                         #:platform platform
                                         #:exts preferred-exts
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
       (select-snapshot-installer-filename table
                                           version-rktd
                                           #:variant variant
                                           #:distribution distribution*
                                           #:arch arch
                                           #:platform platform
                                           #:exts preferred-exts))
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
