#lang racket/base

(require racket/file
         racket/path
         "fs.rkt"
         "process.rkt"
         "security.rkt"
         "text.rkt")

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
  [rackup-runtime-current-bin-dir "runtime" "current" "bin"]
  [rackup-runtime-current-racket "runtime" "current" "bin" "racket"]
  [rackup-runtime-lock-dir "runtime" ".lock"]
  [rackup-state-lock-dir "state" ".lock"])

;; (define-paths-under base-expr [name segment ...] ...) is shorthand for
;;   (define (name) (build-path base-expr segment ...)) ...
(define-syntax-rule (define-paths-under base-expr [name segment ...] ...)
  (begin
    (define (name) (build-path base-expr segment ...))
    ...))

;; (define-paths-by-id (base-expr id) [name segment ...] ...) is
;; shorthand for `(define (name id) (build-path base-expr segment ...))
;; ...`, where the `id` token in `base-expr` is the same one bound for
;; each generated function.
(define-syntax-rule (define-paths-by-id (base-expr id) [name segment ...] ...)
  (begin
    (define (name id) (build-path base-expr segment ...))
    ...))

(define (rackup-runtime-version-dir id)
  (build-path (rackup-runtime-versions-dir) id))
(define-paths-by-id ((rackup-runtime-version-dir id) id)
  [rackup-runtime-install-dir "install"]
  [rackup-runtime-meta-file   "meta.rktd"]
  [rackup-runtime-bin-link    "bin"])

(define-paths-under (rackup-state-dir)
  [rackup-index-file                "index.rktd"]
  [rackup-config-file               "config"]
  [rackup-legacy-config-file        "config.rktd"]
  [rackup-legacy-shim-aliases-file  "shim-aliases"]
  [rackup-default-file              "default-toolchain"])

(define-paths-under (rackup-libexec-dir) [rackup-shim-dispatcher "rackup-shim"])
(define-paths-under (rackup-bin-dir)     [rackup-bin-entry        "rackup"])

(define (rackup-shim-path name)          (build-path (rackup-shims-dir) name))
(define (rackup-shell-script shell-name) (build-path (rackup-shell-dir) (format "rackup.~a" shell-name)))

(define (rackup-toolchain-dir id)
  (build-path (rackup-toolchains-dir) id))
(define-paths-by-id ((rackup-toolchain-dir id) id)
  [rackup-toolchain-install-dir  "install"]
  [rackup-toolchain-meta-file    "meta.rktd"]
  [rackup-toolchain-bin-link     "bin"]
  [rackup-toolchain-env-file     "env.sh"])

(define (rackup-toolchain-exe-path id exe) (build-path (rackup-toolchain-bin-link id) exe))
(define (rackup-addon-dir id)              (build-path (rackup-addons-dir) id))

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
