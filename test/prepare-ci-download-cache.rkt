#lang racket/base

(require racket/cmdline
         racket/file
         racket/path
         racket/string
         "../libexec/rackup/remote.rkt"
         "../libexec/rackup/util.rkt")

(define output-dir #f)

(command-line
 #:program "prepare-ci-download-cache.rkt"
 #:once-each
 [("--output") dir
              "Output directory for prepared installer cache"
              (set! output-dir dir)])

(unless (and output-dir (not (string-blank? output-dir)))
  (raise-user-error 'prepare-ci-download-cache "missing required --output DIR"))

(define output-root (path->complete-path (string->path output-dir)))
(define x86_64-dir (build-path output-root "x86_64"))
(define aarch64-dir (build-path output-root "aarch64"))

(define (hidden-runtime-request arch)
  (with-handlers ([exn:fail?
                   (lambda (_)
                     (resolve-install-request "stable"
                                              #:variant 'bc
                                              #:distribution 'minimal
                                              #:arch arch))])
    (resolve-install-request "stable"
                             #:variant 'cs
                             #:distribution 'minimal
                             #:arch arch)))

(define (installer-cache-file cache-dir installer-url)
  (build-path cache-dir
              (path-basename-string
               (string->path (car (reverse (string-split installer-url "/")))))))

(define (prepare-request! arch cache-dir label request)
  (define installer-url (hash-ref request 'installer-url))
  (define expected-sha256 (hash-ref request 'installer-sha256 #f))
  (define cache-path (installer-cache-file cache-dir installer-url))
  (require-checksummed-http-installer! installer-url expected-sha256)
  (printf "[~a] ~a -> ~a\n" arch label installer-url)
  (cond
    [(file-exists? cache-path)
     (verify-installer-checksum! cache-path #:sha256 expected-sha256)
     (printf "  reusing ~a\n" (path->string* cache-path))]
    [else
     (download-url->file installer-url cache-path)
     (when (regexp-match? #px"[.]sh$" (string-downcase (path->string* cache-path)))
       (file-or-directory-permissions cache-path #o755))
     (verify-installer-checksum! cache-path #:sha256 expected-sha256)
     (printf "  cached  ~a\n" (path->string* cache-path))]))

(define (prepare-arch! arch cache-dir specs)
  (make-directory* cache-dir)
  (for ([entry (in-list specs)])
    (define label (car entry))
    (define resolver (cdr entry))
    (prepare-request! arch cache-dir label (resolver arch))))

(when (directory-exists? output-root)
  (delete-directory/files output-root))
(make-directory* output-root)

(prepare-arch!
 "x86_64"
 x86_64-dir
 (list (cons "stable" (lambda (arch) (resolve-install-request "stable" #:arch arch)))
       (cons "8.18" (lambda (arch) (resolve-install-request "8.18" #:arch arch)))
       (cons "7.9" (lambda (arch) (resolve-install-request "7.9" #:arch arch)))
       (cons "6.0" (lambda (arch) (resolve-install-request "6.0" #:arch arch)))
       (cons "pre-release" (lambda (arch) (resolve-install-request "pre-release" #:arch arch)))
       (cons "hidden-runtime" hidden-runtime-request)))

(prepare-arch!
 "aarch64"
 aarch64-dir
 (list (cons "stable" (lambda (arch) (resolve-install-request "stable" #:arch arch)))
       (cons "8.18" (lambda (arch) (resolve-install-request "8.18" #:arch arch)))
       (cons "hidden-runtime" hidden-runtime-request)))

(printf "Prepared installer cache in ~a\n" (path->string* output-root))
