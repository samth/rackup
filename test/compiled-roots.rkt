#lang racket/base

;; Steady-state unit tests for the per-installation compiled-dir key and
;; the config.rktd writer that isolates a linked toolchain's compiled
;; output.  The upgrade/migration path (link/rebuild flipping a toolchain
;; to keyed-only) is exercised in test/rebuild.rkt.

(require rackunit
         racket/file
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/state.rkt")

(define (with-temp-dir proc)
  (define dir (make-temporary-file "rackup-croots-test~a" 'directory))
  (dynamic-wind void
                (lambda () (proc dir))
                (lambda () (delete-directory/files dir #:must-exist? #f))))

(module+ test
  ;; --- compiled-roots-key -------------------------------------------------
  ;; Linked toolchain: keyed on installation name (version-independent).
  (check-equal? (compiled-roots-key "9.99" 'cs "dev") "compiled/cs-local-dev")
  (check-equal? (compiled-roots-key #f 'cs "dev")
                "compiled/cs-local-dev"
                "linked key ignores the (drifting) version")
  ;; Installer toolchain: keyed on version+variant.
  (check-equal? (compiled-roots-key "9.1" 'cs #f) "compiled/9.1-cs")
  ;; local-name but unknown variant -> name-only key.
  (check-equal? (compiled-roots-key #f 'unknown "dev") "compiled/local-dev")
  ;; Not enough to form a stable installer key.
  (check-equal? (compiled-roots-key "9.1" 'unknown #f) #f)
  (check-equal? (compiled-roots-key #f #f #f) #f)

  ;; --- compiled-roots-value ----------------------------------------------
  ;; keyed-only: a single root, no `.` fallback.
  (check-equal? (compiled-roots-value "9.99" 'cs '(same) "dev" #:keyed-only? #t)
                "compiled/cs-local-dev")
  ;; keyed-only ignores existing roots entirely (no fallback of any kind).
  (check-equal? (compiled-roots-value "9.99" 'cs '("/usr/lib/racket/compiled") "dev" #:keyed-only? #t)
                "compiled/cs-local-dev")
  ;; legacy: key plus the `.` fallback.
  (check-equal? (compiled-roots-value "9.99" 'cs '(same) "dev") "compiled/cs-local-dev:.")
  ;; installer: version+variant key plus fallback (unchanged behavior).
  (check-equal? (compiled-roots-value "9.1" 'cs '(same) #f) "compiled/9.1-cs:.")
  ;; keyed-only with no derivable key -> #f (no PLTCOMPILEDROOTS emitted).
  (check-equal? (compiled-roots-value #f 'unknown '(same) #f #:keyed-only? #t) #f)

  ;; --- toolchain-env-var-entries -----------------------------------------
  (check-equal? (toolchain-env-var-entries "/addon" "9.99" 'cs '(same) "dev" #:keyed-only? #t)
                (list (cons "PLTADDONDIR" "/addon")
                      (cons "PLTCOMPILEDROOTS" "compiled/cs-local-dev")))
  (check-equal? (toolchain-env-var-entries "/addon" "9.99" 'cs '(same) "dev")
                (list (cons "PLTADDONDIR" "/addon")
                      (cons "PLTCOMPILEDROOTS" "compiled/cs-local-dev:.")))

  ;; --- set-toolchain-compiled-file-roots! --------------------------------
  (define (config-path root)
    (build-path root "racket" "etc" "config.rktd"))
  (define (bin-dir root)
    (build-path root "racket" "bin"))
  (define roots '("compiled/cs-local-dev"))

  ;; Fresh tree (no config.rktd): writes it.
  (with-temp-dir (lambda (root)
                   (make-directory* (bin-dir root))
                   (check-equal? (set-toolchain-compiled-file-roots! (bin-dir root) roots) 'written)
                   (define cfg (read-rktd-file (config-path root) #f))
                   (check-true (hash? cfg))
                   (check-equal? (hash-ref cfg 'compiled-file-roots #f) roots)
                   ;; Idempotent second call.
                   (check-equal? (set-toolchain-compiled-file-roots! (bin-dir root) roots)
                                 'unchanged)))

  ;; Preserves other keys.
  (with-temp-dir (lambda (root)
                   (make-directory* (build-path root "racket" "etc"))
                   (write-rktd-file (config-path root) (hash 'catalogs '("https://example.invalid")))
                   (check-equal? (set-toolchain-compiled-file-roots! (bin-dir root) roots) 'written)
                   (define cfg (read-rktd-file (config-path root) #f))
                   (check-equal? (hash-ref cfg 'catalogs #f) '("https://example.invalid"))
                   (check-equal? (hash-ref cfg 'compiled-file-roots #f) roots)))

  ;; Overwrites the default (same).
  (with-temp-dir
   (lambda (root)
     (make-directory* (build-path root "racket" "etc"))
     (write-rktd-file (config-path root) (hash 'compiled-file-roots '(same)))
     (check-equal? (set-toolchain-compiled-file-roots! (bin-dir root) roots) 'written)
     (check-equal? (hash-ref (read-rktd-file (config-path root) #f) 'compiled-file-roots #f) roots)))

  ;; Refuses to clobber a user's custom value.
  (with-temp-dir
   (lambda (root)
     (make-directory* (build-path root "racket" "etc"))
     (write-rktd-file (config-path root) (hash 'compiled-file-roots '("/custom/abs")))
     (check-equal? (set-toolchain-compiled-file-roots! (bin-dir root) roots) 'refused)
     (check-equal? (hash-ref (read-rktd-file (config-path root) #f) 'compiled-file-roots #f)
                   '("/custom/abs")))))
