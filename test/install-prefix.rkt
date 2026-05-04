#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt")

(define (with-temp-home proc)
  (define tmp (make-temporary-file "rackup-prefix-test~a" 'directory))
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

(module+ test
  ;; resolve-toolchain-prefix
  (check-false (resolve-toolchain-prefix #f))
  (check-false (resolve-toolchain-prefix ""))
  (check-false (resolve-toolchain-prefix "   "))
  (check-true (absolute-path? (resolve-toolchain-prefix "/tmp/rackup-tc")))
  (check-equal? (path->string (resolve-toolchain-prefix "/tmp/rackup-tc"))
                "/tmp/rackup-tc")
  (check-exn #px"control characters"
             (lambda () (resolve-toolchain-prefix "/tmp/foo\nbar")))
  ;; A path that exists but is a regular file is rejected.
  (define tmp-file (make-temporary-file "rackup-prefix-file-~a"))
  (dynamic-wind void
                (lambda ()
                  (check-exn #px"prefix exists and is not a directory"
                             (lambda () (resolve-toolchain-prefix
                                         (path->string tmp-file)))))
                (lambda () (delete-file tmp-file)))

  ;; delete-toolchain-dir! for plain dirs
  (with-temp-home
   (lambda (_)
     (ensure-rackup-layout!)
     (define tc-dir (rackup-toolchain-dir "fake-plain"))
     (delete-toolchain-dir! tc-dir)             ; idempotent no-op
     (make-directory* tc-dir)
     (write-string-file (build-path tc-dir "marker") "x")
     (delete-toolchain-dir! tc-dir)
     (check-false (directory-exists? tc-dir))))

  ;; delete-toolchain-dir! for --prefix symlinks: cleans up both the
  ;; link and the prefix target.
  (with-temp-home
   (lambda (tmp-home)
     (ensure-rackup-layout!)
     (define tc-dir (rackup-toolchain-dir "fake-prefixed"))
     (define real (build-path tmp-home "alt-prefix" "fake-prefixed"))
     (make-directory* real)
     (write-string-file (build-path real "marker") "y")
     (make-file-or-directory-link real tc-dir)

     (delete-toolchain-dir! tc-dir)

     (check-false (link-exists? tc-dir))
     (check-false (directory-exists? real)
                  "delete-toolchain-dir! should remove the prefix target too")))

  ;; A dangling --prefix symlink (target wiped, e.g., /tmp cleared):
  ;; delete-toolchain-dir! removes the dangling link without error.
  (with-temp-home
   (lambda (tmp-home)
     (ensure-rackup-layout!)
     (define tc-dir (rackup-toolchain-dir "fake-dangling"))
     (define real (build-path tmp-home "alt-prefix" "fake-dangling"))
     (make-directory* real)
     (make-file-or-directory-link real tc-dir)
     (delete-directory/files (build-path tmp-home "alt-prefix"))

     (check-false (directory-exists? tc-dir))
     (check-true (link-exists? tc-dir))

     (delete-toolchain-dir! tc-dir)
     (check-false (link-exists? tc-dir))))

  ;; remove-toolchain! works on a registered --prefix-installed
  ;; toolchain: deletes the link, the link target, and the addon dir,
  ;; and unregisters from the index.
  (with-temp-home
   (lambda (tmp-home)
     (ensure-rackup-layout!)
     (ensure-index!)
     (define id "release-9.1-cs-x86_64-linux-full")
     (define tc-dir (rackup-toolchain-dir id))
     (define prefix (build-path tmp-home "alt-prefix"))
     (define real (build-path prefix id))
     (define real-bin (build-path real "install" "bin"))
     (make-directory* real-bin)
     (write-string-file (build-path real-bin "racket") "#!/bin/sh\nexit 0\n")
     (file-or-directory-permissions (build-path real-bin "racket") #o755)
     (make-file-or-directory-link real tc-dir)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))
     (define addon (rackup-addon-dir id))
     (make-directory* addon)
     (with-state-lock
      (register-toolchain!
       id
       (hash 'id id
             'kind 'release
             'requested-spec "stable"
             'resolved-version "9.1"
             'variant 'cs
             'distribution 'full
             'arch "x86_64"
             'platform "linux"
             'toolchain-prefix (path->string prefix)
             'executables '("racket")
             'installed-at "2026-05-01T00:00:00Z")))

     (parameterize ([current-output-port (open-output-string)])
       (remove-toolchain! id))

     (check-false (link-exists? tc-dir))
     (check-false (directory-exists? real)
                  "remove-toolchain! should remove the prefix target")
     (check-false (directory-exists? addon))
     (check-false (toolchain-exists? id)))))
