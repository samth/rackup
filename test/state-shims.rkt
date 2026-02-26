#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt")

(define (with-temp-rackup-home proc)
  (define tmp (make-temporary-file "rackup-test~a" 'directory))
  (define old-home (getenv "RACKUP_HOME"))
  (dynamic-wind
   (lambda ()
     (putenv "RACKUP_HOME" (path->string tmp)))
   (lambda ()
     (proc tmp))
   (lambda ()
     (if old-home
         (putenv "RACKUP_HOME" old-home)
         (putenv "RACKUP_HOME" ""))
     (delete-directory/files tmp #:must-exist? #f))))

(module+ test
  (with-temp-rackup-home
   (lambda (tmp)
     (ensure-index!)
     (check-true (directory-exists? (rackup-home)))
     (check-equal? (installed-toolchain-ids) null)

     (define id "release-8.18-cs-x86_64-linux-full")
     (define tc-dir (rackup-toolchain-dir id))
     (define install-root (rackup-toolchain-install-dir id))
     (define real-bin (build-path install-root "bin"))
     (make-directory* real-bin)
     (define racket-exe (build-path real-bin "racket"))
     (write-string-file racket-exe "#!/usr/bin/env bash\necho test\n")
     (file-or-directory-permissions racket-exe #o755)
     (make-file-or-directory-link real-bin (rackup-toolchain-bin-link id))

     (define meta
       (hash 'id id
             'kind 'release
             'requested-spec "stable"
             'resolved-version "8.18"
             'variant 'cs
             'distribution 'full
             'arch "x86_64"
             'platform "linux"
             'snapshot-site #f
             'snapshot-stamp #f
             'installer-url "https://example.invalid/racket.sh"
             'installer-filename "racket.sh"
             'install-root (path->string install-root)
             'bin-link (path->string (rackup-toolchain-bin-link id))
             'real-bin-dir (path->string real-bin)
             'executables '("racket")
             'installed-at "2026-02-26T00:00:00Z"))
     (register-toolchain! id meta)
     (check-equal? (get-default-toolchain) id)
     (check-equal? (find-local-toolchain "release-8.18") id)
     (check-equal? (path->string (resolve-executable-path "racket"))
                   (path->string (build-path (rackup-toolchain-bin-link id) "racket")))

     (reshim!)
     (check-true (link-exists? (build-path (rackup-shims-dir) "racket")))
     (check-true (link-exists? (build-path (rackup-shims-dir) "rackup"))))))
