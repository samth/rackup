#lang racket/base

(require racket/file
         racket/format
         racket/future
         racket/string
         racket/system
         "error.rkt"
         "install.rkt"
         "paths.rkt"
         "shims.rkt"
         "state.rkt"
         "state-lock.rkt"
         "text.rkt")

(provide rebuild-toolchain!
         rebuild-plan
         current-rebuild-system*-proc
         current-rebuild-displayln-proc)

(define current-rebuild-system*-proc (make-parameter system*))
(define current-rebuild-displayln-proc (make-parameter displayln))

;; Decide what to run for a given layout.  Pure: no I/O, no subprocess
;; spawning.  Returns a hash with keys 'kind, 'cwd, 'reason where 'kind
;; is 'package-based, 'in-place, or 'unsupported.
(define (rebuild-plan layout)
  (define source-root (hash-ref layout 'source-root #f))
  (define plthome (hash-ref layout 'plthome #f))
  (cond
    [(and source-root (file-exists? (build-path source-root "Makefile")))
     (hasheq 'kind 'package-based 'cwd source-root 'reason #f)]
    [source-root
     (hasheq 'kind 'unsupported
             'cwd #f
             'reason
             (format
              (string-append
               "no Makefile found at source root ~a; rackup rebuild expects a "
               "package-based source checkout (with a top-level Makefile)")
              source-root))]
    [(and plthome (file-exists? (build-path plthome "Makefile")))
     (hasheq 'kind 'in-place 'cwd plthome 'reason #f)]
    [else
     (hasheq 'kind 'unsupported
             'cwd #f
             'reason
             (string-append
              "this linked toolchain points at an installed prefix, not a source tree; "
              "rackup rebuild requires a source checkout with a Makefile"))]))

;; -j is a make-level flag; CPUS= is what the Racket build's recursive
;; invocations honor.  Passing both keeps top-level and subordinate
;; jobs in sync; a user-supplied CPUS= in pass-through args wins.
(define (make-argv jobs user-make-args)
  (define user-set-cpus?
    (for/or ([a (in-list user-make-args)]) (string-prefix? a "CPUS=")))
  (append (list "make" (format "-j~a" jobs))
          (if user-set-cpus? '() (list (format "CPUS=~a" jobs)))
          user-make-args))

(define (git-work-tree? path system*-proc)
  (define git (find-executable-path "git"))
  (cond
    [(not git) #f]
    [else
     (parameterize ([current-output-port (open-output-string)]
                    [current-error-port (open-output-string)])
       (try-or #f
         (system*-proc git "-C" (~a path) "rev-parse" "--is-inside-work-tree")))]))

(define (run-git-pull! source-root system*-proc displayln-proc)
  (define git (find-executable-path "git"))
  (unless git
    (rackup-error "rackup rebuild --pull requires `git` on PATH"))
  (unless (git-work-tree? source-root system*-proc)
    (rackup-error "rackup rebuild --pull: ~a is not a git work tree" source-root))
  (displayln-proc (format "+ git -C ~a pull --ff-only" source-root))
  (unless (system*-proc git "-C" (~a source-root) "pull" "--ff-only")
    (rackup-error "git pull --ff-only failed in ~a" source-root)))

(define (run-make! cwd argv system*-proc displayln-proc)
  (define make-exe (find-executable-path "make"))
  (unless make-exe
    (rackup-error "rackup rebuild requires `make` on PATH"))
  (displayln-proc (format "+ cd ~a && ~a" cwd (string-join argv " ")))
  (parameterize ([current-directory cwd])
    (unless (apply system*-proc make-exe (cdr argv))
      (rackup-error "make failed in ~a" cwd))))

;; Environment for the rebuild's `make`: the current one plus the
;; toolchain's addon dir, the same PLTADDONDIR the shim and `rackup run`
;; use (for a linked toolchain, the checkout's own addon dir).
(define (build-environment id)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"PLTADDONDIR"
                              (string->bytes/utf-8 (path->string (toolchain-addon-dir id))))
  env)

(define (resolve-rebuild-target name)
  (cond
    [(or (not name) (string-blank? name))
     (or (resolve-active-toolchain-id)
         (rackup-error
          (string-append
           "no toolchain specified and no active or default toolchain configured;"
           "\npass <name> or set a default with `rackup default set <toolchain>`")))]
    [else
     (or (find-local-toolchain name)
         (rackup-error "no matching installed toolchain: ~a" name))]))

(define (rebuild-toolchain! name
                            #:pull? [pull? #f]
                            #:jobs [jobs #f]
                            #:dry-run? [dry-run? #f]
                            #:update-meta? [update-meta? #t]
                            #:make-args [make-args '()])
  (define id (resolve-rebuild-target name))
  (define meta (read-toolchain-meta id))
  (unless (hash? meta)
    (rackup-error "could not read metadata for toolchain ~a" id))
  (unless (eq? (hash-ref meta 'kind #f) 'local)
    (rackup-error
     (string-append
      "rackup rebuild only works on linked source toolchains;"
      "\n~a is kind=~a (use `rackup link <name> <path>` to register a source tree)")
     id (hash-ref meta 'kind #f)))
  (define source-path
    (or (hash-ref meta 'source-path #f)
        (rackup-error "linked toolchain ~a has no recorded source-path; relink it" id)))
  (unless (directory-exists? source-path)
    (rackup-error
     "source path for ~a no longer exists: ~a (relink with `rackup link --force`)"
     id source-path))
  (define layout (detect-local-source-layout source-path))
  (define plan (rebuild-plan layout))
  (when (eq? (hash-ref plan 'kind) 'unsupported)
    (rackup-error "cannot rebuild ~a: ~a" id (hash-ref plan 'reason)))
  (define cwd (hash-ref plan 'cwd))
  (define source-root (hash-ref layout 'source-root #f))
  (define resolved-jobs (or jobs (max 1 (processor-count))))
  (define argv (make-argv resolved-jobs make-args))
  (define system*-proc (current-rebuild-system*-proc))
  (define displayln-proc (current-rebuild-displayln-proc))
  (define key (compiled-roots-key (hash-ref meta 'resolved-version #f)
                                  (hash-ref meta 'variant #f)
                                  (hash-ref meta 'requested-spec #f)))
  ;; `make` refreshes the default `compiled/` dirs of the tree and of every
  ;; installed package; drop the keyed `.zo` the shim wrote for that code
  ;; (all versions), so none shadows the build's newer output.  Runs even
  ;; when `make` fails, since a failed build has usually replaced part of
  ;; the default dirs already.
  (define (purge-keyed-dirs!)
    (define n (purge-linked-keyed-dirs! id meta layout))
    (when (positive? n)
      (displayln-proc
       (format "Removed ~a keyed compiled dir(s) of ~a that the build supersedes" n id))))
  (cond
    [(and pull? dry-run?)
     (displayln-proc (format "+ git -C ~a pull --ff-only" (or source-root cwd)))]
    [pull?
     (run-git-pull! (or source-root cwd) system*-proc displayln-proc)])
  (cond
    [dry-run?
     (displayln-proc (format "+ cd ~a && ~a" cwd (string-join argv " ")))]
    [else
     ;; Undo an earlier keyed-only migration before `make`, so the
     ;; build's later steps (which read the tree's config.rktd) do not
     ;; load stale keyed `.zo`.
     (when key
       (unset-toolchain-compiled-file-roots! (string->path (hash-ref layout 'bin-dir))
                                             (list key)))
     (with-handlers ([exn:fail? (lambda (e)
                                  (purge-keyed-dirs!)
                                  (raise e))])
       ;; bin/rackup clears PLTADDONDIR, so without this the build's
       ;; `raco setup` would use the native addon dir and miss
       ;; user-scope packages that the shim and `rackup run` see under
       ;; the managed dir, and could drop their launchers.
       (parameterize ([current-environment-variables (build-environment id)])
         (run-make! cwd argv system*-proc displayln-proc)))
     (purge-keyed-dirs!)])
  (cond
    [(or dry-run? (not update-meta?)) id]
    [else
     (finalize-local-toolchain! id (hash-ref meta 'requested-spec id) layout
                                #:installed-at (hash-ref meta 'installed-at #f)
                                #:last-rebuilt-at (current-iso8601))
     (displayln-proc (format "Rebuilt ~a" id))
     id]))
