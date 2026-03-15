#lang racket/base

(require racket/file
         racket/hash
         racket/match
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         file/sha1
         net/url
         "../libexec/rackup/remote.rkt")

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

(define out-dir
  (let ([args (current-command-line-arguments)])
    (if (> (vector-length args) 0)
        (vector-ref args 0)
        "_site")))

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
   (run (find-executable-path "tar")
        "-C"
        tmp-stage
        "-czf"
        (build-path out-dir "rackup-src.tar.gz")
        "rackup-src")

   ;; Compute SHA-256 of tarball, write sidecar file, and substitute into install.sh
   (define src-sha256
     (bytes->hex-string (call-with-input-file (build-path out-dir "rackup-src.tar.gz") sha256-bytes)))
   (call-with-output-file (build-path out-dir "rackup-src.tar.gz.sha256")
     (lambda (out) (fprintf out "~a  rackup-src.tar.gz\n" src-sha256))
     #:exists 'truncate/replace)
   ;; Fetch current stable Racket version and extract runtime installer checksums
   ;; from the release page HTML for embedding into install.sh.
   (define runtime-checksums-str
     (with-handlers ([exn:fail? (lambda (e)
                                  (eprintf "warning: could not fetch runtime checksums: ~a\n" (exn-message e))
                                  "")])
       (define version-txt (port->string (get-pure-port (string->url "https://download.racket-lang.org/version.txt"))))
       (define stable-ver
         (match (regexp-match #px"\\(stable \"([^\"]+)\"\\)" version-txt)
           [(list _ v) v]
           [_ (error "could not parse stable version from version.txt")]))
       (define page-html
         (port->string (get-pure-port (string->url (format "https://download.racket-lang.org/releases/~a/" stable-ver)))))
       (define checksums (parse-download-page-checksums page-html))
       ;; Filter to minimal installers and format as filename:sha256 lines
       (string-join
        (for/list ([(filename algo+hex) (in-hash checksums)]
                   #:when (string-contains? filename "-minimal-"))
          (format "~a:~a" filename (cdr algo+hex)))
        "\n")))

   (define install-content
     (string-replace
      (string-replace (file->string (build-path root-dir "scripts" "install.sh"))
                      "@@RACKUP_SRC_SHA256@@"
                      src-sha256)
      "@@RACKUP_RUNTIME_CHECKSUMS@@"
      runtime-checksums-str))
   (for ([name '("install.sh" "install")])
     (define p (build-path out-dir name))
     (call-with-output-file p (lambda (out) (display install-content out)) #:exists 'truncate/replace)
     (file-or-directory-permissions p #o755))

   ;; Generate HTML; Racket computes the install.sh checksum itself
   (make-directory* plt-web-stage)
   (run (find-executable-path "racket")
        (build-path root-dir "pages" "site.rkt")
        "--install-sh"
        (build-path out-dir "install.sh")
        "-r"
        "-o"
        plt-web-stage
        "-f")

   ;; Copy plt-web output into out-dir
   (define www-dir (build-path plt-web-stage "www"))
   (for ([entry (in-list (directory-list www-dir #:build? #t))])
     (define dest (build-path out-dir (file-name-from-path entry)))
     (cond
       [(directory-exists? entry) (copy-directory/files entry dest)]
       [else (copy-file entry dest #t)]))

   ;; Generate docs page from Scribble source (scribble/manual → HTML)
   (run (find-executable-path "scribble")
        "--html" "--dest" out-dir "--dest-name" "docs"
        (build-path root-dir "docs" "rackup.scrbl"))

   ;; Copy favicon
   (copy-file (build-path here "favicon.svg") (build-path out-dir "favicon.svg") #t)

   ;; Create .nojekyll marker
   (call-with-output-file (build-path out-dir ".nojekyll") void #:exists 'truncate/replace)

   (printf "Built GitHub Pages site in ~a\n" out-dir))
 (lambda () (delete-directory/files tmp-stage #:must-exist? #f)))
