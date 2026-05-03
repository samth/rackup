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
         rackup-runtime-lock-dir
         rackup-state-lock-dir
         rackup-runtime-version-dir
         rackup-runtime-install-dir
         rackup-runtime-meta-file
         rackup-runtime-bin-link
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

(define-syntax-rule (define-home-subpaths [name segment ...] ...)
  (begin
    (define (name)
      (build-path (rackup-home) segment ...))
    ...))

(define-home-subpaths
  [rackup-bin-dir "bin"]
  [rackup-libexec-dir "libexec"]
  [rackup-shims-dir "shims"]
  [rackup-shell-dir "shell"]
  [rackup-toolchains-dir "toolchains"]
  [rackup-addons-dir "addons"]
  [rackup-cache-dir "cache"]
  [rackup-download-cache-dir "cache" "downloads"]
  [rackup-state-dir "state"]
  [rackup-runtime-dir "runtime"]
  [rackup-runtime-addon-dir "runtime" "addon"]
  [rackup-runtime-versions-dir "runtime" "versions"]
  [rackup-runtime-current-link "runtime" "current"]
  [rackup-runtime-lock-dir "runtime" ".lock"]
  [rackup-state-lock-dir "state" ".lock"])

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
(define (rackup-default-file)
  (build-path (rackup-state-dir) "default-toolchain"))

(define (rackup-shim-dispatcher)
  (build-path (rackup-libexec-dir) "rackup-shim"))
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
