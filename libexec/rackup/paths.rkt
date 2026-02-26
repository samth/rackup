#lang racket/base

(require racket/file
         racket/path
         "util.rkt")

(provide rackup-home
         rackup-bin-dir
         rackup-libexec-dir
         rackup-shims-dir
         rackup-shell-dir
         rackup-toolchains-dir
         rackup-addons-dir
         rackup-cache-dir
         rackup-download-cache-dir
         rackup-state-dir
         rackup-index-file
         rackup-config-file
         rackup-default-file
         rackup-shim-dispatcher
         rackup-bin-entry
         rackup-shell-script
         rackup-toolchain-dir
         rackup-toolchain-install-dir
         rackup-toolchain-meta-file
         rackup-toolchain-bin-link
         rackup-addon-dir
         ensure-rackup-layout!)

(define (rackup-home)
  (define env (getenv "RACKUP_HOME"))
  (if (and env (not (string-blank? env)))
      (string->path env)
      (build-path (find-system-path 'home-dir) ".rackup")))

(define (rackup-bin-dir) (build-path (rackup-home) "bin"))
(define (rackup-libexec-dir) (build-path (rackup-home) "libexec"))
(define (rackup-shims-dir) (build-path (rackup-home) "shims"))
(define (rackup-shell-dir) (build-path (rackup-home) "shell"))
(define (rackup-toolchains-dir) (build-path (rackup-home) "toolchains"))
(define (rackup-addons-dir) (build-path (rackup-home) "addons"))
(define (rackup-cache-dir) (build-path (rackup-home) "cache"))
(define (rackup-download-cache-dir) (build-path (rackup-cache-dir) "downloads"))
(define (rackup-state-dir) (build-path (rackup-home) "state"))

(define (rackup-index-file) (build-path (rackup-state-dir) "index.rktd"))
(define (rackup-config-file) (build-path (rackup-state-dir) "config.rktd"))
(define (rackup-default-file) (build-path (rackup-state-dir) "default-toolchain"))

(define (rackup-shim-dispatcher) (build-path (rackup-libexec-dir) "rackup-shim"))
(define (rackup-bin-entry) (build-path (rackup-bin-dir) "rackup"))
(define (rackup-shell-script shell-name)
  (build-path (rackup-shell-dir)
              (format "rackup.~a" shell-name)))

(define (rackup-toolchain-dir id)
  (build-path (rackup-toolchains-dir) id))
(define (rackup-toolchain-install-dir id)
  (build-path (rackup-toolchain-dir id) "install"))
(define (rackup-toolchain-meta-file id)
  (build-path (rackup-toolchain-dir id) "meta.rktd"))
(define (rackup-toolchain-bin-link id)
  (build-path (rackup-toolchain-dir id) "bin"))
(define (rackup-addon-dir id)
  (build-path (rackup-addons-dir) id))

(define (ensure-rackup-layout!)
  (for ([p (list (rackup-home)
                 (rackup-bin-dir)
                 (rackup-libexec-dir)
                 (rackup-shims-dir)
                 (rackup-shell-dir)
                 (rackup-toolchains-dir)
                 (rackup-addons-dir)
                 (rackup-download-cache-dir)
                 (rackup-state-dir))])
    (ensure-directory* p)))
