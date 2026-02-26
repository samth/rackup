#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         racket/system
         "paths.rkt"
         "remote.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt"
         "versioning.rkt")

(provide install-toolchain!
         remove-toolchain!
         enumerate-toolchain-executables
         doctor-report)

(define (installer-cache-file installer-url)
  (build-path (rackup-download-cache-dir)
              (path-basename-string (string->path
                                     (car (reverse (string-split installer-url "/")))))))

(define (ensure-installer-cached! installer-url #:no-cache? [no-cache? #f])
  (ensure-rackup-layout!)
  (define cache-path (installer-cache-file installer-url))
  (when (or no-cache? (not (file-exists? cache-path)))
    (displayln (format "Downloading installer: ~a" installer-url))
    (download-url->file installer-url cache-path)
    (file-or-directory-permissions cache-path #o755))
  cache-path)

(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))

(define (run-linux-installer! installer-file install-root)
  ;; Use the same dest/in-place flow as setup-racket for Linux.
  (define installer (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (displayln (format "Installing into ~a" (path->string dest)))
  (system*/check 'linux-installer
                 (shell-exe)
                 installer
                 "--create-dir"
                 "--in-place"
                 "--dest"
                 dest))

(define (detect-bin-dir install-root)
  (define p1 (build-path install-root "bin"))
  (define p2 (build-path install-root "racket" "bin"))
  (cond
    [(directory-exists? p1) p1]
    [(directory-exists? p2) p2]
    [else (rackup-error "could not find Racket bin dir under ~a" (path->string* install-root))]))

(define (file-executable?/safe p)
  (and (file-exists? p)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (member 'execute (file-or-directory-permissions p)))))

(define (enumerate-toolchain-executables real-bin-dir)
  (sort
   (for/list ([p (in-list (directory-list real-bin-dir #:build? #t))]
              #:when (and (file-exists? p) (file-executable?/safe p)))
     (path-basename-string p))
   string<?))

(define (make-bin-link! id real-bin-dir)
  (define link (rackup-toolchain-bin-link id))
  (when (link-exists? link) (delete-file link))
  (when (directory-exists? link)
    (delete-directory/files link))
  (make-file-or-directory-link real-bin-dir link)
  link)

(define (toolchain-meta request id real-bin-dir executables)
  (hash 'id id
        'kind (hash-ref request 'kind)
        'requested-spec (hash-ref request 'requested-spec)
        'resolved-version (hash-ref request 'resolved-version)
        'variant (hash-ref request 'variant)
        'distribution (hash-ref request 'distribution)
        'arch (hash-ref request 'arch)
        'platform (hash-ref request 'platform)
        'snapshot-site (hash-ref request 'snapshot-site #f)
        'snapshot-stamp (hash-ref request 'snapshot-stamp #f)
        'installer-url (hash-ref request 'installer-url)
        'installer-filename (hash-ref request 'installer-filename)
        'install-root (path->string* (rackup-toolchain-install-dir id))
        'bin-link (path->string* (rackup-toolchain-bin-link id))
        'real-bin-dir (path->string* real-bin-dir)
        'executables executables
        'installed-at (current-iso8601)))

(define (canonical-id-for-request request)
  (canonical-toolchain-id (hash-ref request 'kind)
                          #:resolved-version (hash-ref request 'resolved-version)
                          #:variant (hash-ref request 'variant)
                          #:arch (hash-ref request 'arch)
                          #:platform (hash-ref request 'platform)
                          #:distribution (hash-ref request 'distribution)
                          #:snapshot-site (hash-ref request 'snapshot-site #f)
                          #:snapshot-stamp (hash-ref request 'snapshot-stamp #f)))

(define (parse-install-options opts)
  (define variant #f)
  (define distribution 'full)
  (define snapshot-site 'auto)
  (define arch (normalized-host-arch))
  (define set-default? #f)
  (define force? #f)
  (define no-cache? #f)
  (let loop ([rest opts])
    (match rest
      ['() (hash 'variant variant
                 'distribution distribution
                 'snapshot-site snapshot-site
                 'arch arch
                 'set-default? set-default?
                 'force? force?
                 'no-cache? no-cache?)]
      [(list "--variant" v more ...)
       (set! variant v)
       (loop more)]
      [(list "--distribution" d more ...)
       (set! distribution d)
       (loop more)]
      [(list "--snapshot-site" s more ...)
       (set! snapshot-site (string->symbol s))
       (loop more)]
      [(list "--arch" a more ...)
       (set! arch (arch-token->normalized a))
       (loop more)]
      [(list "--set-default" more ...)
       (set! set-default? #t)
       (loop more)]
      [(list "--force" more ...)
       (set! force? #t)
       (loop more)]
      [(list "--no-cache" more ...)
       (set! no-cache? #t)
       (loop more)]
      [(list flag _ ...)
       (rackup-error "unknown install flag: ~a" flag)])))

(define (install-toolchain! spec opts)
  (ensure-rackup-layout!)
  (ensure-index!)
  (define parsed-opts (parse-install-options opts))
  (define request
    (resolve-install-request spec
                             #:variant (hash-ref parsed-opts 'variant)
                             #:distribution (hash-ref parsed-opts 'distribution)
                             #:arch (hash-ref parsed-opts 'arch)
                             #:snapshot-site (hash-ref parsed-opts 'snapshot-site)))
  (define id (canonical-id-for-request request))
  (define tc-dir (rackup-toolchain-dir id))
  (define install-root (rackup-toolchain-install-dir id))
  (cond
    [(directory-exists? tc-dir)
     (if (hash-ref parsed-opts 'force? #f)
         (begin
           (delete-directory/files tc-dir)
           (install-toolchain! spec opts))
         (begin
           (displayln (format "Already installed: ~a" id))
           (when (hash-ref parsed-opts 'set-default? #f)
             (set-default-toolchain! id))
           (reshim!)
           id))]
    [else
     (define installer-path
       (ensure-installer-cached! (hash-ref request 'installer-url)
                                 #:no-cache? (hash-ref parsed-opts 'no-cache? #f)))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (when (directory-exists? tc-dir)
                          (delete-directory/files tc-dir))
                        (raise e))])
       (make-directory* tc-dir)
       (run-linux-installer! installer-path install-root)
       (define real-bin-dir (detect-bin-dir install-root))
       (make-bin-link! id real-bin-dir)
       (ensure-toolchain-addon-dir! id)
       (define executables (enumerate-toolchain-executables real-bin-dir))
       (define meta (toolchain-meta request id real-bin-dir executables))
       (register-toolchain! id meta)
       (when (hash-ref parsed-opts 'set-default? #f)
         (set-default-toolchain! id))
       (reshim!)
       (displayln (format "Installed ~a" id))
       id)]))

(define (remove-toolchain! id)
  (ensure-index!)
  (unless (toolchain-exists? id)
    (rackup-error "toolchain not installed: ~a" id))
  (define tc-dir (rackup-toolchain-dir id))
  (define addon (rackup-addon-dir id))
  (when (directory-exists? tc-dir)
    (delete-directory/files tc-dir))
  (when (directory-exists? addon)
    (delete-directory/files addon))
  (unregister-toolchain! id)
  (reshim!)
  (displayln (format "Removed ~a" id)))

(define (doctor-report)
  (ensure-rackup-layout!)
  (ensure-index!)
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (define default-id (get-default-toolchain idx))
  (define findings
    (list
     (cons 'home (path->string* (rackup-home)))
     (cons 'bin (path->string* (rackup-bin-entry)))
     (cons 'shim-dispatcher (path->string* (rackup-shim-dispatcher)))
     (cons 'shims-dir (path->string* (rackup-shims-dir)))
     (cons 'installed-count (length ids))
     (cons 'default default-id)))
  (for ([kv findings])
    (printf "~a: ~a\n" (car kv) (cdr kv)))
  (for ([id ids])
    (define m (read-toolchain-meta id))
    (printf "toolchain ~a => ~a (~a, ~a)\n"
            id
            (hash-ref m 'resolved-version #f)
            (hash-ref m 'variant #f)
            (hash-ref m 'distribution #f))))
