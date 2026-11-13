#lang racket/base

;; Regression tests for linked source toolchains and stale `.zo` files,
;; run against the real racket binary.
;;
;; A `.zo` written by another Racket version is a hard `version mismatch`
;; error when it is the first one Racket finds; Racket does not skip it or
;; recompile.  A linked source tree's version changes on every `git pull`
;; + `make`, so every compiled root rackup gives a linked toolchain must
;; stay unreachable from a newer binary once it holds old-version `.zo`.
;; Two designs broke this (see docs/plans and issue #101):
;;
;;   - #96's `compiled/cs-local-<name>:.` reused one keyed dir across
;;     versions, so the shim loaded the previous version's `.zo`.
;;   - #98 wrote the key into the tree's racket/etc/config.rktd.  Racket's
;;     own in-place build refreshes only the default `compiled/` (its setup
;;     runs with `-G racket/etc -G build/config/`, and the last config dir
;;     wins), but later build steps run with `-G racket/etc` alone and
;;     loaded stale keyed `.zo`.  This is the failure Matthias hit:
;;       loading code: version mismatch
;;         expected: "9.4.0.3"  found: "9.3.0.10"
;;         in: .../collects/racket/compiled/cs-local-dev/compiled/base_rkt.zo
;;
;; These tests model a version bump by planting `.zo` files whose header
;; names another version in every place an old rackup layout could leave
;; them, next to a fresh `.zo` in the default `compiled/` dir (what the
;; build's `make` refreshes).  They then load the module the two ways a
;; linked tree is used -- through rackup's PLTCOMPILEDROOTS (the shim and
;; `rackup run`) and through the tree's config.rktd alone (Racket's
;; `make`, direct `raco`) -- and require that neither reaches a stale file.

(require rackunit
         racket/file
         racket/port
         racket/string
         racket/system
         (only-in (submod "../libexec/rackup/main.rkt" for-testing) cmd-rebuild)
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/rebuild.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/shims.rkt"
         "../libexec/rackup/state.rkt"
         "../libexec/rackup/state-lock.rkt")

;; ---------------------------------------------------------------------------
;; The real racket

