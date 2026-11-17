#lang racket/base

(require file/untgz
         racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "checksum.rkt"
         "error.rkt"
         "paths.rkt"
         "platform.rkt"
         "process.rkt"
         "remote.rkt"
         "security.rkt"
         "text.rkt")

(provide detect-installer-type
         ensure-installer-cached!
         extract-tgz-installer!
         install-from-dmg!
         extract-nsis-installer!
         discover-bin-dir)

(define (default-announce msg) (displayln msg))

(define (hdiutil-exe) (find-executable-path/default "hdiutil" "/usr/bin/hdiutil"))
(define (ditto-exe)   (find-executable-path/default "ditto"   "/usr/bin/ditto"))

;; Return installer type from a filename/path:
;; - "sh" for shell installers
;; - "tgz" for gzip-compressed tar archives
;; - "dmg" for macOS disk images
;; - "exe" for Windows (NSIS) installers
;; - #f when the path doesn't match a known type.
(define (detect-installer-type p)
  (define p* (if (path? p) p (string->path p)))
  ;; `path-get-extension` returns bytes (or #f), not a path.
  (define ext
    (let ([e (path-get-extension p*)])
      (and e (bytes->string/utf-8 e))))
  (cond
    [(not ext) #f]
    [(string-ci=? ext ".sh") "sh"]
    ;; .tgz is represented as a single extension in installer filenames.
    [(string-ci=? ext ".tgz") "tgz"]
    [(string-ci=? ext ".dmg") "dmg"]
    [(string-ci=? ext ".exe") "exe"]
    [else #f]))

(define (tar-exe) (find-executable-path/default "tar" "/bin/tar"))

(define (installer-cache-path installer-url)
  (build-path (rackup-download-cache-dir)
              (path-basename-string (string->path (last (string-split installer-url "/"))))))

;; Download an installer into the shared download cache, verifying its
;; checksum, and return the cached path.  A cached file whose checksum
;; no longer matches is deleted and redownloaded; `#:no-cache?` forces a
;; redownload.  `#:announce` is called with the URL before downloading.
(define (ensure-installer-cached! installer-url
                                  #:no-cache? [no-cache? #f]
                                  #:sha256 [expected-sha256 #f]
                                  #:sha1 [expected-sha1 #f]
                                  #:announce [announce
                                              (lambda (url)
                                                (displayln (format "Downloading installer: ~a" url)))])
  (ensure-rackup-layout!)
  (require-checksummed-http-installer! installer-url expected-sha256)
  (define cache-path (installer-cache-path installer-url))
  (when (and (file-exists? cache-path) (or expected-sha256 expected-sha1))
    (with-handlers ([exn:fail? (lambda (_) (delete-file cache-path))])
      (verify-installer-checksum! cache-path #:sha256 expected-sha256 #:sha1 expected-sha1)))
  (when (or no-cache? (not (file-exists? cache-path)))
    (announce installer-url)
    (download-url->file installer-url cache-path)
    (verify-installer-checksum! cache-path #:sha256 expected-sha256 #:sha1 expected-sha1)
    (set-file-mode! cache-path #o755))
  cache-path)

;; Extract a .tgz installer archive into install-root.
;; `#:check-label` sets the error-context label; `#:archive-noun` and
;; `#:announce` together drive the progress message ("Extracting <noun>
;; into <dest>") so callers don't repeat the path->complete-path/format
;; dance.
(define (extract-tgz-installer! installer-file install-root
                                #:check-label [check-label 'tgz-installer]
                                #:archive-noun [archive-noun "archive"]
                                #:announce [announce default-announce])
  (define archive (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (announce (format "Extracting ~a into ~a" archive-noun (path->string dest)))
  (make-directory* dest)
  (cond
    ;; Unpack in-process on Windows: tar.exe ships only with Windows 10
    ;; 1803 and later, and `file/untgz` is part of Minimal Racket.
    [(windows?) (untgz archive #:dest dest)]
    [else (system*/check check-label (tar-exe) "-xzf" archive "-C" dest)]))

;; 7-Zip, which can unpack an NSIS installer.  Checked on PATH, then in
;; its default install folders.
(define (seven-zip-exe)
  (or (for/or ([name (in-list '("7z" "7z.exe"))])
        (find-executable-path name))
      (for/or ([var (in-list '("ProgramW6432" "ProgramFiles" "ProgramFiles(x86)"))])
        (define base (getenv var))
        (and base
             (let ([p (build-path base "7-Zip" "7z.exe")])
               (and (file-exists? p) p))))))

;; Unpack a Racket Windows installer (.exe) into install-root without
;; running it.  Running the installer, even silently (/S /D=...), asks for
;; administrator rights and writes machine-wide registry keys, file
;; associations, and Start-menu entries, which clash between side-by-side
;; versions.  The payload is the installation tree itself, so 7-Zip's
;; NSIS reader yields exactly what the installer would copy; only the
;; installer's own plugin files ($PLUGINSDIR) are skipped.
(define (extract-nsis-installer! installer-file install-root
                                 #:check-label [check-label 'nsis-installer]
                                 #:announce [announce default-announce])
  (define exe (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (define 7z
    (or (seven-zip-exe)
        (rackup-error
         (string-append
          "the full Racket distribution for Windows ships only as an .exe installer,\n"
          "which rackup unpacks with 7-Zip, but 7-Zip (7z.exe) was not found.\n"
          "Install 7-Zip (https://www.7-zip.org/, or `winget install 7zip.7zip`),\n"
          "or install Minimal Racket instead: rackup install <version> --distribution minimal"))))
  (announce (format "Extracting installer into ~a" (path->string dest)))
  (make-directory* dest)
  (system*/check check-label 7z "x" "-y" "-bd" "-bso0"
                 (string-append "-o" (path->string dest))
                 "-x!$PLUGINSDIR" (path->string exe)))

;; Mount a DMG, locate the best source directory to copy, copy its contents,
;; then detach the mount.
;;
;; Source selection deliberately skips symlink entries at the DMG root so we
;; don't accidentally copy host paths like /Applications from drag-and-drop
;; style Racket images.
;;
;; `#:attach-label`/`#:copy-label` set error-context labels;
;; `#:source-noun`/`#:announce` drive the "Mounting DMG and extracting
;; <noun> into <dest>" progress message.
(define (install-from-dmg! installer-file install-root
                           #:attach-label [attach-label 'hdiutil-attach]
                           #:copy-label [copy-label 'ditto]
                           #:source-noun [source-noun ""]
                           #:announce [announce default-announce])
  (define dmg (path->complete-path installer-file))
  (define dest (path->complete-path install-root))
  (define mount-point (make-temporary-file "rackup-dmg-~a" 'directory))
  (announce (format "Mounting DMG and extracting~a into ~a"
                    (if (equal? source-noun "") "" (string-append " " source-noun))
                    (path->string dest)))
  (dynamic-wind
   (lambda ()
     (system*/check attach-label
                    (hdiutil-exe) "attach"
                    "-nobrowse" "-noverify" "-noautoopen" "-quiet"
                    "-mountpoint" (path->string* mount-point)
                    (path->string* dmg)))
   (lambda ()
     (define top-dirs
       (for/list ([p (directory-list mount-point #:build? #t)]
                  #:when (and (directory-exists? p)
                              (not (link-exists? p))))
         p))
     (define src-dir
       (cond
         [(for/or ([d (in-list top-dirs)])
            (and (directory-exists? (build-path d "bin")) d))]
         [(directory-exists? (build-path mount-point "bin")) mount-point]
         [(= (length top-dirs) 1) (car top-dirs)]
         [else mount-point]))
     (make-directory* dest)
     (system*/check copy-label (ditto-exe) (path->string* src-dir) (path->string* dest)))
   (lambda ()
     (system* (hdiutil-exe) "detach" (path->string* mount-point) "-quiet")
     (when (directory-exists? mount-point)
       (delete-directory mount-point)))))

;; Discover the installed bin directory under install-root.
;;
;; candidates are checked in order and may be relative strings or paths
;; (e.g., "bin", "racket/bin", "plt/bin").
;;
;; error-label customizes the error text so callers can preserve existing
;; wording (e.g., "Racket" vs "hidden runtime").
;; A Windows installation has no bin/ directory: Racket.exe, raco.exe,
;; and the other launchers sit at the top of the tree.
(define (discover-bin-dir install-root
                          #:candidates [candidates (if (windows?)
                                                       '("racket" ".")
                                                       '("bin" "racket/bin" "plt/bin"))]
                          #:error-label [error-label "Racket"])
  (or (for/or ([c (in-list candidates)])
        (define rel (if (path? c) c (string->path c)))
        (define maybe (simplify-path (apply build-path install-root (explode-path rel)) #f))
        (and (if (windows?)
                 (file-exists? (build-path maybe (exe-file-name "racket")))
                 (directory-exists? maybe))
             maybe))
      (rackup-error "could not find ~a bin dir under ~a" error-label (path->string* install-root))))
