#lang racket/base

;; Steady-state unit tests for the per-installation compiled-dir key and
;; for undoing the keyed-only config.rktd entry that older rackup versions
;; wrote.  The upgrade path and rebuild's purge of stale keyed dirs are
;; exercised in test/compiled-roots-migration.rkt.

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
  ;; key plus the `.` fallback.
  (check-equal? (compiled-roots-value "9.99" 'cs '(same) "dev") "compiled/cs-local-dev:.")
  ;; a config.rktd that still names the key: no doubled key.
  (check-equal? (compiled-roots-value "9.99" 'cs '("compiled/cs-local-dev") "dev")
                "compiled/cs-local-dev:.")
  ;; installer: version+variant key plus fallback (unchanged behavior).
  (check-equal? (compiled-roots-value "9.1" 'cs '(same) #f) "compiled/9.1-cs:.")
  ;; no derivable key -> #f (no PLTCOMPILEDROOTS emitted).
  (check-equal? (compiled-roots-value #f 'unknown '(same) #f) #f)

  ;; --- toolchain-env-var-entries -----------------------------------------
  (check-equal? (toolchain-env-var-entries "/addon" "9.99" 'cs '(same) "dev")
                (list (cons "PLTADDONDIR" "/addon")
                      (cons "PLTCOMPILEDROOTS" "compiled/cs-local-dev:.")))

  ;; --- unset-toolchain-compiled-file-roots! ------------------------------
  (define (config-path root)
    (build-path root "racket" "etc" "config.rktd"))
  (define (bin-dir root)
    (build-path root "racket" "bin"))
  (define roots '("compiled/cs-local-dev"))
  (define (write-config! root cfg)
    (make-directory* (build-path root "racket" "etc"))
    (write-rktd-file (config-path root) cfg))

  ;; No config.rktd: nothing to do.
  (with-temp-dir (lambda (root)
                   (make-directory* (bin-dir root))
                   (check-false (unset-toolchain-compiled-file-roots! (bin-dir root) roots))
                   (check-false (file-exists? (config-path root)))))

  ;; Removes the keyed entry and preserves other keys; idempotent.
  (with-temp-dir (lambda (root)
                   (write-config! root (hash 'compiled-file-roots roots
                                             'catalogs '("https://example.invalid")))
                   (check-true (unset-toolchain-compiled-file-roots! (bin-dir root) roots))
                   (define cfg (read-rktd-file (config-path root) #f))
                   (check-false (hash-ref cfg 'compiled-file-roots #f))
                   (check-equal? (hash-ref cfg 'catalogs #f) '("https://example.invalid"))
                   (check-false (unset-toolchain-compiled-file-roots! (bin-dir root) roots))))

  ;; Leaves a user's own value alone.
  (for ([custom (in-list '(("/custom/abs") (same) ("compiled/cs-local-dev" same)))])
    (with-temp-dir
     (lambda (root)
       (write-config! root (hash 'compiled-file-roots custom))
       (check-false (unset-toolchain-compiled-file-roots! (bin-dir root) roots))
       (check-equal? (hash-ref (read-rktd-file (config-path root) #f) 'compiled-file-roots #f)
                     custom)))))
