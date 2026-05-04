#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "error.rkt"
         "process.rkt"
         "text.rkt")

(provide detect-installer-type
         extract-tgz-installer!
         install-from-dmg!
         discover-bin-dir)

(define (default-announce msg) (displayln msg))

(define (hdiutil-exe) (find-executable-path/default "hdiutil" "/usr/bin/hdiutil"))
(define (ditto-exe)   (find-executable-path/default "ditto"   "/usr/bin/ditto"))

;; Return installer type from a filename/path:
;; - "sh" for shell installers
;; - "tgz" for gzip-compressed tar archives
;; - "dmg" for macOS disk images
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
    [else #f]))

(define (tar-exe) (find-executable-path/default "tar" "/bin/tar"))

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
  (system*/check check-label (tar-exe) "-xzf" archive "-C" dest))

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
(define (discover-bin-dir install-root
                          #:candidates [candidates '("bin" "racket/bin" "plt/bin")]
                          #:error-label [error-label "Racket"])
  (or (for/or ([c (in-list candidates)])
        (define rel (if (path? c) c (string->path c)))
        (define maybe (apply build-path install-root (explode-path rel)))
        (and (directory-exists? maybe) maybe))
      (rackup-error "could not find ~a bin dir under ~a" error-label (path->string* install-root))))
