#lang racket/base

(require rackunit
         racket/path
         "../libexec/rackup/paths.rkt")

(define (with-temp-rackup-home proc)
  (define tmp (make-temporary-file "rackup-paths-test~a" 'directory))
  (define old-home (getenv "RACKUP_HOME"))
  (dynamic-wind (lambda () (putenv "RACKUP_HOME" (path->string tmp)))
                (lambda () (proc tmp))
                (lambda ()
                  (if old-home
                      (putenv "RACKUP_HOME" old-home)
                      (putenv "RACKUP_HOME" ""))
                  (delete-directory/files tmp #:must-exist? #f))))

(module+ test
  (with-temp-rackup-home
   (lambda (tmp)
     (check-equal? (rackup-state-dir) (build-path tmp "state"))
     (check-equal? (rackup-toolchains-dir) (build-path tmp "toolchains"))
     (check-equal? (rackup-addons-dir) (build-path tmp "addons"))
     (check-equal? (rackup-shims-dir) (build-path tmp "shims"))
     (check-equal? (rackup-runtime-dir) (build-path tmp "runtime"))
     (check-equal? (rackup-runtime-current-bin-dir)
                   (build-path tmp "runtime" "current" "bin"))
     (check-equal? (rackup-runtime-current-racket)
                   (build-path tmp "runtime" "current" "bin" "racket"))
     (check-equal? (rackup-legacy-config-file) (build-path tmp "state" "config.rktd"))
     (check-equal? (rackup-legacy-shim-aliases-file) (build-path tmp "state" "shim-aliases"))
     (check-equal? (rackup-shim-path "racket") (build-path tmp "shims" "racket"))
     (check-equal? (rackup-toolchain-exe-path "stable" "racket")
                   (build-path tmp "toolchains" "stable" "bin" "racket")))))

