#lang racket/base

;; detect-local-source-layout finds a checkout's source root however the
;; tree is linked: the checkout root, its `racket/` subdirectory (with or
;; without `./` or a trailing slash), or its `racket/bin`.  Regression: a
;; linked `<checkout>/racket` lost its source root, so `rackup rebuild`
;; reported "points at an installed prefix".

(require rackunit
         racket/file
         racket/path
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/rebuild.rkt")

(define (make-checkout! root)
  (make-directory* (build-path root "racket" "bin"))
  (make-directory* (build-path root "racket" "collects"))
  (make-directory* (build-path root "pkgs"))
  (with-output-to-file (build-path root "Makefile") void))

(define (dir-string p)
  (path->string (path->directory-path (simplify-path p))))

(module+ test
  (define tmp (make-temporary-file "rackup-layout-~a" 'directory))
  (define root (build-path tmp "plt"))
  (make-checkout! root)
  (define root-str (dir-string root))
  (define plthome-str (dir-string (build-path root "racket")))

  (for ([input (in-list (list (path->string root)
                              (path->string (build-path root "racket"))
                              (string-append (path->string root) "/./racket")
                              (string-append (path->string root) "/racket/")
                              (path->string (build-path root "racket" "bin"))))])
    (define layout (detect-local-source-layout input))
    (check-equal? (dir-string (hash-ref layout 'source-root))
                  root-str
                  (format "source root for ~a" input))
    (check-equal? (dir-string (hash-ref layout 'plthome)) plthome-str (format "plthome for ~a" input))
    (check-equal? (hash-ref (rebuild-plan layout) 'kind)
                  'package-based
                  (format "rebuild runs make at the checkout root for ~a" input)))

  ;; A tree without `pkgs/` next to `racket/` is not a checkout: no source root.
  (define bare (build-path tmp "bare"))
  (make-directory* (build-path bare "racket" "bin"))
  (make-directory* (build-path bare "racket" "collects"))
  (check-false (hash-ref (detect-local-source-layout (path->string (build-path bare "racket")))
                         'source-root))

  (delete-directory/files tmp))
