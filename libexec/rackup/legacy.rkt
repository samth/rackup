#lang racket/base

;; Consolidated legacy/pre-6.1.1 handling for PLT Scheme and older Racket
;; releases. Factored out from remote.rkt and install.rkt (Issue #20).

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "legacy-plt-catalog.rkt"
         "rktd-io.rkt"
         "util.rkt"
         "versioning.rkt")

(provide plt-scheme-download-base
         legacy-installers-base-url-for-release
         plt-version-page-url
         legacy-installer-rx
         parse-legacy-installer-filename
         parse-legacy-installers-index-html
         parse-plt-version-page-html
         select-legacy-installer-filename
         plt-version->hyphenated
         select-plt-generated-page-url
         plt-generated-page-url->installer-filename
         version-maybe-plt-scheme?
         legacy-interactive-linux-installer?
         detect-shell-installer-mode
         legacy-installer-input-script
         maybe-modernize-legacy-archsys!)

;; -------- Constants --------

(define plt-scheme-download-base "http://download.plt-scheme.org/")

;; -------- URL helpers --------

(define (legacy-installers-base-url-for-release version distribution)
  (define subdir
    (case distribution
      [(full) "racket"]
      [(minimal) "racket-textual"]
      [else (rackup-error "unsupported legacy distribution: ~a" distribution)]))
  (format "https://download.racket-lang.org/installers/~a/~a/" version subdir))

(define (plt-version-page-url version)
  (format "~av~a.html" plt-scheme-download-base version))

;; -------- Filename parsing --------

