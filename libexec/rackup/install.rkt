#lang racket/base

(require racket/cmdline
         racket/file
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "legacy.rkt"
         "paths.rkt"
         "remote.rkt"
         "rktd-io.rkt"
         "runtime.rkt"
         "shims.rkt"
         "state.rkt"
         "state-lock.rkt"
         "util.rkt"
         "versioning.rkt")

(provide install-toolchain!
         link-toolchain!
         remove-toolchain!
         upgrade-toolchain!
         run-linux-installer!
         run-tgz-installer!
         run-macos-dmg-installer!
         enumerate-toolchain-executables
         doctor-report
         commit-state-change!)

;; Acquire the state lock, run body, then reshim to keep shims
;; consistent with the new state.
(define-syntax-rule (commit-state-change! body ...)
  (with-state-lock
   body ...
   (reshim!)))

(define current-install-verbosity (make-parameter 'normal))

(define (install-verbosity)
  (current-install-verbosity))

(define (install-quiet?)
  (eq? (install-verbosity) 'quiet))

(define (install-verbose?)
  (eq? (install-verbosity) 'verbose))

(define (ansi-color code s)
  (ansi code s))

(define (install-info fmt . args)
  (unless (install-quiet?)
    (displayln (ansi-color "34" (apply format fmt args)))))

(define (install-ok fmt . args)
  (displayln (ansi-color "32" (apply format fmt args))))

(define (install-warn fmt . args)
  (eprintf "~a\n" (ansi-color "33" (apply format fmt args))))

(define (install-verbose fmt . args)
  (when (install-verbose?)
    (displayln (ansi-color "34" (apply format fmt args)))))

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

(define (ensure-installer-cached! installer-url
                                  #:no-cache? [no-cache? #f]
                                  #:sha256 [expected-sha256 #f]
                                  #:sha1 [expected-sha1 #f])
  (ensure-rackup-layout!)
  (require-checksummed-http-installer! installer-url expected-sha256)
  (define cache-path (installer-cache-file installer-url))
  (when (and (file-exists? cache-path) (or expected-sha256 expected-sha1))
    (with-handlers ([exn:fail? (lambda (_)
                                 (delete-file cache-path))])
      (verify-installer-checksum! cache-path #:sha256 expected-sha256 #:sha1 expected-sha1)))
  (when (or no-cache? (not (file-exists? cache-path)))
    (if (install-verbose?)
        (install-verbose "Downloading installer: ~a" installer-url)
        (install-info "Downloading installer..."))
    (download-url->file installer-url cache-path)
    (verify-installer-checksum! cache-path #:sha256 expected-sha256 #:sha1 expected-sha1)
    (file-or-directory-permissions cache-path #o755))
  cache-path)

(define (run-linux-installer! installer-file
                              install-root
                              #:legacy-install-kind [legacy-install-kind #f])
  ;; Use the same dest/in-place flow as setup-racket for Linux.
  (define installer (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (install-verbose "Installing into ~a" (path->string dest))
  (define log-file (make-temporary-file "rackup-installer-~a.log"))
  (define (delete-log!)
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (delete-file log-file)))
  (define detected-shell-mode
    (and (regexp-match? #px"[.]sh$" (string-downcase (path->string* installer)))
         (detect-shell-installer-mode installer)))
  (define legacy-kind
    (cond
      [legacy-install-kind legacy-install-kind]
      [(member detected-shell-mode '(shell-basic shell-unixstyle)) detected-shell-mode]
      [(legacy-interactive-linux-installer? installer) 'shell-unixstyle]
      [else #f]))
  (define ok?
    (call-with-output-file*
     log-file
     #:exists 'truncate/replace
     (lambda (combined)
       (define (run-modern)
         (system* (shell-exe) installer "--create-dir" "--in-place" "--dest" dest))
       (define (run-legacy)
         (define scripted-in (open-input-string (legacy-installer-input-script dest legacy-kind)))
         (dynamic-wind void
                       (lambda ()
                         (parameterize ([current-input-port scripted-in])
                           (system* (shell-exe) installer)))
                       (lambda () (close-input-port scripted-in))))
       (parameterize ([current-output-port combined]
                      [current-error-port combined])
         (if legacy-kind
             (run-legacy)
             (run-modern))))))
  (unless ok?
    (define details
      (with-handlers ([exn:fail? (lambda (_) "")])
        (call-with-input-file* log-file (lambda (in) (string-trim (port->string in))))))
    (install-warn "Installer script failed.")
    (unless (string-blank? details)
      (eprintf "~a\n" (truncate-lines details)))
    (delete-log!)
    (rackup-error "installer failed: ~a (~a)"
                  (path->string* installer)
                  (if legacy-kind
                      "legacy interactive mode"
                      (format "--create-dir --in-place --dest ~a" (path->string* dest)))))
  (delete-log!))

(define (tar-exe)
  (or (find-executable-path "tar") (string->path "/bin/tar")))

(define (run-tgz-installer! installer-file install-root)
  (define archive (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (install-verbose "Extracting archive into ~a" (path->string dest))
  (make-directory* dest)
  (system*/check 'linux-tgz-installer (tar-exe) "-xzf" archive "-C" dest))

(define (run-macos-dmg-installer! installer-file install-root)
  (define dmg (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (define mount-point (make-temporary-file "rackup-dmg-~a" 'directory))
  (install-verbose "Mounting DMG and extracting into ~a" (path->string dest))
  (dynamic-wind
   (lambda ()
     (system*/check 'hdiutil-attach
                    "/usr/bin/hdiutil" "attach"
                    "-nobrowse" "-noverify" "-noautoopen" "-quiet"
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
     (make-directory* dest)
     (system*/check 'ditto "/usr/bin/ditto" (path->string* src-dir) (path->string* dest)))
   (lambda ()
     (system* "/usr/bin/hdiutil" "detach" (path->string* mount-point) "-quiet")
     (when (directory-exists? mount-point)
       (delete-directory mount-point)))))

(define (installer-filename-extension s)
  (define low (string-downcase s))
  (cond
    [(regexp-match? #px"[.]sh$" low) "sh"]
    [(regexp-match? #px"[.]tgz$" low) "tgz"]
    [(regexp-match? #px"[.]dmg$" low) "dmg"]
    [else #f]))

(define (detect-bin-dir install-root)
  (define p1 (build-path install-root "bin"))
  (define p2 (build-path install-root "racket" "bin"))
  (define p3 (build-path install-root "plt" "bin"))
  (cond
    [(directory-exists? p1) p1]
    [(directory-exists? p2) p2]
    [(directory-exists? p3) p3]
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

(define (local-chez-wrapper-targets layout)
  (define plthome (string->path (hash-ref layout 'plthome)))
  ;; Boot files are at lib/racket/ in installed-prefix layouts but
  ;; at lib/ in in-place source builds.
  (define (find-boot name)
    (define installed (build-path plthome "lib" "racket" name))
    (define in-place (build-path plthome "lib" name))
    (cond [(file-exists? installed) installed]
          [(file-exists? in-place) in-place]
          [else #f]))
  (define petite-boot (find-boot "petite.boot"))
  (define scheme-boot (find-boot "scheme.boot"))
  (if petite-boot
      (append (list (cons "petite" (list "-B" (path->string* petite-boot))))
              (if scheme-boot
                  (list (cons "scheme"
                              (list "-B"
                                    (path->string* petite-boot)
                                    "-B"
                                    (path->string* scheme-boot))))
                  null))
      null))

(define (write-exec-wrapper! dest exe args)
  (define body
    (string-append
     "#!/usr/bin/env bash\n"
     "set -euo pipefail\n"
     "exec "
     (sh-single-quote (path->string* exe))
     (apply string-append
            (for/list ([arg (in-list args)])
              (string-append " " (sh-single-quote arg))))
     " \"$@\"\n"))
  (write-string-file dest body)
  (file-or-directory-permissions dest #o755))

(define (maybe-wrap-local-chez-extra-executables! id extra-exes layout)
  (define overlay (rackup-toolchain-bin-link id))
  (define wrapper-targets (local-chez-wrapper-targets layout))
  (for ([wrapper (in-list wrapper-targets)])
    (define name (car wrapper))
    (define boot-args (cdr wrapper))
    (define src (assoc name extra-exes))
    (when src
      (define dest (build-path overlay name))
      (when (or (link-exists? dest) (file-exists? dest))
        (delete-file dest))
      (write-exec-wrapper! dest (cdr src) boot-args))))

(define (write-toolchain-env-file! id env-vars)
  (define p (rackup-toolchain-env-file id))
  (define body
    (string-append "#!/usr/bin/env bash\n"
                   "# rackup managed toolchain environment\n"
                   (apply string-append
                          (for/list ([kv (in-list env-vars)])
                            (env-var-export-line (car kv) (cdr kv))))))
  (write-string-file p body)
  (file-or-directory-permissions p #o644)
  p)

(define (delete-toolchain-env-file! id)
  (define p (rackup-toolchain-env-file id))
  (when (file-exists? p)
    (delete-file p)))

(define (path-complete-string p)
  (path->string* (path->complete-path p)))

(define (maybe-parent p)
  (and p (path-only p)))

(define (path-contains? p rx)
  (regexp-match? rx (path->string* p)))

(define linux-i386-loader-candidates
  '("/lib/ld-linux.so.2"
    "/lib32/ld-linux.so.2"
    "/lib/i386-linux-gnu/ld-linux.so.2"
    "/lib/i686-linux-gnu/ld-linux.so.2"
    "/usr/i386-linux-gnu/lib/ld-linux.so.2"))

(define (linux-i386-loader-present?)
  (for/or ([loader (in-list linux-i386-loader-candidates)])
    (file-exists? (string->path loader))))

(define chez-extra-names '("scheme" "petite"))

(define (find-local-chez-extra-executables layout)
  (define base-paths
    (filter values
            (for/list ([key (in-list '(source-root input-path plthome))])
              (define v (hash-ref layout key #f))
              (and v (string->path v)))))
  (define search-roots
    (remove-duplicates
     (filter directory-exists?
             (append
              base-paths
              (for*/list ([base (in-list base-paths)]
                          [suffix (in-list '(("bin")
                                             ("src")
                                             ("src" "build")
                                             ("src" "build" "cs" "c" "ChezScheme")
                                             ("src" "ChezScheme")
                                             ("racket" "src")
                                             ("racket" "src" "build")
                                             ("racket" "src" "build" "cs" "c" "ChezScheme")
                                             ("racket" "src" "ChezScheme")))])
                (apply build-path base suffix))))
     equal?))
  (define matches
    (remove-duplicates
     (append*
      (for/list ([root (in-list search-roots)])
        (find-files (lambda (p)
                      (and (file-exists? p)
                           (member (path-basename-string p) chez-extra-names)
                           (not (path-contains? p #rx"/ChezScheme/pb/"))
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
            (cons name (hash-ref names->paths name)))))))

(define (detect-local-source-layout path-input)
  (define input-path
    (path->complete-path (expand-user-path (if (path? path-input)
                                               path-input
                                               (string->path path-input)))))
  (define (dir? . parts)
    (directory-exists? (apply build-path input-path parts)))
  (define (installed-prefix-layout root)
    (define plthome root)
    (define maybe-root (maybe-parent plthome))
    (define pkgs (build-path plthome "share" "racket" "pkgs"))
    (hash 'input-path
          (path-complete-string input-path)
          'source-root
          #f
          'plthome
          (path-complete-string plthome)
          'bin-dir
          (path-complete-string (build-path plthome "bin"))
          'collects-dir
          (path-complete-string (build-path plthome "share" "racket" "collects"))
          'pkgs-dir
          (and (directory-exists? pkgs) (path-complete-string pkgs))))
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
    [(and (dir? "racket") (dir? "racket" "bin") (dir? "racket" "share" "racket" "collects"))
     (installed-prefix-layout (build-path input-path "racket"))]
    [else
     (define maybe-bin
       (cond
         [(and (directory-exists? input-path)
               (directory-exists? (build-path input-path "collects"))
               (directory-exists? (build-path input-path "bin")))
          (build-path input-path "bin")]
         [(and (directory-exists? input-path)
               (directory-exists? (build-path input-path "share" "racket" "collects"))
               (directory-exists? (build-path input-path "bin")))
          (build-path input-path "bin")]
         [(and (directory-exists? input-path)
               (equal? (path-basename-string input-path) "bin")
               (directory-exists? (build-path (or (maybe-parent input-path) input-path) "collects")))
          input-path]
         [(and (directory-exists? input-path)
               (equal? (path-basename-string input-path) "bin")
               (directory-exists?
                (build-path (or (maybe-parent input-path) input-path) "share" "racket" "collects")))
          input-path]
         [else #f]))
     (unless maybe-bin
       (rackup-error
        (string-append
         "could not detect an in-place source build layout at ~a\n"
         "Expected one of:\n"
         "  <root>/racket/bin + <root>/racket/collects\n"
         "  <root>/racket/bin + <root>/racket/share/racket/collects\n"
         "  <plthome>/bin + <plthome>/collects\n"
         "  <plthome>/bin + <plthome>/share/racket/collects")
        (path->string* input-path)))
     (define plthome (or (maybe-parent maybe-bin) input-path))
     (cond
       [(directory-exists? (build-path plthome "share" "racket" "collects"))
        (installed-prefix-layout plthome)]
       [else
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
              (and (directory-exists? pkgs) (path-complete-string pkgs)))])]))

(define (local-layout-env-vars layout [addon-dir #f] [version #f] [variant #f] [local-name #f])
  ;; If the probe gave us an addon-dir, use it.  Otherwise leave
  ;; PLTADDONDIR unset and let the shim dispatcher fall back to its
  ;; default (which is per-toolchain under ~/.rackup/addons/).  We
  ;; intentionally do NOT fall back to <source-root>/add-on: that
  ;; tends to be wrong for users whose packages live in their native
  ;; addon-dir (e.g., ~/.local/share/racket/<install-name>/), and the
  ;; old behavior caused silent breakage of `raco pkg` operations.
  (define addon-entry
    (if (and (string? addon-dir) (not (string-blank? addon-dir)))
        (list (cons "PLTADDONDIR" addon-dir))
        null))
  (define bin-dir-str (hash-ref layout 'bin-dir #f))
  (define existing-roots
    (if bin-dir-str
        (read-toolchain-compiled-file-roots (string->path bin-dir-str))
        '(same)))
  (define compiled-roots-entry
    (cond
      [(compiled-roots-value version variant existing-roots local-name)
       =>
       (lambda (v) (list (cons "PLTCOMPILEDROOTS" v)))]
      [else null]))
  (append addon-entry compiled-roots-entry))

;; Old PLT Scheme installations (version <= 4.x) have a shell wrapper at
;; plt/bin/mzscheme that uses $PLTHOME to locate the real binary under
;; plt/.bin/<archsys>/. Set PLTHOME for these so the wrapper works.
(define (installed-toolchain-env-vars real-bin-dir [request #f])
  (define plthome (maybe-parent real-bin-dir))
  (define-values (plthome-base plthome-leaf _plthome-dir?)
    (if plthome
        (split-path plthome)
        (values #f #f #f)))
  (define plthome-name
    (and (path? plthome-leaf) (path->string plthome-leaf)))
  (define plthome-normalized
    (and plthome-base (path? plthome-leaf) (build-path plthome-base plthome-leaf)))
  (define plthome-entry
    (cond
      [(and plthome-normalized (equal? plthome-name "plt"))
       (list (cons "PLTHOME" (path->string* plthome-normalized)))]
      [else null]))
  (define compiled-roots-entry
    (cond
      [(and (hash? request)
            (compiled-roots-value (hash-ref request 'resolved-version #f)
                                  (hash-ref request 'variant #f)
                                  (read-toolchain-compiled-file-roots real-bin-dir)))
       =>
       (lambda (v) (list (cons "PLTCOMPILEDROOTS" v)))]
      [else null]))
  (append plthome-entry compiled-roots-entry))

(define (toolchain-meta request id real-bin-dir executables [env-vars null])
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
        'installer-sha256
        (hash-ref request 'installer-sha256 #f)
        'install-root
        (path->string* (rackup-toolchain-install-dir id))
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
  (define explicit-distribution? #f)
  (define snapshot-site 'auto)
  (define arch (normalized-host-arch))
  (define set-default? #f)
  (define force? #f)
  (define no-cache? #f)
  (define verbosity 'normal)
  (define installer-ext #f)
  (command-line #:program "rackup install"
                #:argv opts
                #:once-each [("--variant") v "VM variant" (set! variant v)]
                [("--distribution") d "Distribution"
                                    (set! distribution d)
                                    (set! explicit-distribution? #t)]
                [("--snapshot-site") s "Snapshot mirror" (set! snapshot-site (string->symbol s))]
                [("--arch") a "Target architecture" (set! arch (arch-token->normalized a))]
                [("--set-default") "Set installed toolchain as default" (set! set-default? #t)]
                [("--force") "Reinstall existing canonical toolchain" (set! force? #t)]
                [("--no-cache") "Redownload installer instead of using cache" (set! no-cache? #t)]
                [("--installer-ext") e "Force installer extension (sh, tgz, dmg)" (set! installer-ext e)]
                #:once-any
                [("--quiet") "Show minimal install output" (set! verbosity 'quiet)]
                [("--verbose") "Show detailed installer URL/path output" (set! verbosity 'verbose)]
                #:args ()
                (void))
  (hash 'variant
        variant
        'distribution
        distribution
        'explicit-distribution?
        explicit-distribution?
        'snapshot-site
        snapshot-site
        'arch
        arch
        'set-default?
        set-default?
        'force?
        force?
        'no-cache?
        no-cache?
        'verbosity
        verbosity
        'installer-ext
        installer-ext))

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

(define (local-toolchain-meta id name layout real-bin-dir executables env-vars version* variant*)
  (define platform (host-platform-token))
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
        (hash-ref layout 'collects-dir)
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
  (when (and (directory-exists? tc-dir) (hash-ref parsed-opts 'force? #f))
    (delete-directory/files tc-dir)
    (when (directory-exists? tc-dir)
      (rackup-error "failed to remove existing toolchain before relink: ~a" id)))
  (define layout (detect-local-source-layout local-path))
  (define real-bin-dir (string->path (hash-ref layout 'bin-dir)))
  (define racket-exe (build-path real-bin-dir "racket"))
  (unless (file-executable?/safe racket-exe)
    (rackup-error "linked toolchain does not contain an executable racket binary at ~a"
                  (path->string* racket-exe)))
  (cond
    [(directory-exists? tc-dir)
     (rackup-error "toolchain already exists: ~a (use --force to relink)" id)]
    [else
     (with-handlers ([exn:fail? (lambda (e)
                                  (when (directory-exists? tc-dir)
                                    (delete-directory/files tc-dir))
                                  (raise e))])
       (make-directory* tc-dir)
       (define extra-exes (find-local-chez-extra-executables layout))
       ;; Probe the linked racket with a clean environment so
       ;; find-system-path returns the binary's native addon-dir.
       (define-values (version* variant* addon-dir*)
         (reprobe-local-toolchain (path->string* real-bin-dir)))
       (unless addon-dir*
         (install-warn
          (string-append
           "could not probe addon-dir from ~a; PLTADDONDIR will be unset.\n"
           "  Run `rackup link --force ~a ~a` after fixing the binary\n"
           "  (e.g., once `raco setup` finishes) to record the correct value.")
          (path->string* real-bin-dir) name (hash-ref layout 'input-path)))
       (define env-vars (local-layout-env-vars layout addon-dir* version* variant* name))
       (make-bin-overlay! id real-bin-dir extra-exes)
       (maybe-wrap-local-chez-extra-executables! id extra-exes layout)
       (if (pair? env-vars)
           (write-toolchain-env-file! id env-vars)
           (delete-toolchain-env-file! id))
       (ensure-toolchain-addon-dir! id)
       (define executables (enumerate-toolchain-executables (rackup-toolchain-bin-link id)))
       (define meta (local-toolchain-meta id name layout real-bin-dir executables env-vars version* variant*))
       (commit-state-change!
        (register-toolchain! id meta)
        (when (hash-ref parsed-opts 'set-default? #f)
          (set-default-toolchain! id)))
       (displayln (format "Linked ~a => ~a" id (hash-ref layout 'input-path)))
       id)]))

(define (report-default-change! before after id explicit?)
  (when (and after (not (equal? before after)))
    (cond
      [(and explicit? (equal? after id))
       (install-info "Default toolchain: ~a (set by --set-default)" after)]
      [(and (not before) (equal? after id))
       (install-info "Default toolchain: ~a (set automatically on first install)" after)]
      [else
       (install-info "Default toolchain changed: ~a -> ~a" (or before "none") after)])))

(define (preflight-request-install! request installer-ext)
  (when (and (equal? installer-ext "sh")
             (equal? (hash-ref request 'arch #f) "i386")
             (equal? (hash-ref request 'platform #f) "linux")
             (eq? (hash-ref request 'legacy-install-kind #f) 'shell-basic)
             (not (or (equal? (normalized-host-arch) "i386")
                      (linux-i386-loader-present?))))
    (rackup-error
     (string-append
      "PLT Scheme ~a requires 32-bit Linux compatibility support during installation, but this host does not appear to provide it.\n"
      "The historical installer runs a 32-bit helper while finishing installation.\n"
      "Install 32-bit compatibility packages that provide ld-linux.so.2, or use a newer x86_64-capable release.")
     (hash-ref request 'resolved-version))))

(define (install-toolchain! spec opts)
  (ensure-rackup-layout!)
  (ensure-index!)
  (define parsed-opts (parse-install-options opts))
  (define requested-distribution (hash-ref parsed-opts 'distribution))
  (define request
    (resolve-install-request spec
                             #:variant (hash-ref parsed-opts 'variant)
                             #:distribution requested-distribution
                             #:arch (hash-ref parsed-opts 'arch)
                             #:snapshot-site (hash-ref parsed-opts 'snapshot-site)
                             #:installer-ext (hash-ref parsed-opts 'installer-ext #f)))
  (define fell-back-to-minimal?
    (distribution-fallback? (hash-ref request 'distribution)
                            (if (symbol? requested-distribution)
                                requested-distribution
                                (string->symbol requested-distribution))))
  (define explicit-distribution? (hash-ref parsed-opts 'explicit-distribution?))
  (when fell-back-to-minimal?
    (cond
      [explicit-distribution?
       ;; User explicitly requested --distribution full; require confirmation
       (unless (terminal-port? (current-input-port))
         (rackup-error
          (string-append "no ~a installer available for ~a on ~a; "
                         "rerun with --distribution minimal to install the minimal distribution")
          requested-distribution
          (hash-ref request 'arch)
          (hash-ref request 'platform)))
       (printf "No ~a installer is available for ~a on ~a.\nInstall minimal distribution instead? [y/N] "
               requested-distribution
               (hash-ref request 'arch)
               (hash-ref request 'platform))
       (flush-output)
       (define answer (read-line))
       (unless (and (string? answer)
                    (member (string-downcase (string-trim answer)) '("y" "yes")))
         (rackup-error "install aborted"))]
      [else
       ;; Default full was unavailable; proceed with warning
       (eprintf "WARNING: no full installer available for ~a on ~a; installing minimal instead.\n"
                (hash-ref request 'arch)
                (hash-ref request 'platform))]))
  (define id (canonical-id-for-request request))
  (define tc-dir (rackup-toolchain-dir id))
  (define install-root (rackup-toolchain-install-dir id))
  (parameterize ([current-install-verbosity (hash-ref parsed-opts 'verbosity 'normal)])
    (define default-before (get-default-toolchain))
    (define explicit-default? (hash-ref parsed-opts 'set-default? #f))
    (when (and (directory-exists? tc-dir) (hash-ref parsed-opts 'force? #f))
      (delete-directory/files tc-dir)
      (when (directory-exists? tc-dir)
        (rackup-error "failed to remove existing toolchain before reinstall: ~a" id)))
    ;; A directory without an index entry is a ghost from a prior interrupted
    ;; install.  Clean it up so the install can proceed.
    (when (and (directory-exists? tc-dir) (not (toolchain-exists? id)))
      (delete-directory/files tc-dir))
    (cond
      [(directory-exists? tc-dir)
       (install-ok "Already installed: ~a" id)
       (commit-state-change!
        (when explicit-default?
          (set-default-toolchain! id)))
       (report-default-change! default-before (get-default-toolchain) id explicit-default?)
       id]
      [else
       (install-info "Installing ~a..." id)
       (define installer-path
         (ensure-installer-cached! (hash-ref request 'installer-url)
                                   #:no-cache? (hash-ref parsed-opts 'no-cache? #f)
                                   #:sha256 (hash-ref request 'installer-sha256 #f)
                                   #:sha1 (hash-ref request 'installer-sha1 #f)))
       (define installer-ext
         (installer-filename-extension
          (hash-ref request
                    'installer-filename
                    (path-basename-string (string->path (path->string* installer-path))))))
       (preflight-request-install! request installer-ext)
       (with-handlers ([(lambda (e) (or (exn:fail? e) (exn:break? e)))
                        (lambda (e)
                                    (when (directory-exists? tc-dir)
                                      (delete-directory/files tc-dir))
                                    (raise e))])
         (make-directory* tc-dir)
         (cond
           [(equal? installer-ext "sh")
            (run-linux-installer! installer-path
                                  install-root
                                  #:legacy-install-kind (hash-ref request 'legacy-install-kind #f))]
           [(equal? installer-ext "tgz") (run-tgz-installer! installer-path install-root)]
           [(equal? installer-ext "dmg") (run-macos-dmg-installer! installer-path install-root)]
           [else
            (rackup-error "unsupported installer format for ~a: ~a"
                          (host-platform-token)
                          (or installer-ext "unknown"))])
         (define real-bin-dir (detect-bin-dir install-root))
         (maybe-modernize-legacy-archsys! real-bin-dir)
         (make-bin-link! id real-bin-dir)
         (define env-vars (installed-toolchain-env-vars real-bin-dir request))
         (if (pair? env-vars)
             (write-toolchain-env-file! id env-vars)
             (delete-toolchain-env-file! id))
         (ensure-toolchain-addon-dir! id)
         (define executables (enumerate-toolchain-executables real-bin-dir))
         (define meta (toolchain-meta request id real-bin-dir executables env-vars))
         (commit-state-change!
          (register-toolchain! id meta)
          (when explicit-default?
            (set-default-toolchain! id)))
         (install-ok "Installed ~a" id)
         (report-default-change! default-before (get-default-toolchain) id explicit-default?)
         (when fell-back-to-minimal?
           (printf "\nTip: to get the full Racket distribution, run:\n  raco pkg install main-distribution\n"))
         id)])))

(define (remove-toolchain! id #:clean-compiled? [clean-compiled? #f])
  (ensure-index!)
  (unless (toolchain-exists? id)
    (rackup-error "toolchain not installed: ~a" id))
  (when clean-compiled?
    (clean-toolchain-compiled-dirs! id))
  (define tc-dir (rackup-toolchain-dir id))
  (define addon (rackup-addon-dir id))
  (when (directory-exists? tc-dir)
    (delete-directory/files tc-dir))
  (when (directory-exists? addon)
    (delete-directory/files addon))
  (commit-state-change!
   (unregister-toolchain! id))
  (displayln (format "Removed ~a" id)))

;; ---------------------------------------------------------------------------
;; Upgrade

;; Build the environment variable alist for running a toolchain's raco.
(define (toolchain-runtime-env id)
  (append (toolchain-env-vars id)
          (list (cons "PLTADDONDIR"
                      (path->string (rackup-addon-dir id))))))

;; Run raco with the correct env for a toolchain.  Returns stdout as a
;; string on success, #f on failure.
(define (capture-raco-output id . raco-args)
  (define bin (rackup-toolchain-bin-link id))
  (define raco-exe (build-path bin "raco"))
  (apply capture-program-output
         #:env (toolchain-runtime-env id)
         raco-exe
         raco-args))

;; Run racket -e with the correct env for a toolchain.  Returns stdout
;; as a string on success, #f on failure.
(define (capture-racket-eval-output id expr-text)
  (define bin (rackup-toolchain-bin-link id))
  (define racket-exe (build-path bin "racket"))
  (capture-program-output
   #:env (toolchain-runtime-env id)
   racket-exe
   "-e"
   expr-text))

;; A small Racket program that prints the absolute source directory of
;; every user-scope package, one per line.  Covers both catalog
;; installs and `raco pkg install --link` installs.
(define list-pkg-dirs-program
  (string-join
   '("(begin"
     " (require pkg/lib racket/path)"
     " (parameterize ([current-pkg-scope 'user])"
     "  (with-pkg-lock/read-only"
     "   (define cache (make-hash))"
     "   (for ([name (in-list (sort (hash-keys (installed-pkg-table)) string<?))])"
     "    (define dir (pkg-directory name #:cache cache))"
     "    (when dir"
     "     (displayln"
     "      (path->string"
     "       (simplify-path (path->complete-path dir)))))))))")
   " "))

;; Query the toolchain for absolute source directories of all
;; user-scope packages (catalog and linked).  Returns a list of strings,
;; or #f if the toolchain's racket cannot be invoked.
(define (toolchain-user-package-dirs id)
  (define out
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (capture-racket-eval-output id list-pkg-dirs-program)))
  (cond
    [(or (not out) (string-blank? out)) null]
    [else
     (for/list ([line (in-list (string-split out "\n"))]
                #:when (not (string-blank? line)))
       (string-trim line))]))

;; Recursively find directories named `target` (a string) under `root`
;; and call `proc` on each one.  Does not descend into the matched
;; directories.  Skips symlinks to avoid escaping the root or looping.
(define (for-each-named-subdir root target proc)
  (define (walk dir)
    (when (and (directory-exists? dir) (not (link-exists? dir)))
      (for ([entry (in-list (with-handlers ([exn:fail? (lambda (_) null)])
                              (directory-list dir #:build? #t)))])
        (cond
          [(link-exists? entry) (void)]
          [(directory-exists? entry)
           (cond
             [(equal? (path-basename-string entry) target)
              (proc entry)]
             [else (walk entry)])]))))
  (walk root))

;; Walk the package source directories of toolchain `id` and remove any
;; `compiled/<key>/` subdirectories, where `<key>` is derived from the
;; toolchain's version+variant.  Reports what was removed.
(define (clean-toolchain-compiled-dirs! id)
  (define meta (read-toolchain-meta id))
  (unless (hash? meta)
    (install-warn "Cannot clean compiled dirs: missing metadata for ~a" id)
    (set! meta (hash)))
  (define local-name
    (and (eq? (hash-ref meta 'kind #f) 'local)
         (hash-ref meta 'requested-spec #f)))
  (define key-value
    (compiled-roots-value (hash-ref meta 'resolved-version #f)
                          (hash-ref meta 'variant #f)
                          '(same)
                          local-name))
  (cond
    [(not key-value)
     (install-warn
      "Cannot clean compiled dirs for ~a: no usable version+variant in metadata"
      id)]
    [else
     ;; key-value is "compiled/<key>:." -- extract just <key>.
     (define key
       (let* ([before-colon (car (string-split key-value ":"))]
              [after-slash (cadr (string-split before-colon "/"))])
         after-slash))
     (install-info "Scanning user packages for compiled/~a directories..." key)
     (define dirs (toolchain-user-package-dirs id))
     (cond
       [(null? dirs)
        (install-info "No user packages with source directories found.")]
       [else
        (define removed 0)
        (define addon (path->string* (rackup-addon-dir id)))
        (for ([d (in-list dirs)])
          (define d-path (string->path d))
          (when (directory-exists? d-path)
            (for-each-named-subdir
             d-path
             "compiled"
             (lambda (compiled-dir)
               (define versioned (build-path compiled-dir key))
               (when (and (directory-exists? versioned) (not (link-exists? versioned)))
                 (with-handlers ([exn:fail?
                                  (lambda (e)
                                    (install-warn "Failed to remove ~a: ~a"
                                                  (path->string* versioned)
                                                  (exn-message e)))])
                   (delete-directory/files versioned)
                   (set! removed (+ removed 1))))))))
        (install-ok "Cleaned ~a compiled/~a director~a"
                    removed
                    key
                    (if (= removed 1) "y" "ies"))])]))

;; Parse `raco pkg show --user` into a list of package names.  Header
;; line "Package Checksum Source"; "[none]" means empty.  Filter
;; tokens that don't match the package-name pattern so stray bytes
;; (terminal escape fragments, partial error messages) aren't passed
;; to `raco pkg install`.
(define (parse-pkg-show-output text)
  (if (or (not text) (string-blank? text))
      null
      (for/list ([line (in-list (string-split text "\n"))]
                 #:unless (or (string-blank? line)
                              (regexp-match? #px"^\\s*Package\\b" line)
                              (regexp-match? #px"\\[none\\]" line))
                 [tok (in-value (car (string-split (string-trim line))))]
                 #:when (valid-pkg-name? tok))
        tok)))

;; Migrate user-scoped packages from old-id to new-id by listing
;; packages from the old toolchain and installing them in the new one.
;; Returns #t on success (or when there are no packages to migrate),
;; #f when the migration command reported errors.
(define (migrate-user-packages! old-id new-id)
  (install-info "Checking for user packages to migrate...")
  (define show-output (capture-raco-output old-id "pkg" "show" "--user"))
  (define pkgs (parse-pkg-show-output show-output))
  (cond
    [(null? pkgs)
     (install-info "No user packages to migrate.")
     #t]
    [else
     (install-info "Migrating ~a user package~a: ~a"
                   (length pkgs)
                   (if (= (length pkgs) 1) "" "s")
                   (string-join pkgs " "))
     (define bin (rackup-toolchain-bin-link new-id))
     (define raco-exe (build-path bin "raco"))
     (define env (environment-variables-copy (current-environment-variables)))
     (for ([kv (in-list (toolchain-runtime-env new-id))])
       (environment-variables-set! env
                                   (string->bytes/utf-8 (car kv))
                                   (string->bytes/utf-8 (cdr kv))))
     (define ok?
       (parameterize ([current-environment-variables env])
         (apply system* raco-exe "pkg" "install" "--auto" "--skip-installed" pkgs)))
     (cond
       [ok?
        (install-ok "Migrated ~a package~a."
                    (length pkgs)
                    (if (= (length pkgs) 1) "" "s"))
        #t]
       [else
        (install-warn "Package migration had errors. Some packages may not have been migrated.")
        #f])]))

;; Determine the install spec to use when resolving the latest version
;; for a toolchain's channel.  The kind field is 'release for both
;; stable and version-pinned installs, so we use requested-spec.
(define (meta->upgrade-spec meta)
  (define spec (hash-ref meta 'requested-spec #f))
  (define kind (hash-ref meta 'kind #f))
  (cond
    [(equal? spec "stable") "stable"]
    [(or (equal? spec "pre-release") (equal? spec "pre")
         (eq? kind 'pre-release))
     "pre-release"]
    [(or (equal? spec "snapshot")
         (and (string? spec) (string-prefix? spec "snapshot:"))
         (eq? kind 'snapshot))
     (define site (hash-ref meta 'snapshot-site #f))
     (if (and site (not (eq? site 'auto)))
         (format "snapshot:~a" site)
         "snapshot")]
    [else #f]))

;; Check whether a newer version is available for the given toolchain.
;; Returns (values newer? request) where request is the resolved
;; install request for the latest version, or #f if resolution fails.
(define (check-upgrade-available meta)
  (define spec (meta->upgrade-spec meta))
  (unless spec
    (rackup-error "cannot determine upgrade spec for toolchain kind: ~a"
                  (hash-ref meta 'kind)))
  (define variant (let ([v (hash-ref meta 'variant #f)])
                    (and v (format "~a" v))))
  (define distribution (let ([d (hash-ref meta 'distribution #f)])
                         (if (symbol? d) d
                             (and d (string->symbol d)))))
  (define arch (hash-ref meta 'arch #f))
  (define snapshot-site
    (let ([s (hash-ref meta 'snapshot-site #f)])
      (cond [(not s) 'auto]
            [(symbol? s) s]
            [else (string->symbol s)])))
  (define request
    (resolve-install-request spec
                             #:variant variant
                             #:distribution distribution
                             #:arch arch
                             #:snapshot-site snapshot-site))
  (define current-version (hash-ref meta 'resolved-version #f))
  (define latest-version (hash-ref request 'resolved-version))
  (define snapshot-channel?
    (and (string? spec) (or (equal? spec "snapshot")
                            (string-prefix? spec "snapshot:"))))
  (define newer?
    (cond
      [snapshot-channel?
       (define current-stamp (hash-ref meta 'snapshot-stamp #f))
       (define latest-stamp (hash-ref request 'snapshot-stamp #f))
       (or (not current-stamp)
           (not latest-stamp)
           (string>? latest-stamp current-stamp))]
      [else
       (and current-version
            latest-version
            (> (cmp-versions latest-version current-version) 0))]))
  (values newer? request))

;; Upgrade a single toolchain.  Returns the new toolchain ID on
;; success, or #f if already up to date.
(define (upgrade-toolchain! id meta
                            #:force? [force? #f]
                            #:no-cache? [no-cache? #f])
  (ensure-rackup-layout!)
  (ensure-index!)
  (define kind (hash-ref meta 'kind))
  (define current-version (hash-ref meta 'resolved-version "?"))
  (install-info "Checking ~a (~a)..." id current-version)
  (define-values (newer? request) (check-upgrade-available meta))
  (define latest-version (hash-ref request 'resolved-version))
  (cond
    [(or newer? force?)
     (when newer?
       (install-info "  ~a -> ~a available" current-version latest-version))
     (when (and force? (not newer?))
       (install-info "  Forcing reinstall of ~a" current-version))
     (define was-default? (equal? id (get-default-toolchain)))
     ;; Build install opts from current toolchain's settings
     (define install-opts
       (append
        (let ([v (hash-ref meta 'variant #f)])
          (if v (list "--variant" (format "~a" v)) null))
        (let ([d (hash-ref meta 'distribution #f)])
          (if d (list "--distribution" (format "~a" d)) null))
        (let ([s (hash-ref meta 'snapshot-site #f)])
          (if (and s (not (eq? s 'auto)))
              (list "--snapshot-site" (format "~a" s))
              null))
        (if force? (list "--force") null)
        (if no-cache? (list "--no-cache") null)))
     (define spec (meta->upgrade-spec meta))
     (define new-id (install-toolchain! spec install-opts))
     (when (and (not (equal? new-id id)) (toolchain-exists? id))
       (define migrated? (migrate-user-packages! id new-id))
       (when was-default?
         (commit-state-change!
          (set-default-toolchain! new-id))
         (install-info "Default toolchain updated to ~a" new-id))
       (cond
         [migrated?
          (remove-toolchain! id)]
         [else
          ;; Migration failed -- keep the old toolchain so the user can
          ;; recover.  Don't silently delete data.
          (install-warn
           (string-append
            "Keeping old toolchain ~a because migration failed.\n"
            "  Investigate the failure above, then either:\n"
            "    - rackup upgrade --force ~a   (retry migration)\n"
            "    - rackup remove ~a            (discard old toolchain)")
           id id id)]))
     new-id]
    [else
     (install-ok "  ~a is up to date (~a)" id current-version)
     #f]))

(define (doctor-report)
  (ensure-rackup-layout!)
  (ensure-index!)
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (define default-id (get-default-toolchain idx))
  (define runtime-status (hidden-runtime-status))
  (define runtime-mode (hash-ref runtime-status 'mode #f))
  (define runtime-meta (hash-ref runtime-status 'meta #f))
  (define wrapper-runtime-source
    (cond
      [(eq? runtime-mode 'embedded-exe) 'embedded-exe]
      [(hash-ref runtime-status 'present? #f) 'internal]
      [(find-executable-path "racket") 'system]
      [else 'none]))
  (define findings
    (append
     (list (cons 'home (path->string* (rackup-home)))
           (cons 'bin (path->string* (rackup-bin-entry)))
           (cons 'shim-dispatcher (path->string* (rackup-shim-dispatcher)))
           (cons 'shims-dir (path->string* (rackup-shims-dir)))
           (cons 'installed-count (length ids))
           (cons 'default default-id)
           (cons 'wrapper-runtime-source wrapper-runtime-source))
     (if (eq? runtime-mode 'embedded-exe)
         (list (cons 'runtime-mode 'embedded-exe)
               (cons 'runtime-present #t))
         (list (cons 'runtime-present (hash-ref runtime-status 'present? #f))
               (cons 'runtime-id (hash-ref runtime-status 'id #f))
               (cons 'runtime-version
                     (and (hash? runtime-meta) (hash-ref runtime-meta 'resolved-version #f)))
               (cons 'runtime-racket (hash-ref runtime-status 'racket-path #f))))))
  (for ([kv findings])
    (printf "~a: ~a\n" (ansi "1" (format "~a" (car kv))) (cdr kv)))
  (for ([id ids])
    (define m (read-toolchain-meta id))
    (printf "toolchain ~a => ~a\n"
            id
            (ansi "90" (format "(~a, ~a, ~a)"
                                (hash-ref m 'resolved-version #f)
                                (hash-ref m 'variant #f)
                                (hash-ref m 'distribution #f))))))

(module+ for-testing
  (provide detect-bin-dir
           installed-toolchain-env-vars
           ensure-installer-cached!
           parse-pkg-show-output
           meta->upgrade-spec
           write-toolchain-env-file!
           clean-toolchain-compiled-dirs!))
