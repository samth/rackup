#lang racket/base

(require racket/cmdline
         racket/file
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
         run-linux-installer!
         run-linux-tgz-installer!
         enumerate-toolchain-executables
         doctor-report)

(define current-install-verbosity (make-parameter 'normal))

(define (install-verbosity)
  (current-install-verbosity))

(define (install-quiet?)
  (eq? (install-verbosity) 'quiet))

(define (install-verbose?)
  (eq? (install-verbosity) 'verbose))

(define (install-color-enabled?)
  (and (terminal-port? (current-output-port)) (not (getenv "NO_COLOR"))))

(define (ansi-color code s)
  (if (install-color-enabled?)
      (string-append "\u001b[" code "m" s "\u001b[0m")
      s))

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

(define (sha256-exe)
  (cond
    [(find-executable-path "sha256sum") => (lambda (p) (cons 'sha256sum p))]
    [(find-executable-path "shasum") => (lambda (p) (cons 'shasum p))]
    [(find-executable-path "openssl") => (lambda (p) (cons 'openssl p))]
    [else #f]))

(define (system*/capture-string who . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (if (apply system* args)
        (string-trim (get-output-string out))
        (rackup-error "~a failed: ~a~a"
                      who
                      (string-join (map path->string* args) " ")
                      (let ([e (string-trim (get-output-string err))])
                        (if (string-blank? e)
                            ""
                            (string-append "\n" e)))))))

(define (file-sha256 p)
  (match (sha256-exe)
    [(cons 'sha256sum exe)
     (car (string-split (system*/capture-string 'sha256sum exe p)))]
    [(cons 'shasum exe)
     (car (string-split (system*/capture-string 'shasum exe "-a" "256" p)))]
    [(cons 'openssl exe)
     (last (string-split (system*/capture-string 'openssl exe "dgst" "-sha256" p)))]
    [_ (rackup-error "could not find sha256sum, shasum, or openssl to verify downloads")]))

(define (verify-installer-sha256! installer-path expected-sha256)
  (when expected-sha256
    (define actual-sha256 (file-sha256 installer-path))
    (unless (equal? (string-downcase actual-sha256) (string-downcase expected-sha256))
      (rackup-error "download checksum mismatch for ~a\nexpected: ~a\nactual:   ~a"
                    (path->string* installer-path)
                    expected-sha256
                    actual-sha256))))

(define (ensure-installer-cached! installer-url
                                  #:no-cache? [no-cache? #f]
                                  #:sha256 [expected-sha256 #f])
  (ensure-rackup-layout!)
  (require-checksummed-http-installer! installer-url expected-sha256)
  (define cache-path (installer-cache-file installer-url))
  (when (and (file-exists? cache-path) expected-sha256)
    (with-handlers ([exn:fail? (lambda (_)
                                 (delete-file cache-path))])
      (verify-installer-sha256! cache-path expected-sha256)))
  (when (or no-cache? (not (file-exists? cache-path)))
    (if (install-verbose?)
        (install-verbose "Downloading installer: ~a" installer-url)
        (install-info "Downloading installer..."))
    (download-url->file installer-url cache-path)
    (verify-installer-sha256! cache-path expected-sha256)
    (file-or-directory-permissions cache-path #o755))
  cache-path)

(define (legacy-interactive-linux-installer? installer-file)
  (regexp-match? #px"(?:^|/)(?:racket(?:-textual)?|plt)-.+-bin-.+[.]sh$"
                 (path->string* installer-file)))

(define (read-file-prefix-bytes p [limit 65536])
  (call-with-input-file* p
    (lambda (in)
      (or (read-bytes limit in) #""))))

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
    [(regexp-match? #rx#"Do you want a Unix-style distribution\\?" prefix)
     'shell-unixstyle]
    [(regexp-match? #rx#"Where do you want to install the \"" prefix)
     'shell-basic]
    [else #f]))

(define (legacy-installer-input-script dest legacy-install-kind)
  ;; Old PLT/Racket installers (e.g. 5.2, 4.x/3xx) do not support --dest/--in-place.
  ;; Answer prompts for a whole-directory install into the exact requested destination,
  ;; then skip creating system links.
  (case legacy-install-kind
    [(shell-basic) (format "~a\n\n" (path->string* dest))]
    [(shell-unixstyle) (format "n\n~a\n\n" (path->string* dest))]
    [else (rackup-error "unknown legacy installer kind: ~a" legacy-install-kind)]))

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
    (rackup-error "linux-installer failed: ~a (~a)"
                  (path->string* installer)
                  (if legacy-kind
                      "legacy interactive mode"
                      (format "--create-dir --in-place --dest ~a" (path->string* dest)))))
  (delete-log!))

(define (tar-exe)
  (or (find-executable-path "tar") (string->path "/bin/tar")))

(define (run-linux-tgz-installer! installer-file install-root)
  (define archive (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (install-verbose "Extracting archive into ~a" (path->string dest))
  (make-directory* dest)
  (system*/check 'linux-tgz-installer (tar-exe) "-xzf" archive "-C" dest))

(define (installer-filename-extension s)
  (define low (string-downcase s))
  (cond
    [(regexp-match? #px"[.]sh$" low) "sh"]
    [(regexp-match? #px"[.]tgz$" low) "tgz"]
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
  (define petite-boot (build-path plthome "lib" "racket" "petite.boot"))
  (define scheme-boot (build-path plthome "lib" "racket" "scheme.boot"))
  (if (file-exists? petite-boot)
      (append (list (cons "petite" (list "-B" (path->string* petite-boot))))
              (if (file-exists? scheme-boot)
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

(define (local-layout-env-vars layout [addon-dir #f])
  (define collects-dir (hash-ref layout 'collects-dir))
  (define pkgs-dir (hash-ref layout 'pkgs-dir #f))
  (define collects-path
    (if pkgs-dir
        (path-join/colon (list collects-dir pkgs-dir))
        (path-join/colon (list collects-dir))))
  (append (list (cons "PLTHOME" (hash-ref layout 'plthome))
                (cons "PLTCOLLECTS" collects-path))
          (if (and (string? addon-dir) (not (string-blank? addon-dir)))
              (list (cons "PLTADDONDIR" addon-dir))
              null)))

(define (probe-local-racket-version+variant+addon-dir bin-dir env-vars)
  (define racket-exe (build-path (string->path bin-dir) "racket"))
  (define version-out (capture-program-output #:env env-vars racket-exe "-e" "(display (version))"))
  (define variant-out
    (capture-program-output
     #:env env-vars
     racket-exe
     "-e"
     "(display (let ([v (system-type 'vm)]) (if (symbol? v) (symbol->string v) (format \"~a\" v))))"))
  (define addon-out
    (capture-program-output
     #:env env-vars
     racket-exe
     "-e"
     "(display (find-system-path 'addon-dir))"))
  (values (and version-out (not (string-blank? version-out)) version-out)
          (and variant-out (not (string-blank? variant-out)) (string-downcase variant-out))
          (and addon-out (not (string-blank? addon-out)) addon-out)))

(define (installed-toolchain-env-vars real-bin-dir)
  (define plthome (maybe-parent real-bin-dir))
  (define-values (plthome-base plthome-leaf _plthome-dir?)
    (if plthome
        (split-path plthome)
        (values #f #f #f)))
  (define plthome-name
    (and (path? plthome-leaf) (path->string plthome-leaf)))
  (define plthome-normalized
    (and plthome-base (path? plthome-leaf) (build-path plthome-base plthome-leaf)))
  (cond
    [(and plthome-normalized (equal? plthome-name "plt"))
     (list (cons "PLTHOME" (path->string* plthome-normalized)))]
    [else null]))

(define (maybe-modernize-legacy-archsys! real-bin-dir)
  (define plthome (maybe-parent real-bin-dir))
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
  (define snapshot-site 'auto)
  (define arch (normalized-host-arch))
  (define set-default? #f)
  (define force? #f)
  (define no-cache? #f)
  (define verbosity 'normal)
  (command-line #:program "rackup install"
                #:argv opts
                #:once-each [("--variant") v "VM variant" (set! variant v)]
                [("--distribution") d "Distribution" (set! distribution d)]
                [("--snapshot-site") s "Snapshot mirror" (set! snapshot-site (string->symbol s))]
                [("--arch") a "Target architecture" (set! arch (arch-token->normalized a))]
                [("--set-default") "Set installed toolchain as default" (set! set-default? #t)]
                [("--force") "Reinstall existing canonical toolchain" (set! force? #t)]
                [("--no-cache") "Redownload installer instead of using cache" (set! no-cache? #t)]
                #:once-any
                [("--quiet") "Show minimal install output" (set! verbosity 'quiet)]
                [("--verbose") "Show detailed installer URL/path output" (set! verbosity 'verbose)]
                #:args ()
                (void))
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
        no-cache?
        'verbosity
        verbosity))

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
       (define base-env-vars (local-layout-env-vars layout))
       (define-values (version* variant* addon-dir*)
         (probe-local-racket-version+variant+addon-dir (path->string* real-bin-dir) base-env-vars))
       (define env-vars (local-layout-env-vars layout addon-dir*))
       (make-bin-overlay! id real-bin-dir extra-exes)
       (maybe-wrap-local-chez-extra-executables! id extra-exes layout)
       (write-toolchain-env-file! id env-vars)
       (ensure-toolchain-addon-dir! id)
       (define executables (enumerate-toolchain-executables (rackup-toolchain-bin-link id)))
       (define meta (local-toolchain-meta id name layout real-bin-dir executables env-vars version* variant*))
       (register-toolchain! id meta)
       (when (hash-ref parsed-opts 'set-default? #f)
         (set-default-toolchain! id))
       (reshim!)
       (displayln (format "Linked ~a => ~a" id (hash-ref layout 'plthome)))
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
  (define request
    (resolve-install-request spec
                             #:variant (hash-ref parsed-opts 'variant)
                             #:distribution (hash-ref parsed-opts 'distribution)
                             #:arch (hash-ref parsed-opts 'arch)
                             #:snapshot-site (hash-ref parsed-opts 'snapshot-site)))
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
    (cond
      [(directory-exists? tc-dir)
       (install-ok "Already installed: ~a" id)
       (when explicit-default?
         (set-default-toolchain! id))
       (reshim!)
       (report-default-change! default-before (get-default-toolchain) id explicit-default?)
       id]
      [else
       (install-info "Installing ~a..." id)
       (define installer-path
         (ensure-installer-cached! (hash-ref request 'installer-url)
                                   #:no-cache? (hash-ref parsed-opts 'no-cache? #f)
                                   #:sha256 (hash-ref request 'installer-sha256 #f)))
       (define installer-ext
         (installer-filename-extension
          (hash-ref request
                    'installer-filename
                    (path-basename-string (string->path (path->string* installer-path))))))
       (preflight-request-install! request installer-ext)
       (with-handlers ([exn:fail? (lambda (e)
                                    (when (directory-exists? tc-dir)
                                      (delete-directory/files tc-dir))
                                    (raise e))])
         (make-directory* tc-dir)
         (cond
           [(equal? installer-ext "sh")
            (run-linux-installer! installer-path
                                  install-root
                                  #:legacy-install-kind (hash-ref request 'legacy-install-kind #f))]
           [(equal? installer-ext "tgz") (run-linux-tgz-installer! installer-path install-root)]
           [else
            (rackup-error "unsupported installer format for Linux: ~a"
                          (or installer-ext "unknown"))])
         (define real-bin-dir (detect-bin-dir install-root))
         (maybe-modernize-legacy-archsys! real-bin-dir)
         (make-bin-link! id real-bin-dir)
         (define env-vars (installed-toolchain-env-vars real-bin-dir))
         (if (pair? env-vars)
             (write-toolchain-env-file! id env-vars)
             (delete-toolchain-env-file! id))
         (ensure-toolchain-addon-dir! id)
         (define executables (enumerate-toolchain-executables real-bin-dir))
         (define meta (toolchain-meta request id real-bin-dir executables env-vars))
         (register-toolchain! id meta)
         (when explicit-default?
           (set-default-toolchain! id))
         (reshim!)
         (install-ok "Installed ~a" id)
         (report-default-change! default-before (get-default-toolchain) id explicit-default?)
         id)])))

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