(define racket-exe
  (let ([p (find-system-path 'exec-file)])
    (if (absolute-path? p)
        p
        (or (find-executable-path p) p))))

;; Run the real racket with `args` under `env-overrides` (an alist of
;; name -> value-or-#f).  Returns (values exit-ok? output).
(define (run-racket env-overrides . args)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([v (in-list '(#"PLTCOMPILEDROOTS" #"PLT_ZO_DISABLE"))])
    (environment-variables-set! env v #f))
  (for ([kv (in-list env-overrides)])
    (environment-variables-set! env
                                (string->bytes/utf-8 (car kv))
                                (and (cdr kv) (string->bytes/utf-8 (cdr kv)))))
  (define out (open-output-string))
  (define ok?
    (parameterize ([current-environment-variables env]
                   [current-output-port out]
                   [current-error-port out])
      (apply system* racket-exe args)))
  (values ok? (get-output-string out)))

;; ---------------------------------------------------------------------------
;; Fixtures

(define (write-string-file p s)
  (make-directory* (let-values ([(base name dir?) (split-path p)]) base))
  (with-output-to-file p (lambda () (display s)) #:exists 'replace))

(define (write-script! p body)
  (write-string-file p body)
  (file-or-directory-permissions p #o755))

;; A module with no dependencies outside the kernel, so loading it reads
;; exactly one `.zo` from the tree under test.
(define module-source
  "(module m '#%kernel (#%provide v) (define-values (v) 'fresh))")

(define (module-path tree) (build-path tree "lib" "m.rkt"))
(define (default-zo tree) (build-path tree "lib" "compiled" "m_rkt.zo"))

;; Compile m.rkt into the tree's default `compiled/` dir, as the in-place
;; build's `make` does.
(define (compile-default! tree)
  (write-string-file (module-path tree) module-source)
  (define-values (ok? out)
    (run-racket '() "-N" "raco" "-l-" "raco" "make" (path->string (module-path tree))))
  (unless (and ok? (file-exists? (default-zo tree)))
    (error 'compile-default! "raco make failed:\n~a" out)))

;; A version string of the same length as (version) that differs from it,
;; so the patched header stays well-formed.
(define stale-version
  (let* ([v (version)]
         [last-char (string-ref v (sub1 (string-length v)))])
    (string-append (substring v 0 (sub1 (string-length v)))
                   (if (char=? last-char #\0) "1" "0"))))

;; A copy of `fresh` whose header claims `stale-version`.  A `.zo` starts
;; with `#~`, a length byte, and the version string.
(define (stale-zo-bytes fresh)
  (define v (string->bytes/utf-8 (version)))
  (define n (bytes-length v))
  (unless (and (> (bytes-length fresh) (+ 3 n))
               (equal? (subbytes fresh 0 2) #"#~")
               (= (bytes-ref fresh 2) n)
               (equal? (subbytes fresh 3 (+ 3 n)) v))
    (error 'stale-zo-bytes "unexpected .zo header: ~s" (subbytes fresh 0 (min 16 (bytes-length fresh)))))
  (bytes-append (subbytes fresh 0 3)
                (string->bytes/utf-8 stale-version)
                (subbytes fresh (+ 3 n))))

(define (plant-stale! tree compiled-dir)
  (define dest (build-path tree "lib" compiled-dir "m_rkt.zo"))
  (make-directory* (build-path tree "lib" compiled-dir))
  (call-with-output-file dest
    (lambda (o) (write-bytes (stale-zo-bytes (file->bytes (default-zo tree))) o))
    #:exists 'replace))

;; Every keyed layout an earlier rackup could have left for `key`
;; (e.g. "compiled/cs-local-dev"), relative to a module's directory.
(define (stale-layouts key)
  (list (build-path key "compiled")                ; #96 / #98: no version
        (build-path key stale-version "compiled")  ; another version's dir
        (build-path "compiled" stale-version)))    ; stray version dir

;; Load m.rkt and print its value.
(define (load-args tree)
  (list "-e" (format "(display (dynamic-require (string->path ~s) 'v))"
                     (path->string (module-path tree)))))

(define (check-loads-fresh what ok+out)
  (define-values (ok? out) (apply values ok+out))
  (with-check-info (['output out])
    (check-false (string-contains? out "version mismatch")
                 (format "~a: reached a stale .zo" what))
    (check-true ok? (format "~a: racket failed" what))
    (check-equal? (string-trim out) "fresh" what)))

(define (with-temp-dir proc)
  (define dir (make-temporary-file "rackup-stale-zo~a" 'directory))
  (dynamic-wind void
                (lambda () (proc dir))
                (lambda () (delete-directory/files dir #:must-exist? #f))))

;; A linked "source checkout" whose racket answers rackup's probe with the
;; running version.  The tree's own collects are not real; the modules
;; under test live in <tree>/lib and are loaded with the real racket,
;; using the tree's racket/etc as the config dir exactly as Racket's
;; in-place build does.
(define (make-fake-checkout! root)
  (define bin (build-path root "racket" "bin"))
  (make-directory* (build-path root "racket" "collects"))
  (make-directory* (build-path root "racket" "etc"))
  (make-directory* (build-path root "pkgs"))
  ;; A real git work tree when git is available: rackup chooses the
  ;; compiled-roots scheme for git checkouts by asking git.
  (define git (find-executable-path "git"))
  (unless (and git (parameterize ([current-output-port (open-output-string)]
                                  [current-error-port (open-output-string)])
                     (system* git "init" "-q" (path->string root))))
    (make-directory* (build-path root ".git")))
  (write-string-file (build-path root "Makefile") "")
  (write-script!
   (build-path bin "racket")
   (string-append "#!/usr/bin/env bash\n"
                  "if [[ \"$#\" -ge 2 && \"$1\" == \"-f\" ]]; then\n"
                  (format "  printf '(\"~a\" chez-scheme \"/tmp/x\")'\n" (version))
                  "  exit 0\n"
                  "fi\n"
                  "exit 1\n"))
  (write-script! (build-path bin "raco") "#!/usr/bin/env bash\nexit 0\n"))

(define (with-temp-rackup-home proc)
  (define home (make-temporary-file "rackup-stale-zo-home~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
  (for ([v (in-list '(#"RACKUP_TOOLCHAIN" #"RACKUP_TESTING" #"PLTCOMPILEDROOTS"
                      #"_RACKUP_ORIG_PLTCOMPILEDROOTS"))])
    (environment-variables-set! env v #f))
  (dynamic-wind void
                (lambda ()
                  (parameterize ([current-environment-variables env])
                    (proc home)))
                (lambda () (delete-directory/files home #:must-exist? #f))))

(define (quietly thunk)
  (parameterize ([current-output-port (open-output-string)]
                 [current-error-port (open-output-string)])
    (thunk)))

(define (linked-roots id)
  (cdr (or (assoc "PLTCOMPILEDROOTS" (toolchain-env-vars id))
           (error 'linked-roots "no PLTCOMPILEDROOTS for ~a" id))))

(define (linked-key id)
  (define meta (read-toolchain-meta id))
  (compiled-roots-key (hash-ref meta 'resolved-version #f)
                      (hash-ref meta 'variant #f)
                      (hash-ref meta 'requested-spec #f)))

(define (as-list . vs) vs)

(module+ test
  (with-temp-dir
   (lambda (tree)
     (compile-default! tree)

     ;; --- The fixture reproduces the trap --------------------------------
     ;; If these fail, Racket has started skipping wrong-version `.zo`
     ;; (the Racket-side fix proposed in issue #101); the rest of this file
     ;; then guards a problem that no longer exists, so revisit it.
     (plant-stale! tree (build-path "compiled" "cs-local-dev" "compiled"))
     (let-values ([(ok? out) (apply run-racket
                                    '(("PLTCOMPILEDROOTS" . "compiled/cs-local-dev:."))
                                    (load-args tree))])
       (check-false ok? "the pre-#100 linked roots load the stale .zo")
       (check-true (string-contains? out "version mismatch") out))
     (let ([etc (build-path tree "etc-keyed-only")])
       (write-string-file (build-path etc "config.rktd")
                          "#hash((compiled-file-roots . (\"compiled/cs-local-dev\")))")
       (let-values ([(ok? out) (apply run-racket '()
                                      "-G" (path->string etc) (load-args tree))])
         (check-false ok? "#98's keyed-only config.rktd loads the stale .zo")
         (check-true (string-contains? out "version mismatch") out)))
     ;; And the fresh default `.zo` alone is fine.
     (check-loads-fresh "no roots set" (call-with-values
                                        (lambda () (apply run-racket '() (load-args tree)))
                                        as-list))))

  ;; --- A linked git checkout, as rackup sets it up --------------------------
  ;; Link a checkout, plant stale `.zo` in every old keyed layout, and load
  ;; through rackup's PLTCOMPILEDROOTS (the shim, `rackup run`) and through
  ;; the tree's config dir (`make`, direct raco).
  (define (check-linked-checkout what setup!)
    (with-temp-rackup-home
     (lambda (home)
       (define src (build-path home "plt"))
       (make-fake-checkout! src)
       (quietly (lambda () (link-toolchain! "dev" (path->string src) '("--set-default"))))
       (define id "local-dev")
       (define key (linked-key id))
       (setup! src key id)
       (define tree src)
       (compile-default! tree)
       (for ([layout (in-list (stale-layouts key))])
         (plant-stale! tree layout))
       (define etc (path->string (build-path src "racket" "etc")))
       (check-loads-fresh (format "~a: rackup's PLTCOMPILEDROOTS" what)
                          (call-with-values
                           (lambda ()
                             (apply run-racket (list (cons "PLTCOMPILEDROOTS" (linked-roots id)))
                                    (load-args tree)))
                           as-list))
       (check-loads-fresh (format "~a: the tree's config dir (make, direct raco)" what)
                          (call-with-values
                           (lambda () (apply run-racket '() "-G" etc (load-args tree)))
                           as-list))
       ;; Racket's in-place build: setup with both config dirs, later steps
       ;; with racket/etc alone (racket/src/lib.zuo).
       (define build-config (path->string (build-path home "build-config")))
       (make-directory* build-config)
       (check-loads-fresh (format "~a: the build's setup config dirs" what)
                          (call-with-values
                           (lambda () (apply run-racket '() "-G" etc "-G" build-config
                                             (load-args tree)))
                           as-list))
       ;; The shim's roots, after a version bump, must name a dir that only
       ;; the running version writes.
       (check-true (string-contains? (linked-roots id) "@(version)")
                   (format "~a: linked roots are versioned: ~a" what (linked-roots id))))))

  ;; Fresh link.
  (check-linked-checkout "fresh link" void)

  ;; Upgrade from a rackup that wrote keyed-only roots into config.rktd
  ;; (#98): the next reshim must remove them.
  (check-linked-checkout
   "after keyed-only upgrade"
   (lambda (src key id)
     (write-rktd-file (build-path src "racket" "etc" "config.rktd")
                      (hash 'compiled-file-roots (list key)))
     (write-toolchain-meta! id (hash-set (read-toolchain-meta id)
                                         'compiled-roots-scheme 'keyed-only))
     (quietly (lambda () (with-state-lock (reshim!))))))

  ;; `rackup rebuild` (with `make` stubbed out): #98 wrote config.rktd here.
  (check-linked-checkout
   "after rackup rebuild"
   (lambda (src key id)
     (parameterize ([current-rebuild-system*-proc (lambda (exe . args) #t)])
       (quietly (lambda () (cmd-rebuild '("dev"))))))))
