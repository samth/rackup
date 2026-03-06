#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "paths.rkt"
         "remote.rkt"
         "rktd-io.rkt"
         "util.rkt"
         "versioning.rkt")

(provide cmd-runtime
         hidden-runtime-status)

(define (hidden-runtime-invocation-prefix racket-exe)
  (list racket-exe
        "-U"
        "-A"
        (path->string* (ensure-directory* (rackup-runtime-addon-dir)))))

(define (capture-hidden-runtime-output racket-exe . args)
  (apply capture-program-output
         (append (hidden-runtime-invocation-prefix racket-exe) args)))

(define (run-hidden-runtime/quiet racket-exe . args)
  (apply run-quiet-program
         (append (hidden-runtime-invocation-prefix racket-exe) args)))

(define (hidden-runtime-racket-path)
  (define p (build-path (rackup-runtime-current-link) "bin" "racket"))
  (and (executable-file? p) p))

(define (hidden-runtime-present?)
  (and (hidden-runtime-racket-path) #t))

(define (runtime-id-for-request req)
  (format "runtime-~a-~a-~a-~a-~a"
          (hash-ref req 'resolved-version)
          (variant->string (hash-ref req 'variant))
          (hash-ref req 'arch)
          (hash-ref req 'platform)
          (distribution->string (hash-ref req 'distribution))))

(define (runtime-current-id)
  (define current (rackup-runtime-current-link))
  (cond
    [(link-exists? current)
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (define target (resolve-path current))
       (and target (path-basename-string target)))]
    [else #f]))

(define (runtime-current-meta)
  (define id (runtime-current-id))
  (and id (read-rktd-file (rackup-runtime-meta-file id) #f)))

(define (runtime-cache-file installer-url)
  (build-path (rackup-download-cache-dir)
              (path-basename-string (string->path (car (reverse (string-split installer-url "/")))))))

(define (ensure-installer-cached! installer-url #:sha256 [expected-sha256 #f])
  (ensure-rackup-layout!)
  (require-checksummed-http-installer! installer-url expected-sha256)
  (define cache-path (runtime-cache-file installer-url))
  (unless (file-exists? cache-path)
    (displayln (format "Downloading hidden runtime installer: ~a" installer-url))
    (download-url->file installer-url cache-path)
    (when (regexp-match? #px"[.]sh$" (string-downcase (path->string* cache-path)))
      (file-or-directory-permissions cache-path #o755)))
  cache-path)

(define (run-linux-installer! installer-file install-root)
  (define installer (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (displayln (format "Installing hidden runtime into ~a" (path->string dest)))
  (system*/check 'hidden-runtime-installer
                 (shell-exe)
                 installer
                 "--create-dir"
                 "--in-place"
                 "--dest"
                 dest))

(define (tar-exe)
  (or (find-executable-path "tar") (string->path "/bin/tar")))

(define (run-tgz-installer! installer-file install-root)
  (define archive (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (displayln (format "Extracting hidden runtime archive into ~a" (path->string dest)))
  (make-directory* dest)
  (system*/check 'hidden-runtime-tgz-installer (tar-exe) "-xzf" archive "-C" dest))

(define (run-macos-dmg-installer! installer-file install-root)
  (define dmg (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (define mount-point (make-temporary-file "rackup-dmg-~a" 'directory))
  (displayln (format "Mounting DMG and extracting hidden runtime into ~a" (path->string dest)))
  (dynamic-wind
   (lambda ()
     (system*/check 'hdiutil-attach
                    "/usr/bin/hdiutil" "attach"
                    "-nobrowse" "-noverify" "-noautoopen"
                    "-mountpoint" (path->string* mount-point)
                    (path->string* dmg)))
   (lambda ()
     ;; Racket .dmg files are drag-and-drop installers containing:
     ;; - A directory like "Racket v9.1/" with bin/, lib/, share/ inside
     ;; - A symlink to /Applications (for drag-and-drop UX)
     ;; We must skip symlinks to avoid copying the system /Applications.
     (define top-dirs
       (for/list ([p (directory-list mount-point #:build? #t)]
                  #:when (and (directory-exists? p)
                              (not (link-exists? p))))
         p))
     (define src-dir
       (cond
         [(for/or ([d (in-list top-dirs)])
            (and (directory-exists? (build-path d "bin")) d))]
         [(directory-exists? (build-path mount-point "bin"))
          mount-point]
         [(= (length top-dirs) 1) (car top-dirs)]
         [else mount-point]))
     (copy-directory/files src-dir dest #:keep-modify-seconds? #t))
   (lambda ()
     (system* "/usr/bin/hdiutil" "detach" (path->string* mount-point) "-quiet")
     (when (directory-exists? mount-point)
       (delete-directory mount-point)))))

(define (installer-extension p)
  (define low (string-downcase (path->string* p)))
  (cond
    [(regexp-match? #px"[.]sh$" low) "sh"]
    [(regexp-match? #px"[.]tgz$" low) "tgz"]
    [(regexp-match? #px"[.]dmg$" low) "dmg"]
    [else #f]))

(define (detect-bin-dir install-root)
  (define p1 (build-path install-root "bin"))
  (define p2 (build-path install-root "racket" "bin"))
  (cond
    [(directory-exists? p1) p1]
    [(directory-exists? p2) p2]
    [else
     (rackup-error "could not find hidden runtime bin dir under ~a" (path->string* install-root))]))

(define (replace-link! link-path target-path)
  (when (link-exists? link-path)
    (delete-file link-path))
  (when (file-exists? link-path)
    (delete-file link-path))
  (when (directory-exists? link-path)
    (delete-directory/files link-path))
  (make-file-or-directory-link target-path link-path))

(define (write-runtime-meta! id
                             req
                             real-bin-dir
                             #:installed-by [installed-by 'runtime-command]
                             #:installer-url [installer-url #f]
                             #:installer-filename [installer-filename #f])
  (define meta
    (hash 'id
          id
          'role
          'internal-runtime
          'resolved-version
          (hash-ref req 'resolved-version)
          'variant
          (hash-ref req 'variant)
          'distribution
          (hash-ref req 'distribution)
          'arch
          (hash-ref req 'arch)
          'platform
          (hash-ref req 'platform)
          'installer-url
          installer-url
          'installer-filename
          installer-filename
          'install-root
          (path->string* (rackup-runtime-install-dir id))
          'bin-link
          (path->string* (rackup-runtime-bin-link id))
          'real-bin-dir
          (path->string* real-bin-dir)
          'installed-at
          (current-iso8601)
          'installed-by
          installed-by
          'source-spec
          "stable"))
  (write-rktd-file (rackup-runtime-meta-file id) meta)
  meta)

(define (probe-runtime-version+variant racket-exe)
  (define version-out
    (capture-hidden-runtime-output racket-exe "-e" "(display (version))"))
  (define variant-out
    (capture-hidden-runtime-output
     racket-exe
     "-e"
     "(display (let ([v (system-type 'vm)]) (if (symbol? v) (symbol->string v) (format \"~a\" v))))"))
  (values (and version-out (not (string-blank? version-out)) version-out)
          (and variant-out (not (string-blank? variant-out)) (string-downcase variant-out))))

(define (hidden-runtime-request)
  (with-handlers ([exn:fail? (lambda (_) (resolve-install-request "stable"
                                                                  #:variant 'bc
                                                                  #:distribution 'minimal))])
    (resolve-install-request "stable" #:variant 'cs #:distribution 'minimal)))

(define (request-with-version req version [variant #f])
  (define v* (or variant (hash-ref req 'variant)))
  (hash-set (hash-set req 'resolved-version version) 'variant v*))

(define (adopt-hidden-runtime! [quiet? #f])
  (define racket-exe (hidden-runtime-racket-path))
  (unless racket-exe
    (rackup-error "no hidden runtime to adopt"))
  (define current-id (runtime-current-id))
  (unless current-id
    (rackup-error "hidden runtime current link is missing"))
  (define meta-path (rackup-runtime-meta-file current-id))
  (if (file-exists? meta-path)
      (begin
        (unless quiet?
          (displayln (format "Hidden runtime installed: ~a" current-id)))
        current-id)
      (let-values ([(version* variant*) (probe-runtime-version+variant racket-exe)])
        (define req
          (hash 'resolved-version
                (or version* "stable")
                'variant
                (or (and variant* (string->symbol variant*)) 'cs)
                'distribution
                'minimal
                'arch
                (normalized-host-arch)
                'platform
                (host-platform-token)))
        (define real-bin
          (with-handlers ([exn:fail? (lambda (_) (build-path (rackup-runtime-current-link) "bin"))])
            (resolve-path (build-path (rackup-runtime-current-link) "bin"))))
        (write-runtime-meta! current-id
                             req
                             real-bin
                             #:installed-by 'bootstrap-script
                             #:installer-url #f
                             #:installer-filename #f)
        (unless quiet?
          (displayln (format "Adopted hidden runtime: ~a" current-id)))
        current-id)))

(define (rackup-core-source-path)
  (build-path (rackup-libexec-dir) "rackup-core.rkt"))

(define (compiled-dir-name? p)
  (define leaf (file-name-from-path p))
  (and leaf (equal? (path->string* leaf) "compiled")))

(define (rackup-source-file? p)
  (and (file-exists? p)
       (regexp-match? #px"[.]rkt$" (path->string* p))))

(define (rackup-source-paths)
  (sort
   (filter rackup-source-file?
           (find-files (lambda (p)
                         (cond
                           [(directory-exists? p) (not (compiled-dir-name? p))]
                           [else (rackup-source-file? p)]))
                       (rackup-libexec-dir)
                       #:follow-links? #f
                       #:skip-filtered-directory? #t))
   string<?
   #:key path->string*))

(define (run-quiet-program exe . args)
  (define out (open-output-nowhere))
  (define err (open-output-string))
  (define ok?
    (parameterize ([current-output-port out]
                   [current-error-port err])
      (apply system* exe args)))
  (values ok? (string-trim (get-output-string err))))

(define (demod-merged-zo-path)
  (build-path (rackup-libexec-dir) "compiled" "rackup-core_rkt_merged.zo"))

(define (precompile-rackup-sources!)
  (define racket-exe (hidden-runtime-racket-path))
  (when racket-exe
    (define merged-zo (demod-merged-zo-path))
    (if (file-exists? merged-zo)
        ;; Recompile demodularized machine-independent .zo to machine-dependent
        (let-values ([(ok? details)
                      (run-hidden-runtime/quiet
                       racket-exe
                       "-l" "raco" "demod" "-r"
                       (path->string* merged-zo))])
          (cond
            [ok?
             ;; Verify the recompiled .zo loads correctly
             (let-values ([(ok2? details2)
                           (run-hidden-runtime/quiet
                            racket-exe
                            (path->string* merged-zo)
                            "-e" "(void)")])
               (unless ok2?
                 (eprintf "rackup: warning: recompiled demod .zo failed smoke test\n")
                 (unless (string-blank? details2)
                   (eprintf "~a\n" details2))))]
            [else
             (eprintf "rackup: warning: failed to recompile demodularized .zo\n")
             (unless (string-blank? details)
               (eprintf "~a\n" details))]))
        ;; Fallback: compile from source
        (let ([sources (rackup-source-paths)])
          (when (pair? sources)
            (define compile-expression
              (string-join
               '("(begin"
                 "  (require compiler/cm racket/path)"
                 "  (for ([arg (in-vector (current-command-line-arguments))])"
                 "    (managed-compile-zo (path->complete-path (string->path arg)))))")
               " "))
            (let-values ([(ok? details)
                          (apply run-hidden-runtime/quiet
                                 racket-exe
                                 "-e"
                                 compile-expression
                                 (map path->string* sources))])
              (unless ok?
                (eprintf "rackup: warning: failed to precompile rackup sources via compiler/cm\n")
                (unless (string-blank? details)
                  (eprintf "~a\n" details)))))))))

(define (with-runtime-lock thunk)
  (ensure-rackup-layout!)
  (define lock-dir (rackup-runtime-lock-dir))
  (when (file-exists? lock-dir)
    (rackup-error "hidden runtime lock path exists and is not a directory: ~a"
                  (path->string* lock-dir)))
  (when (directory-exists? lock-dir)
    (rackup-error "hidden runtime is locked: ~a" (path->string* lock-dir)))
  (dynamic-wind (lambda () (make-directory lock-dir))
                thunk
                (lambda ()
                  (when (directory-exists? lock-dir)
                    (delete-directory lock-dir)))))

(define (install-hidden-runtime! [quiet? #f])
  (ensure-rackup-layout!)
  (cond
    [(hidden-runtime-present?) (adopt-hidden-runtime! quiet?)]
    [else
     (with-runtime-lock
      (lambda ()
        (if (hidden-runtime-present?)
            (adopt-hidden-runtime! quiet?)
            (let* ([req (hidden-runtime-request)]
                   [id (runtime-id-for-request req)]
                   [version-dir (rackup-runtime-version-dir id)]
                   [install-root (rackup-runtime-install-dir id)]
                   [bin-link (rackup-runtime-bin-link id)]
                   [installer-url (hash-ref req 'installer-url)]
                   [installer-file
                    (ensure-installer-cached! installer-url
                                              #:sha256 (hash-ref req 'installer-sha256 #f))]
                   [installer-ext (installer-extension installer-file)])
              (if (and (directory-exists? version-dir) (file-exists? (build-path bin-link "racket")))
                  (begin
                    (replace-link! (rackup-runtime-current-link) version-dir)
                    (adopt-hidden-runtime! quiet?))
                  (with-handlers ([exn:fail? (lambda (e)
                                               (when (directory-exists? version-dir)
                                                 (delete-directory/files version-dir))
                                               (raise e))])
                    (make-directory* version-dir)
                    (cond
                      [(equal? installer-ext "sh")
                       (run-linux-installer! installer-file install-root)]
                      [(equal? installer-ext "tgz")
                       (run-tgz-installer! installer-file install-root)]
                      [(equal? installer-ext "dmg")
                       (run-macos-dmg-installer! installer-file install-root)]
                      [else
                       (rackup-error "unsupported hidden runtime installer format: ~a"
                                     (or installer-ext "unknown"))])
                    (define real-bin (detect-bin-dir install-root))
                    (replace-link! bin-link real-bin)
                    (write-runtime-meta! id
                                         req
                                         real-bin
                                         #:installer-url installer-url
                                         #:installer-filename (hash-ref req 'installer-filename #f))
                    (replace-link! (rackup-runtime-current-link) version-dir)
                    (unless quiet?
                      (displayln (format "Installed hidden runtime: ~a" id)))
                    id))))))]))

(define (upgrade-hidden-runtime!)
  (ensure-rackup-layout!)
  (unless (hidden-runtime-present?)
    (install-hidden-runtime!))
  (define current-meta
    (or (runtime-current-meta)
        (begin
          (adopt-hidden-runtime! #t)
          (runtime-current-meta))))
  (define current-version (and current-meta (hash-ref current-meta 'resolved-version #f)))
  (define req (hidden-runtime-request))
  (define latest-version (hash-ref req 'resolved-version))
  (if (and (string? current-version) (>= (cmp-versions current-version latest-version) 0))
      (begin
        (displayln (format "Hidden runtime already up to date: ~a"
                           (or (hash-ref current-meta 'id #f) (runtime-current-id))))
        (or (hash-ref current-meta 'id #f) (runtime-current-id)))
      (install-hidden-runtime!)))

(define (hidden-runtime-status)
  (define racket-exe (hidden-runtime-racket-path))
  (define id (runtime-current-id))
  (define meta (runtime-current-meta))
  (hash 'present?
        (and racket-exe #t)
        'racket-path
        (and racket-exe (path->string* racket-exe))
        'id
        id
        'meta
        meta))

(define (cmd-runtime rest)
  (match rest
    [(list "status")
     (define s (hidden-runtime-status))
     (if (hash-ref s 'present? #f)
         (let ([m (hash-ref s 'meta #f)])
           (printf "present: yes\n")
           (printf "id: ~a\n" (or (hash-ref s 'id #f) ""))
           (printf "racket: ~a\n" (or (hash-ref s 'racket-path #f) ""))
           (when (hash? m)
             (printf "version: ~a\n" (hash-ref m 'resolved-version ""))
             (printf "variant: ~a\n" (hash-ref m 'variant ""))
             (printf "distribution: ~a\n" (hash-ref m 'distribution ""))
             (printf "installed-at: ~a\n" (hash-ref m 'installed-at ""))))
         (displayln "present: no"))]
    [(list "install")
     (install-hidden-runtime!)
     (precompile-rackup-sources!)]
    [(list "upgrade")
     (upgrade-hidden-runtime!)
     (precompile-rackup-sources!)]
    [_ (rackup-error "usage: rackup runtime status|install|upgrade")]))
