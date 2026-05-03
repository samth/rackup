#lang racket/base

(require racket/file
         racket/path
         "util.rkt")

(provide running-as-exe?
         rackup-home
         rackup-bin-dir
         rackup-libexec-dir
         rackup-shims-dir
         rackup-shell-dir
         rackup-toolchains-dir
         rackup-addons-dir
         rackup-cache-dir
         rackup-download-cache-dir
         rackup-state-dir
         rackup-runtime-dir
         rackup-runtime-addon-dir
         rackup-runtime-versions-dir
         rackup-runtime-current-link
         rackup-runtime-current-bin-dir
         rackup-runtime-current-racket
         rackup-runtime-lock-dir
         rackup-state-lock-dir
         rackup-runtime-version-dir
         rackup-runtime-install-dir
         rackup-runtime-meta-file
         rackup-runtime-bin-link
         rackup-index-file
         rackup-config-file
         rackup-legacy-config-file
         rackup-legacy-shim-aliases-file
         rackup-default-file
         rackup-shim-dispatcher
         rackup-shim-path
         rackup-bin-entry
         rackup-shell-script
         rackup-toolchain-dir
         rackup-toolchain-install-dir
         rackup-toolchain-meta-file
         rackup-toolchain-bin-link
         rackup-toolchain-exe-path
         rackup-toolchain-env-file
         rackup-addon-dir
         ensure-rackup-layout!)

;; True when rackup was installed as a prebuilt raco-exe binary.
;; Detected once (on first call) by checking for the compiled rackup-core
;; executable next to the shell wrapper.  The result is cached so that
;; the mode cannot flip mid-session; self-upgrade exits afterward anyway.
(define running-as-exe-cache (box 'unset))
(define (running-as-exe?)
  (define v (unbox running-as-exe-cache))
  (cond
    [(eq? v 'unset)
     (define result (executable-file? (build-path (rackup-bin-dir) "rackup-core")))
     (set-box! running-as-exe-cache result)
     result]
    [else v]))

(define (rackup-home)
  (define env (getenv "RACKUP_HOME"))
  (define home
    (if (and env (not (string-blank? env)))
        (string->path env)
        (build-path (find-system-path 'home-dir) ".rackup")))
  (ensure-path-without-control-chars! home "RACKUP_HOME")
  home)

(define (rackup-bin-dir)
  (build-path (rackup-home) "bin"))
(define (rackup-libexec-dir)
  (build-path (rackup-home) "libexec"))
(define (rackup-shims-dir)
  (build-path (rackup-home) "shims"))
(define (rackup-shell-dir)
  (build-path (rackup-home) "shell"))
(define (rackup-toolchains-dir)
  (build-path (rackup-home) "toolchains"))
(define (rackup-addons-dir)
  (build-path (rackup-home) "addons"))
(define (rackup-cache-dir)
  (build-path (rackup-home) "cache"))
(define (rackup-download-cache-dir)
  (build-path (rackup-cache-dir) "downloads"))
(define (rackup-state-dir)
  (build-path (rackup-home) "state"))
(define (rackup-runtime-dir)
  (build-path (rackup-home) "runtime"))
(define (rackup-runtime-addon-dir)
  (build-path (rackup-runtime-dir) "addon"))
(define (rackup-runtime-versions-dir)
  (build-path (rackup-runtime-dir) "versions"))
(define (rackup-runtime-current-link)
  (build-path (rackup-runtime-dir) "current"))
(define (rackup-runtime-current-bin-dir)
  (build-path (rackup-runtime-current-link) "bin"))
(define (rackup-runtime-current-racket)
  (build-path (rackup-runtime-current-bin-dir) "racket"))
(define (rackup-runtime-lock-dir)
  (build-path (rackup-runtime-dir) ".lock"))
(define (rackup-state-lock-dir)
  (build-path (rackup-state-dir) ".lock"))

(define (rackup-runtime-version-dir id)
  (build-path (rackup-runtime-versions-dir) id))
(define (rackup-runtime-install-dir id)
  (build-path (rackup-runtime-version-dir id) "install"))
(define (rackup-runtime-meta-file id)
  (build-path (rackup-runtime-version-dir id) "meta.rktd"))
(define (rackup-runtime-bin-link id)
  (build-path (rackup-runtime-version-dir id) "bin"))

(define (rackup-index-file)
  (build-path (rackup-state-dir) "index.rktd"))
(define (rackup-config-file)
  (build-path (rackup-state-dir) "config"))
(define (rackup-legacy-config-file)
  (build-path (rackup-state-dir) "config.rktd"))
(define (rackup-legacy-shim-aliases-file)
  (build-path (rackup-state-dir) "shim-aliases"))
(define (rackup-default-file)
  (build-path (rackup-state-dir) "default-toolchain"))

(define (rackup-shim-dispatcher)
  (build-path (rackup-libexec-dir) "rackup-shim"))
(define (rackup-shim-path name)
  (build-path (rackup-shims-dir) name))
(define (rackup-bin-entry)
  (build-path (rackup-bin-dir) "rackup"))
(define (rackup-shell-script shell-name)
  (build-path (rackup-shell-dir) (format "rackup.~a" shell-name)))

(define (rackup-toolchain-dir id)
  (build-path (rackup-toolchains-dir) id))
(define (rackup-toolchain-install-dir id)
  (build-path (rackup-toolchain-dir id) "install"))
(define (rackup-toolchain-meta-file id)
  (build-path (rackup-toolchain-dir id) "meta.rktd"))
(define (rackup-toolchain-bin-link id)
  (build-path (rackup-toolchain-dir id) "bin"))
(define (rackup-toolchain-exe-path id exe)
  (build-path (rackup-toolchain-bin-link id) exe))
(define (rackup-toolchain-env-file id)
  (build-path (rackup-toolchain-dir id) "env.sh"))
(define (rackup-addon-dir id)
  (build-path (rackup-addons-dir) id))

(define (ensure-rackup-layout!)
  (define base-dirs
    (list (rackup-home)
          (rackup-bin-dir)
          (rackup-libexec-dir)
          (rackup-shims-dir)
          (rackup-shell-dir)
          (rackup-toolchains-dir)
          (rackup-addons-dir)
          (rackup-download-cache-dir)
          (rackup-state-dir)))
  ;; Only create hidden runtime directories when not running as a
  ;; prebuilt exe (the exe embeds its own Racket runtime).
  (define dirs
    (if (running-as-exe?)
        base-dirs
        (append base-dirs
                (list (rackup-runtime-dir)
                      (rackup-runtime-addon-dir)
                      (rackup-runtime-versions-dir)))))
  (for ([p dirs])
    (ensure-directory* p)))