(define legacy-installer-rx
  #px"^(racket(?:-textual)?)-([0-9]+(?:\\.[0-9]+){0,3})-bin-(.+)\\.([A-Za-z0-9]+)$")

(define (parse-legacy-installer-filename s)
  (match (regexp-match legacy-installer-rx s)
    [(list _ prefix version-token platform-token ext-s)
     (define distribution (if (equal? prefix "racket-textual") 'minimal 'full))
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
           'bc
           'ext
           (string-downcase ext-s))]
    [_ #f]))

;; -------- HTML parsing --------

(define (parse-legacy-installers-index-html html)
  (define hrefs
    (for/list ([m (in-list (regexp-match* #px"href=\"([^\"]+)\"" html #:match-select cdr))])
      (car m)))
  (remove-duplicates
   (filter values
           (for/list ([h (in-list hrefs)])
             (and (string? h) (regexp-match? #px"^(?:racket|racket-textual)-.+\\.sh$" h) h)))
   string=?))

(define (parse-plt-version-page-html html)
  (remove-duplicates
   (for/list ([m (in-list (regexp-match*
                           #px"<option[^>]*value=\"(https?://download[.]plt-scheme[.]org/[^\"]+)\""
                           html
                           #:match-select cdr))])
     (car m))
   string=?))

;; -------- Installer selection --------

(define (select-legacy-installer-filename filenames
                                          #:version-token version-token
                                          #:distribution distribution
                                          #:arch arch
                                          #:platform [platform "linux"]
                                          #:ext [ext "sh"])
  (define parsed (filter values (map parse-legacy-installer-filename filenames)))
  (define matches
    (for/list ([p parsed]
               #:when (and (equal? (hash-ref p 'version-token) version-token)
                           (equal? (hash-ref p 'distribution) distribution)
                           (equal? (hash-ref p 'arch) arch)
                           (equal? (hash-ref p 'platform-family) platform)
                           (equal? (hash-ref p 'ext) ext)))
      (hash-ref p 'filename)))
  (cond
    [(pair? matches) (car (sort matches string<?))]
    [else
     (rackup-error "no legacy installer found for version=~a distro=~a arch=~a platform=~a ext=~a"
                   version-token
                   distribution
                   arch
                   platform
                   ext)]))

(define (plt-version->hyphenated version)
  (regexp-replace* #px"[.]" version "-"))

(define (select-plt-generated-page-url urls
                                       #:version version
                                       #:arch arch
                                       #:platform [platform "linux"])
  (define version* (plt-version->hyphenated version))
  (define (base-name u)
    (path-basename-string (string->path (path->string* u))))
  (define (candidate-for-platform? base)
    (and (string-prefix? base (format "plt-~a-bin-" version*))
         (string-contains? base (format "-~a-" platform))
         (string-suffix? base "-sh.html")))
  (define matches
    (for/list ([u (in-list urls)]
               #:when (let ([base (base-name u)])
                        (and (candidate-for-platform? base)
                             (string-contains? base (format "-~a-" arch)))))
      (path->string* u)))
  (cond
    [(pair? matches) (car (sort matches string<?))]
    [else
     (define platform-urls
       (for/list ([u (in-list urls)]
                  #:when (candidate-for-platform? (base-name u)))
         (path->string* u)))
     (define hint
       (cond
         [(and (equal? platform "linux")
               (equal? arch "x86_64")
               (for/or ([u (in-list platform-urls)])
                 (string-contains? (base-name u) "-i386-")))
          " (this PLT Scheme version appears to have only i386 Linux installers; try --arch i386)"]
         [else ""]))
     (rackup-error "no PLT Scheme installer page found for version=~a arch=~a platform=~a~a"
                   version
                   arch
                   platform
                   hint)]))

(define (plt-generated-page-url->installer-filename page-url version)
  (define base (path-basename-string (string->path (path->string* page-url))))
  (define version* (plt-version->hyphenated version))
  (match (regexp-match (pregexp (format "^plt-~a-bin-(.+)-sh[.]html$" (regexp-quote version*))) base)
    [(list _ platform-token) (format "plt-~a-bin-~a.sh" version platform-token)]
    [_ (rackup-error "unexpected PLT Scheme generated page URL: ~a" page-url)]))

(define (version-maybe-plt-scheme? v)
  (legacy-plt-version? v))

;; -------- Installer mode detection --------

(define (legacy-interactive-linux-installer? installer-file)
  (regexp-match? #px"(?:^|/)(?:racket(?:-textual)?|plt)-.+-bin-.+[.]sh$"
                 (path->string* installer-file)))

(define (read-file-prefix-bytes p [limit 65536])
  (call-with-input-file* p (lambda (in) (or (read-bytes limit in) #""))))

(define (detect-shell-installer-mode installer-file)
  ;; Some older Racket shell installers (notably 6.0) have modern-looking
  ;; filenames but only support interactive prompting. Detect them from the
  ;; script header instead of guessing from the filename alone.
  (define prefix
    (with-handlers ([exn:fail? (lambda (_) #"")])
      (read-file-prefix-bytes installer-file)))
  (cond
    [(and (regexp-match? #rx#"Command-line flags:" prefix)
          (regexp-match? #rx#"--dest" prefix)
          (regexp-match? #rx#"--in-place" prefix))
     'modern]
    [(regexp-match? #rx#"Do you want a Unix-style distribution\\?" prefix) 'shell-unixstyle]
    [(regexp-match? #rx#"Where do you want to install the \"" prefix) 'shell-basic]
    [else #f]))

(define (legacy-installer-input-script dest legacy-install-kind)
  ;; Old PLT/Racket installers (e.g. 5.2, 4.x/3xx) do not support --dest/--in-place.
  ;; Answer prompts for a whole-directory install into the exact requested destination,
  ;; then skip creating system links.
  (case legacy-install-kind
    [(shell-basic) (format "~a\n\n" (path->string* dest))]
    [(shell-unixstyle) (format "n\n~a\n\n" (path->string* dest))]
    [else (rackup-error "unknown legacy installer kind: ~a" legacy-install-kind)]))

(define (maybe-modernize-legacy-archsys! real-bin-dir)
  (define plthome (path-only real-bin-dir))
  (define archsys (and plthome (build-path plthome "bin" "archsys")))
  (when (and archsys (file-exists? archsys))
    (define content (file->string archsys))
    (define updated
      (regexp-replace* #px"file /bin/ls \\| grep ELF \\| wc -l"
                       content
                       "file -L /bin/ls 2>/dev/null | grep ELF | wc -l"))
    (unless (equal? updated content)
      (write-string-file archsys updated)
      (file-or-directory-permissions archsys #o755))))
