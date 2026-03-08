#lang racket/base

(require racket/file
         racket/path
         racket/runtime-path
         racket/string
         racket/system
         file/sha1
         "../pages/site.rkt")

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

(define out-dir
  (path->complete-path
   (let ([args (current-command-line-arguments)])
     (if (> (vector-length args) 0)
         (vector-ref args 0)
         "_site"))))

(define tmp-stage (make-temporary-directory))
(define plt-web-stage (build-path tmp-stage "plt-web-out"))

(define (run prog . args)
  (unless (apply system*
                 prog
                 (map (lambda (a)
                        (if (path? a)
                            (path->string a)
                            a))
                      args))
    (error 'build-pages-site "command failed: ~a" prog)))

(dynamic-wind
 void
 (lambda ()
   (make-directory* out-dir)

   ;; Build tarball
   (define src-stage (build-path tmp-stage "rackup-src"))
   (make-directory* src-stage)
   (run (build-path root-dir "scripts" "copy-filtered-tree.sh")
        root-dir
        src-stage
        "bin"
        "libexec"
        "scripts/copy-filtered-tree.sh")
   ;; Build demodularized .zo before creating tarball
   (let* ([libexec (build-path src-stage "libexec")]
          [core (build-path libexec "rackup-core.rkt")]
          [merged (build-path libexec "compiled" "rackup-core_rkt_merged.zo")])
     (make-directory* (path-only merged))
     (run (find-executable-path "raco")
          "demod" "-s" "-M" "-g" "-o"
          merged core)
     (unless (file-exists? merged)
       (eprintf "build-pages-site: compiled dir contents: ~a\n"
                (if (directory-exists? (path-only merged))
                    (directory-list (path-only merged))
                    "(directory does not exist)"))
       (error 'build-pages-site
              "raco demod succeeded but output file not found: ~a" merged)))

   (run (find-executable-path "tar")
        "-C"
        tmp-stage
        "-czf"
        (build-path out-dir "rackup-src.tar.gz")
        "rackup-src")

   ;; Compute SHA-256 of tarball and substitute into install.sh
   (define src-sha256
     (bytes->hex-string (call-with-input-file (build-path out-dir "rackup-src.tar.gz") sha256-bytes)))
   (define install-content
     (string-replace (file->string (build-path root-dir "scripts" "install.sh"))
                     "@@RACKUP_SRC_SHA256@@"
                     src-sha256))
   (for ([name '("install.sh" "install")])
     (define p (build-path out-dir name))
     (call-with-output-file p (lambda (out) (display install-content out)) #:exists 'truncate/replace)
     (file-or-directory-permissions p #o755))

   ;; Generate HTML via plt-web; render-all writes to www/ under CWD
   (make-directory* plt-web-stage)
   (parameterize ([current-directory plt-web-stage])
     (generate-site (path->string (build-path out-dir "install.sh"))))

   ;; Copy plt-web output into out-dir
   (define www-dir (build-path plt-web-stage "www"))
   (for ([entry (in-list (directory-list www-dir #:build? #t))])
     (define dest (build-path out-dir (file-name-from-path entry)))
     (cond
       [(directory-exists? entry) (copy-directory/files entry dest)]
       [else (copy-file entry dest #t)]))

   ;; Create .nojekyll marker
   (call-with-output-file (build-path out-dir ".nojekyll") void #:exists 'truncate/replace)

   (printf "Built GitHub Pages site in ~a\n" out-dir))
 (lambda () (delete-directory/files tmp-stage #:must-exist? #f)))
