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
         "runtime.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt"
         "versioning.rkt")

(provide install-toolchain!
         link-toolchain!
         remove-toolchain!
         enumerate-toolchain-executables
         doctor-report)

(define (install-color-enabled?)
  (and (terminal-port? (current-output-port)) (not (getenv "NO_COLOR"))))

(define (ansi-color code s)
  (if (install-color-enabled?)
      (string-append "\u001b[" code "m" s "\u001b[0m")
      s))

(define (install-info fmt . args)
  (displayln (ansi-color "34" (apply format fmt args))))

(define (install-ok fmt . args)
  (displayln (ansi-color "32" (apply format fmt args))))

(define (install-warn fmt . args)
  (eprintf "~a\n" (ansi-color "33" (apply format fmt args))))

(define (truncate-lines s [max-lines 80])
  (define lines (string-split s "\n"))
  (if (<= (length lines) max-lines)
      s
      (string-append (string-join (take lines max-lines) "\n")
                     "\n..."
                     (format "\n[truncated to first ~a lines]" max-lines))))

(define (installer-cache-file installer-url)
  (build-path (rackup-download-cache-dir)
              (path-basename-string (string->path (car (reverse (string-split installer-url "/")))))))

(define (ensure-installer-cached! installer-url #:no-cache? [no-cache? #f])
  (ensure-rackup-layout!)
  (define cache-path (installer-cache-file installer-url))
  (when (or no-cache? (not (file-exists? cache-path)))
    (install-info "Downloading installer: ~a" installer-url)
    (download-url->file installer-url cache-path)
    (file-or-directory-permissions cache-path #o755))
  cache-path)

(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))

(define (run-linux-installer! installer-file install-root)
  ;; Use the same dest/in-place flow as setup-racket for Linux.
  (define installer (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (install-info "Installing into ~a" (path->string dest))
  (define combined (open-output-string))
  (define ok?
    (parameterize ([current-output-port combined]
                   [current-error-port combined])
      (system* (shell-exe) installer "--create-dir" "--in-place" "--dest" dest)))
  (unless ok?
    (define details (string-trim (get-output-string combined)))
    (install-warn "Installer script failed.")
    (unless (string-blank? details)
      (eprintf "%s\n" (truncate-lines details)))
    (rackup-error "linux-installer failed: ~a --create-dir --in-place --dest ~a"
                  (path->string* installer)
                  (path->string* dest))))

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
  (sort (for/list ([p (in-list (directory-list real-bin-dir #:build? #t))]
                   #:when (and (file-exists? p) (file-executable?/safe p)))
          (path-basename-string p))
        string<?))

(define (make-bin-link! id real-bin-dir)
  (define link (rackup-toolchain-bin-link id))
  (cond
    [(link-exists? link) (delete-file link)]
    [(file-exists? link) (delete-file link)]
    [(directory-exists? link) (delete-directory/files link)])
  (make-file-or-directory-link real-bin-dir link)
  link)

(define (link-executable-into-dir! dir src [name #f])
  (define dst-name (or name (path-basename-string src)))
  (define dst (build-path dir dst-name))
  (cond
    [(link-exists? dst) (delete-file dst)]
    [(file-exists? dst) (delete-file dst)]
    [(directory-exists? dst) (delete-directory/files dst)])
  (make-file-or-directory-link src dst)
  dst)

(define (make-bin-overlay! id real-bin-dir extra-exes)
  (define overlay (rackup-toolchain-bin-link id))
  (cond
    [(link-exists? overlay) (delete-file overlay)]
    [(file-exists? overlay) (delete-file overlay)]
    [(directory-exists? overlay) (delete-directory/files overlay)])
  (make-directory* overlay)
  (for ([p (in-list (directory-list real-bin-dir #:build? #t))]
        #:when (and (file-exists? p) (file-executable?/safe p)))
    (link-executable-into-dir! overlay p))
  (for ([kv (in-list extra-exes)])
    (define name (car kv))
    (define src (cdr kv))
    (define dst (build-path overlay name))
    ;; Prefer the main PLTHOME bin entry when a name already exists there.
    (unless (or (file-exists? dst) (link-exists? dst))
      (link-executable-into-dir! overlay src name)))
  overlay)

(define (write-toolchain-env-file! id env-vars)
  (define p (rackup-toolchain-env-file id))
  (define body
    (string-append "#!/usr/bin/env bash\n"
                   "# rackup managed toolchain environment\n"
                   (apply string-append
                          (for/list ([kv (in-list env-vars)])
                            (format "export ~a=~a\n" (car kv) (sh-single-quote (cdr kv)))))))
  (write-string-file p body)
  (file-or-directory-permissions p #o644)
  p)

(define (delete-toolchain-env-file! id)
  (define p (rackup-toolchain-env-file id))
  (when (file-exists? p)
    (delete-file p)))

(define (path-complete-string p)
  (path->string* (path->complete-path p)))

(define (path-join/colon paths)
  (string-join (map path->string* paths) ":"))

(define (maybe-parent p)
  (and p (path-only p)))

(define (path-contains? p rx)
  (regexp-match? rx (path->string* p)))

(define chez-extra-names '("scheme" "petite"))

(define (find-local-chez-extra-executables layout)
  (define source-root* (hash-ref layout 'source-root #f))
  (if (not source-root*)
      null
      (let ()
        (define source-root (string->path source-root*))
        (define search-roots
          (filter directory-exists?
                  (list (build-path source-root "racket" "src" "build" "cs" "c" "ChezScheme")
                        (build-path source-root "racket" "src" "ChezScheme"))))
        (define matches
          (remove-duplicates (append* (for/list ([root (in-list search-roots)])
                                        (find-files (lambda (p)
                                                      (and (file-exists? p)
                                                           (member (path-basename-string p)
                                                                   chez-extra-names)
                                                           (file-executable?/safe p)))
                                                    root)))
                             equal?))
        (if (null? matches)
            null
            (let ()
              (define dirs->executables (make-hash))
              (for ([p (in-list matches)])
                (define dir (path-only p))
                (when dir
                  (define names->paths (hash-ref dirs->executables dir #f))
                  (unless names->paths
                    (set! names->paths (make-hash))
                    (hash-set! dirs->executables dir names->paths))
                  (hash-set! names->paths (path-basename-string p) p)))
              (let* ([scored (for/list ([dir (in-list (hash-keys dirs->executables))])
                               (define names->paths (hash-ref dirs->executables dir))
                               (define both?
                                 (and (hash-has-key? names->paths "scheme")
                                      (hash-has-key? names->paths "petite")))
                               (define score
                                 (+ (if both? 200 0)
                                    (if (path-contains? dir #rx"/src/build/") 100 0)
                                    (if (path-contains? dir #rx"/ChezScheme/") 40 0)
                                    (if (path-contains? dir #rx"/bin/") 20 0)))
                               (list dir names->paths score (path->string* dir)))]
                     [best (car (sort scored
                                      (lambda (a b)
                                        (define sa (list-ref a 2))
                                        (define sb (list-ref b 2))
                                        (define pa (list-ref a 3))
                                        (define pb (list-ref b 3))
                                        (or (> sa sb) (and (= sa sb) (string<? pa pb))))))]
                     [names->paths (list-ref best 1)])
                (for/list ([name (in-list chez-extra-names)]
                           #:when (hash-has-key? names->paths name))
                  (cons name (hash-ref names->paths name)))))))))

(define (detect-local-source-layout path-input)
  (define input-path
    (path->complete-path (expand-user-path (if (path? path-input)
                                               path-input
                                               (string->path path-input)))))
  (define (dir? . parts)
    (directory-exists? (apply build-path input-path parts)))
  (cond
    [(and (dir? "racket") (dir? "racket" "bin") (dir? "racket" "collects"))
     (define source-root input-path)
     (define plthome (build-path source-root "racket"))
     (define bin-dir (build-path plthome "bin"))
     (define collects (build-path plthome "collects"))
     (define pkgs (build-path source-root "pkgs"))
     (hash 'input-path
           (path-complete-string input-path)
           'source-root
           (path-complete-string source-root)
           'plthome
           (path-complete-string plthome)
           'bin-dir
           (path-complete-string bin-dir)
           'collects-dir
           (path-complete-string collects)
           'pkgs-dir
           (and (directory-exists? pkgs) (path-complete-string pkgs)))]
    [else
     (define maybe-bin
       (cond
         [(and (directory-exists? input-path)
               (directory-exists? (build-path input-path "collects"))
               (directory-exists? (build-path input-path "bin")))
          (build-path input-path "bin")]
         [(and (directory-exists? input-path)
               (equal? (path-basename-string input-path) "bin")
               (directory-exists? (build-path (or (maybe-parent input-path) input-path) "collects")))
          input-path]
         [else #f]))
     (unless maybe-bin
       (rackup-error
        (string-append
         "could not detect an in-place source build layout at ~a\n"
         "Expected either <root>/racket/bin + <root>/racket/collects or <plthome>/bin + <plthome>/collects")
        (path->string* input-path)))
     (define plthome (or (maybe-parent maybe-bin) input-path))
     (define maybe-root (maybe-parent plthome))
     (define pkgs (and maybe-root (build-path maybe-root "pkgs")))
     (hash 'input-path
           (path-complete-string input-path)
           'source-root
           (and maybe-root (directory-exists? pkgs) (path-complete-string maybe-root))
           'plthome
           (path-complete-string plthome)
           'bin-dir
           (path-complete-string maybe-bin)
           'collects-dir
           (path-complete-string (build-path plthome "collects"))
           'pkgs-dir
           (and (directory-exists? pkgs) (path-complete-string pkgs)))]))

(define (local-layout-env-vars layout)
  (define collects-dir (hash-ref layout 'collects-dir))
  (define pkgs-dir (hash-ref layout 'pkgs-dir #f))
  (define collects-path
    (if pkgs-dir
        (path-join/colon (list collects-dir pkgs-dir))
        (path-join/colon (list collects-dir))))
  (list (cons "PLTHOME" (hash-ref layout 'plthome)) (cons "PLTCOLLECTS" collects-path)))

(define (capture-program-output #:env [env-vars null] exe . args)
  (define old-vals
    (for/list ([kv (in-list env-vars)])
      (cons (car kv) (getenv (car kv)))))
  (define out (open-output-string))
  (define err (open-output-string))
  (dynamic-wind (lambda ()
                  (for ([kv (in-list env-vars)])
                    (putenv (car kv) (cdr kv))))
                (lambda ()
                  (parameterize ([current-output-port out]
                                 [current-error-port err])
                    (if (apply system* exe args)
                        (string-trim (get-output-string out))
                        #f)))
                (lambda ()
                  (for ([kv (in-list old-vals)])
                    (define k (car kv))
                    (define v (cdr kv))
                    (if v
                        (putenv k v)
                        (putenv k ""))))))

(define (probe-local-racket-version+variant bin-dir env-vars)
  (define racket-exe (build-path (string->path bin-dir) "racket"))
  (define version-out (capture-program-output #:env env-vars racket-exe "-e" "(display (version))"))
  (define variant-out
    (capture-program-output
     #:env env-vars
     racket-exe
     "-e"
     "(display (let ([v (system-type 'vm)]) (if (symbol? v) (symbol->string v) (format \"~a\" v))))"))
  (values (and version-out (not (string-blank? version-out)) version-out)
          (and variant-out (not (string-blank? variant-out)) (string-downcase variant-out))))

(define (toolchain-meta request id real-bin-dir executables)
  (hash 'id
        id
        'kind
        (hash-ref request 'kind)
        'requested-spec
        (hash-ref request 'requested-spec)
        'resolved-version
        (hash-ref request 'resolved-version)
        'variant
        (hash-ref request 'variant)
        'distribution
        (hash-ref request 'distribution)
        'arch
        (hash-ref request 'arch)
        'platform
        (hash-ref request 'platform)
        'snapshot-site
        (hash-ref request 'snapshot-site #f)
        'snapshot-stamp
        (hash-ref request 'snapshot-stamp #f)
        'installer-url
        (hash-ref request 'installer-url)
        'installer-filename
        (hash-ref request 'installer-filename)
        'install-root
        (path->string* (rackup-toolchain-install-dir id))
        'bin-link
        (path->string* (rackup-toolchain-bin-link id))
        'real-bin-dir
        (path->string* real-bin-dir)
        'executables
        executables
        'installed-at
        (current-iso8601)))

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
      ['()
       (hash 'variant
             variant
             'distribution
             distribution
             'snapshot-site
             snapshot-site
             'arch
             arch
             'set-default?
             set-default?
             'force?
             force?
             'no-cache?
             no-cache?)]
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
      [(list flag _ ...) (rackup-error "unknown install flag: ~a" flag)])))

(define (parse-link-options opts)
  (define set-default? #f)
  (define force? #f)
  (let loop ([rest opts])
    (match rest
      ['() (hash 'set-default? set-default? 'force? force?)]
      [(list "--set-default" more ...)
       (set! set-default? #t)
       (loop more)]
      [(list "--force" more ...)
       (set! force? #t)
       (loop more)]
      [(list flag _ ...) (rackup-error "unknown link flag: ~a" flag)])))

(define (local-toolchain-id name)
  (string-append "local-" (sanitize-id-part name)))

(define (local-toolchain-meta id name layout real-bin-dir executables)
  (define env-vars (local-layout-env-vars layout))
  (define-values (version* variant*)
    (probe-local-racket-version+variant (path->string* real-bin-dir) env-vars))
  (define platform-raw (system-type 'os))
  (define platform
    (if (symbol? platform-raw)
        (symbol->string platform-raw)
        (format "~a" platform-raw)))
  (hash 'id
        id
        'kind
        'local
        'requested-spec
        name
        'resolved-version
        (or version* "local")
        'variant
        (or (and variant* (string->symbol variant*)) 'unknown)
        'distribution
        'in-place
        'arch
        (normalized-host-arch)
        'platform
        platform
        'snapshot-site
        #f
        'snapshot-stamp
        #f
        'installer-url
        #f
        'installer-filename
        #f
        'source-path
        (hash-ref layout 'input-path)
        'source-root
        (hash-ref layout 'source-root #f)
        'plthome
        (hash-ref layout 'plthome)
        'pltcollects
        (cdr (assoc "PLTCOLLECTS" env-vars))
        'install-root
        #f
        'bin-link
        (path->string* (rackup-toolchain-bin-link id))
        'real-bin-dir
        (path->string* real-bin-dir)
        'env-vars
        (for/list ([kv (in-list env-vars)])
          (list (car kv) (cdr kv)))
        'executables
        executables
        'installed-at
        (current-iso8601)))

(define (link-toolchain! name local-path opts)
  (ensure-rackup-layout!)
  (ensure-index!)
  (when (or (not (string? name)) (string-blank? name))
    (rackup-error "toolchain link name must be non-empty"))
  (define parsed-opts (parse-link-options opts))
  (define id (local-toolchain-id name))
  (define tc-dir (rackup-toolchain-dir id))
  (define layout (detect-local-source-layout local-path))
  (define real-bin-dir (string->path (hash-ref layout 'bin-dir)))
  (define racket-exe (build-path real-bin-dir "racket"))
  (unless (file-executable?/safe racket-exe)
    (rackup-error "linked toolchain does not contain an executable racket binary at ~a"
                  (path->string* racket-exe)))
  (cond
    [(directory-exists? tc-dir)
     (if (hash-ref parsed-opts 'force? #f)
         (begin
           (delete-directory/files tc-dir)
           (link-toolchain! name local-path opts))
         (begin
           (rackup-error "toolchain already exists: ~a (use --force to relink)" id)))]
    [else
     (with-handlers ([exn:fail? (lambda (e)
                                  (when (directory-exists? tc-dir)
                                    (delete-directory/files tc-dir))
                                  (raise e))])
       (make-directory* tc-dir)
       (define extra-exes (find-local-chez-extra-executables layout))
       (make-bin-overlay! id real-bin-dir extra-exes)
       (write-toolchain-env-file! id (local-layout-env-vars layout))
       (ensure-toolchain-addon-dir! id)
       (define executables (enumerate-toolchain-executables (rackup-toolchain-bin-link id)))
       (define meta (local-toolchain-meta id name layout real-bin-dir executables))
       (register-toolchain! id meta)
       (when (hash-ref parsed-opts 'set-default? #f)
         (set-default-toolchain! id))
       (reshim!)
       (displayln (format "Linked ~a => ~a" id (hash-ref layout 'plthome)))
       id)]))

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
           (install-ok "Already installed: ~a" id)
           (when (hash-ref parsed-opts 'set-default? #f)
             (set-default-toolchain! id))
           (reshim!)
           id))]
    [else
     (define installer-path
       (ensure-installer-cached! (hash-ref request 'installer-url)
                                 #:no-cache? (hash-ref parsed-opts 'no-cache? #f)))
     (with-handlers ([exn:fail? (lambda (e)
                                  (when (directory-exists? tc-dir)
                                    (delete-directory/files tc-dir))
                                  (raise e))])
       (make-directory* tc-dir)
       (run-linux-installer! installer-path install-root)
       (define real-bin-dir (detect-bin-dir install-root))
       (make-bin-link! id real-bin-dir)
       (delete-toolchain-env-file! id)
       (ensure-toolchain-addon-dir! id)
       (define executables (enumerate-toolchain-executables real-bin-dir))
       (define meta (toolchain-meta request id real-bin-dir executables))
       (register-toolchain! id meta)
       (when (hash-ref parsed-opts 'set-default? #f)
         (set-default-toolchain! id))
       (reshim!)
       (install-ok "Installed ~a" id)
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
  (define runtime-status (hidden-runtime-status))
  (define runtime-meta (hash-ref runtime-status 'meta #f))
  (define wrapper-runtime-source
    (cond
      [(hash-ref runtime-status 'present? #f) 'internal]
      [(find-executable-path "racket") 'system]
      [else 'none]))
  (define findings
    (list (cons 'home (path->string* (rackup-home)))
          (cons 'bin (path->string* (rackup-bin-entry)))
          (cons 'shim-dispatcher (path->string* (rackup-shim-dispatcher)))
          (cons 'shims-dir (path->string* (rackup-shims-dir)))
          (cons 'installed-count (length ids))
          (cons 'default default-id)
          (cons 'runtime-present (hash-ref runtime-status 'present? #f))
          (cons 'runtime-id (hash-ref runtime-status 'id #f))
          (cons 'runtime-version
                (and (hash? runtime-meta) (hash-ref runtime-meta 'resolved-version #f)))
          (cons 'runtime-racket (hash-ref runtime-status 'racket-path #f))
          (cons 'wrapper-runtime-source wrapper-runtime-source)))
  (for ([kv findings])
    (printf "~a: ~a\n" (car kv) (cdr kv)))
  (for ([id ids])
    (define m (read-toolchain-meta id))
    (printf "toolchain ~a => ~a (~a, ~a)\n"
            id
            (hash-ref m 'resolved-version #f)
            (hash-ref m 'variant #f)
            (hash-ref m 'distribution #f))))
