#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt"
         "../libexec/rackup/versioning.rkt"
         (only-in (submod "../libexec/rackup/install.rkt" for-testing)
                  parse-pkg-show-output
                  meta->upgrade-spec))

;; ---------------------------------------------------------------------------
;; parse-pkg-show-output

(module+ test
  (check-equal? (parse-pkg-show-output #f) null)
  (check-equal? (parse-pkg-show-output "") null)
  (check-equal? (parse-pkg-show-output " [none]") null)

  (check-equal?
   (parse-pkg-show-output
    (string-append
     " Package                    Checksum          Source\n"
     " foo                        abc123def...      catalog...foo\n"
     " bar-lib                    789xyz456...      catalog...bar\n"))
   '("foo" "bar-lib"))

  (check-equal?
   (parse-pkg-show-output
    " Package  Checksum  Source\n foo  abc  cat\n")
   '("foo"))

  ;; ---------------------------------------------------------------------------
  ;; meta->upgrade-spec

  (check-equal? (meta->upgrade-spec (hash 'kind 'stable)) "stable")
  (check-equal? (meta->upgrade-spec (hash 'kind 'pre-release)) "pre-release")
  (check-equal? (meta->upgrade-spec (hash 'kind 'snapshot 'snapshot-site #f))
                "snapshot")
  (check-equal? (meta->upgrade-spec (hash 'kind 'snapshot 'snapshot-site 'auto))
                "snapshot")
  (check-equal? (meta->upgrade-spec (hash 'kind 'snapshot 'snapshot-site 'utah))
                "snapshot:utah")
  (check-equal? (meta->upgrade-spec (hash 'kind 'snapshot 'snapshot-site 'northwestern))
                "snapshot:northwestern")
  (check-equal? (meta->upgrade-spec (hash 'kind 'release)) #f)
  (check-equal? (meta->upgrade-spec (hash 'kind 'local)) #f)

  ;; ---------------------------------------------------------------------------
  ;; upgradeable-toolchains filtering

  (define (with-temp-rackup-home proc)
    (define tmp (make-temporary-file "rackup-test~a" 'directory))
    (define old-home (getenv "RACKUP_HOME"))
    (define old-testing (getenv "RACKUP_TESTING"))
    (dynamic-wind (lambda ()
                    (putenv "RACKUP_HOME" (path->string tmp))
                    (putenv "RACKUP_TESTING" "1"))
                  (lambda () (proc tmp))
                  (lambda ()
                    (if old-home
                        (putenv "RACKUP_HOME" old-home)
                        (putenv "RACKUP_HOME" ""))
                    (if old-testing
                        (putenv "RACKUP_TESTING" old-testing)
                        (putenv "RACKUP_TESTING" ""))
                    (delete-directory/files tmp #:must-exist? #f))))

  (define (fake-toolchain! id meta)
    (define tc-dir (rackup-toolchain-dir id))
    (make-directory* tc-dir)
    (with-state-lock (register-toolchain! id meta)))

  (define (make-meta id kind #:requested-spec [spec "stable"]
                     #:version [ver "9.1"]
                     #:snapshot-site [ss #f]
                     #:snapshot-stamp [stamp #f])
    (hash 'id id
          'kind kind
          'requested-spec spec
          'resolved-version ver
          'variant 'cs
          'distribution 'full
          'arch "x86_64"
          'platform "linux"
          'snapshot-site ss
          'snapshot-stamp stamp
          'installer-url "http://example.com/test.sh"
          'installer-filename "test.sh"
          'installer-sha256 #f
          'install-root (path->string (rackup-toolchain-install-dir id))
          'bin-link (path->string (rackup-toolchain-bin-link id))
          'real-bin-dir "/tmp/fake-bin"
          'env-vars null
          'executables '("racket" "raco")
          'installed-at "2026-01-01T00:00:00Z"))

  (with-temp-rackup-home
   (lambda (_tmp)
     (ensure-index!)

     ;; Register some toolchains
     (define stable-id "release-9.1-cs-x86_64-linux-full")
     (define release-id "release-8.18-cs-x86_64-linux-full")
     (define pre-id "pre-9.2-cs-x86_64-linux-full")
     (define snap-id "snapshot-utah-20260301-abc-9.2.0.1-cs-x86_64-linux-full")

     (fake-toolchain! stable-id
                      (make-meta stable-id 'stable
                                 #:requested-spec "stable"
                                 #:version "9.1"))
     (fake-toolchain! release-id
                      (make-meta release-id 'release
                                 #:requested-spec "8.18"
                                 #:version "8.18"))
     (fake-toolchain! pre-id
                      (make-meta pre-id 'pre-release
                                 #:requested-spec "pre-release"
                                 #:version "9.2"))
     (fake-toolchain! snap-id
                      (make-meta snap-id 'snapshot
                                 #:requested-spec "snapshot"
                                 #:version "9.2.0.1"
                                 #:snapshot-site 'utah
                                 #:snapshot-stamp "20260301-abc"))

     ;; upgradeable-toolchains with no filter returns stable, pre-release, snapshot
     (define all-upgradeable (upgradeable-toolchains))
     (check-equal? (length all-upgradeable) 3)
     (define all-ids (map car all-upgradeable))
     (check-not-false (member stable-id all-ids))
     (check-not-false (member pre-id all-ids))
     (check-not-false (member snap-id all-ids))
     (check-false (member release-id all-ids))

     ;; Filter by "stable"
     (define stable-only (upgradeable-toolchains "stable"))
     (check-equal? (length stable-only) 1)
     (check-equal? (caar stable-only) stable-id)

     ;; Filter by "pre-release"
     (define pre-only (upgradeable-toolchains "pre-release"))
     (check-equal? (length pre-only) 1)
     (check-equal? (caar pre-only) pre-id)

     ;; Filter by "pre" (alias)
     (define pre-alias (upgradeable-toolchains "pre"))
     (check-equal? (length pre-alias) 1)

     ;; Filter by "snapshot"
     (define snap-only (upgradeable-toolchains "snapshot"))
     (check-equal? (length snap-only) 1)
     (check-equal? (caar snap-only) snap-id)

     ;; Filter by non-existent channel
     (define none (upgradeable-toolchains "nonexistent"))
     (check-equal? (length none) 0))))
