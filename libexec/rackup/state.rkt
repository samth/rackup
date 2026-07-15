#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "error.rkt"
         "paths.rkt"
         "rktd-io.rkt"
         "state-lock.rkt"
         "fs.rkt"
         "security.rkt"
         "text.rkt")

(provide load-index
         save-index!
         ensure-index!
         installed-toolchains
         installed-toolchain-ids
         toolchain-exists?
         get-default-toolchain
         set-default-toolchain!
         clear-default-toolchain!
         read-toolchain-meta
         write-toolchain-meta!
         toolchain-env-vars
         toolchain-runtime-env
         meta->env-vars
         env-vars->meta
         toolchain-env-var-entries
         compiled-roots-value
         read-toolchain-compiled-file-roots
         register-toolchain!
         unregister-toolchain!
         find-local-toolchain
         toolchain-short-names
         upgradeable-toolchains
         ensure-toolchain-addon-dir!
         config-flag-set?
         set-config-flag!
         clear-config-flag!)

(define (empty-index)
  (hash 'installed-toolchains (hash) 'default-toolchain #f))

(define (normalize-index idx)
  (cond
    [(hash? idx)
     (hash 'installed-toolchains
           (if (hash? (hash-ref idx 'installed-toolchains #f))
               (hash-ref idx 'installed-toolchains)
               (hash))
           'default-toolchain
           (hash-ref idx 'default-toolchain #f))]
    [else (empty-index)]))

(define (load-index)
  (normalize-index (read-rktd-file (rackup-index-file) (empty-index))))

(define (save-index! idx)
  (write-rktd-file (rackup-index-file) idx))

(define (ensure-index!)
  (ensure-rackup-layout!)
  (unless (file-exists? (rackup-index-file))
    (save-index! (empty-index)))
  (unless (file-exists? (rackup-config-file))
    (write-string-file (rackup-config-file) ""))
  (load-index))

(define (installed-toolchains [idx (load-index)])
  (hash-ref idx 'installed-toolchains (hash)))

(define (installed-toolchain-ids [idx (load-index)])
  (sort (hash-keys (installed-toolchains idx)) string<?))

(define (toolchain-exists? id [idx (load-index)])
  (hash-has-key? (installed-toolchains idx) id))

(define (get-default-toolchain [idx (load-index)])
  (define raw (or (read-string-file (rackup-default-file) #f) (hash-ref idx 'default-toolchain #f)))
  (and raw (valid-toolchain-id? raw) raw))

(define/state-locked (set-default-toolchain! id)
  (ensure-valid-toolchain-id! id "default toolchain id")
  (ensure-index!)
  (define idx (load-index))
  (unless (toolchain-exists? id idx)
    (rackup-error "toolchain not installed: ~a" id))
  (write-string-file (rackup-default-file) id)
  (save-index! (hash-set idx 'default-toolchain id)))

(define/state-locked (clear-default-toolchain!)
  (delete-path! (rackup-default-file))
  (when (file-exists? (rackup-index-file))
    (define idx (load-index))
    (save-index! (hash-set idx 'default-toolchain #f))))

(define (read-toolchain-meta id)
  (read-rktd-file (rackup-toolchain-meta-file id) #f))

(define (write-toolchain-meta! id meta)
  (write-rktd-file (rackup-toolchain-meta-file id) meta))

(define (meta->env-vars m)
  (define raw (and (hash? m) (hash-ref m 'env-vars #f)))
  (if (list? raw)
      (for/list ([entry (in-list raw)]
                 #:when (and (list? entry) (= (length entry) 2)))
        (cons (format "~a" (car entry)) (format "~a" (cadr entry))))
      null))

(define (toolchain-env-vars id)
  (meta->env-vars (read-toolchain-meta id)))

;; The inverse of meta->env-vars: serialize an env-var alist into the
;; list-of-two-element-lists form stored under 'env-vars in meta.rktd.
(define (env-vars->meta env-vars)
  (for/list ([kv (in-list env-vars)])
    (list (car kv) (cdr kv))))

;; Environment for running a toolchain's own executables (raco/racket):
;; the toolchain's recorded env vars plus its rackup-managed addon dir.
(define (toolchain-runtime-env id)
  (append (toolchain-env-vars id)
          (list (cons "PLTADDONDIR" (path->string (rackup-addon-dir id))))))

;; Read the compiled-file-roots from a toolchain's config.rktd.
;; Returns a list like (same) or ("/usr/lib/racket/compiled"), or
;; (same) as default if the file is missing or has no entry.
(define (read-toolchain-compiled-file-roots real-bin-dir)
  (define parent
    (and real-bin-dir
         (let-values ([(d _ __) (split-path (if (path? real-bin-dir)
                                                real-bin-dir
                                                (string->path (format "~a" real-bin-dir))))])
           d)))
  (define candidates
    (if parent
        (list (build-path parent "etc" "config.rktd")
              (build-path parent "etc" "racket" "config.rktd"))
        null))
  (define config
    (for/or ([p (in-list candidates)])
      (and (file-exists? p)
           (try-or #f
             (call-with-input-file p read)))))
  (cond
    [(and (hash? config) (list? (hash-ref config 'compiled-file-roots #f)))
     (hash-ref config 'compiled-file-roots)]
    [else '(same)]))

;; Serialize a compiled-file-roots entry (as found in config.rktd or
;; returned by find-compiled-file-roots) into a string suitable for a
;; colon-separated PLTCOMPILEDROOTS value.  'same cannot be represented
;; directly, but "." is a relative path that resolves equivalently.
(define (serialize-compiled-root r)
  (cond
    [(eq? r 'same) "."]
    [(path? r) (path->string r)]
    [(string? r) r]
    [else (format "~a" r)]))

;; Compute a PLTCOMPILEDROOTS value that prepends a per-installation
;; subdirectory to the toolchain's existing compiled-file roots.  The
;; goal is one compiled directory per installation, so that switching
;; between toolchains that share a user source tree doesn't invalidate
;; each other's (mutually incompatible) .zo files.
;;
;; `existing-roots` is a list as found in config.rktd's
;; 'compiled-file-roots key (e.g., (same) for in-place installs, or
;; ("/usr/lib/racket/compiled") for FHS installs).  When not provided,
;; defaults to (same).  `local-name` is the local name of a linked
;; toolchain (e.g., "dev" for `rackup link dev`).
;;
;; Keying:
;;  - A linked source toolchain's version drifts on every `make`, so
;;    keying its dir on the version would spawn a fresh compiled tree
;;    per rebuild -- and go stale whenever the source is rebuilt outside
;;    `rackup rebuild`.  Key those on the installation name instead
;;    (e.g. "compiled/cs-local-dev"), which is stable across rebuilds
;;    and already unique per installation.
;;  - Installer toolchains have a stable version, so they keep the
;;    version+variant key (e.g. "compiled/9.1-cs").  That also lets
;;    .zo-compatible variants (full/minimal at the same version) share a
;;    directory.
;;
;; Returns a string like "compiled/9.1-cs:." or "compiled/cs-local-dev:."
;; (for linked toolchains), or #f when there is not enough information to
;; form a stable key.
(define (compiled-roots-value version variant [existing-roots '(same)] [local-name #f])
  (define variant-str
    (cond
      [(symbol? variant) (and (not (eq? variant 'unknown)) (symbol->string variant))]
      [(string? variant) (and (not (string-blank? variant)) variant)]
      [else #f]))
  (define version-str
    (cond
      [(and (string? version) (not (string-blank? version)) (not (equal? version "local")))
       version]
      [else #f]))
  (define local-name-str
    (and (string? local-name) (not (string-blank? local-name)) local-name))
  (define key
    (cond
      ;; Linked toolchain: key on the installation name (version-independent).
      [(and local-name-str variant-str) (format "compiled/~a-local-~a" variant-str local-name-str)]
      [local-name-str (format "compiled/local-~a" local-name-str)]
      ;; Installer toolchain: key on the stable version+variant.
      [(and version-str variant-str) (format "compiled/~a-~a" version-str variant-str)]
      [else #f]))
  (cond
    [key
     ;; Always include 'same (serialized as ".") so that user code's
     ;; compiled/ directories are found, even on FHS installs where the
     ;; existing roots only contain absolute reroot paths for system
     ;; collections.
     (define roots-with-same
       (let ([roots (if (null? existing-roots) '(same) existing-roots)])
         (if (memq 'same roots) roots (append roots '(same)))))
     (define fallbacks (map serialize-compiled-root roots-with-same))
     (string-join (cons key fallbacks) ":")]
    [else #f]))

;; Build the env-var alist recorded for a toolchain: PLTADDONDIR (when
;; a usable addon dir is known) and PLTCOMPILEDROOTS (when the
;; version+variant yield a stable key).  Entries are omitted when
;; unavailable.
(define (toolchain-env-var-entries addon-dir version variant existing-roots local-name)
  (append
   (if (and (string? addon-dir) (not (string-blank? addon-dir)))
       (list (cons "PLTADDONDIR" addon-dir))
       null)
   (cond
     [(compiled-roots-value version variant existing-roots local-name)
      =>
      (lambda (v) (list (cons "PLTCOMPILEDROOTS" v)))]
     [else null])))

(define (meta-summary meta)
  (for/hash ([k '(id kind
                     requested-spec
                     resolved-version
                     variant
                     distribution
                     arch
                     platform
                     snapshot-site
                     snapshot-stamp
                     installed-at
                     executables)])
    (values k (hash-ref meta k #f))))

(define/state-locked (register-toolchain! id meta)
  (ensure-valid-toolchain-id! id "toolchain id")
  (ensure-index!)
  (write-toolchain-meta! id meta)
  (define idx (load-index))
  (define new-installed (hash-set (installed-toolchains idx) id (meta-summary meta)))
  (save-index! (hash-set idx 'installed-toolchains new-installed))
  (when (not (get-default-toolchain))
    (set-default-toolchain! id)))

(define/state-locked (unregister-toolchain! id)
  (ensure-valid-toolchain-id! id "toolchain id")
  (ensure-index!)
  (define idx (load-index))
  (define new-installed (hash-remove (installed-toolchains idx) id))
  (define new-idx (hash-set idx 'installed-toolchains new-installed))
  (save-index! new-idx)
  (when (equal? (get-default-toolchain idx) id)
    (clear-default-toolchain!)
    (when (pair? (hash-keys new-installed))
      (set-default-toolchain! (car (sort (hash-keys new-installed) string<?))))))

;; Extract the string forms of version, variant, and distribution from
;; toolchain metadata.  Returns (values ver var dist) where each is a
;; string or #f.
(define (toolchain-meta-fields m)
  (values (hash-ref m 'resolved-version #f)
          (let ([v (hash-ref m 'variant #f)]) (and v (format "~a" v)))
          (let ([v (hash-ref m 'distribution #f)]) (and v (format "~a" v)))))

;; Does `name` match the toolchain's requested-spec or resolved-version?
(define (toolchain-meta-matches-spec? m name)
  (and (hash? m)
       (or (equal? name (hash-ref m 'requested-spec #f))
           (equal? name (hash-ref m 'resolved-version #f)))))

;; Does `name` match a multi-part combination of the toolchain's
;; version, variant, and distribution?
;; e.g. "9.0-minimal" matches version=9.0 + distribution=minimal
(define (toolchain-meta-matches-parts? m name)
  (and (hash? m)
       (let ([parts (string-split name "-")])
         (and (>= (length parts) 2)
              (let-values ([(ver var dist) (toolchain-meta-fields m)])
                (let ([vals (list ver var dist)])
                  (for/and ([part (in-list parts)])
                    (member part vals))))))))

;; Return all candidate short names derivable from a toolchain's metadata:
;; requested-spec, resolved-version, and multi-part combinations of
;; version/variant/distribution.
;; For linked (local) toolchains, skip version-based names since the
;; version is a snapshot that changes over time.
(define (toolchain-meta-names m)
  (if (not (hash? m))
      null
      (let-values ([(ver var dist) (toolchain-meta-fields m)])
        (let* ([local? (equal? (hash-ref m 'kind #f) 'local)]
               [spec (hash-ref m 'requested-spec #f)]
               ;; For local toolchains, don't use resolved-version as an alias
               [spec-names (if local?
                               (filter values (list spec))
                               (filter values (list spec ver)))]
               ;; For local toolchains, don't generate version-based combinations
               [fields (if local?
                           (filter values (list var dist))
                           (filter values (list ver var dist)))]
               [pairs (for*/list ([i (in-range (length fields))]
                                  [j (in-range (add1 i) (length fields))])
                        (string-join (list (list-ref fields i) (list-ref fields j)) "-"))]
               [triple (if (= (length fields) 3)
                           (list (string-join fields "-"))
                           null)])
          (remove-duplicates (append spec-names pairs triple))))))

;; Core name resolution against pre-loaded metadata.
;; Returns the matching toolchain ID or #f.
;; When #:error-on-ambiguous? is #t, raises an error listing the
;; matches instead of returning #f for ambiguous names.
(define (resolve-name-with-meta name ids all-meta
                                #:error-on-ambiguous? [error-on-ambiguous? #f])
  (define (unique xs) (and (= (length xs) 1) (car xs)))
  ;; When multiple toolchains match, prefer "full" distribution over others.
  ;; If still ambiguous and error-on-ambiguous?, raise an error.
  (define (unique-or-prefer-full xs)
    (or (unique xs)
        (let ([fulls (filter (lambda (id)
                               (let ([m (cdr (assoc id all-meta))])
                                 (and (hash? m)
                                      (equal? (format "~a" (hash-ref m 'distribution #f))
                                              "full"))))
                             xs)])
          (or (unique fulls)
              (and error-on-ambiguous? (> (length xs) 1)
                   (rackup-error
                    "ambiguous toolchain '~a' matches multiple installed toolchains:\n  ~a\nUse a more specific name."
                    name
                    (string-join xs "\n  ")))))))
  (cond
    [(member name ids) name]
    [else
     (or (unique (filter (lambda (id) (string-prefix? id name)) ids))
         (unique-or-prefer-full (for/list ([pair (in-list all-meta)]
                                           #:when (toolchain-meta-matches-spec? (cdr pair) name))
                                  (car pair)))
         (unique-or-prefer-full (for/list ([pair (in-list all-meta)]
                                           #:when (toolchain-meta-matches-parts? (cdr pair) name))
                                  (car pair)))
         #f)]))

(define (find-local-toolchain name [idx (load-index)])
  (cond
    [(or (not name) (string-blank? name)) (get-default-toolchain idx)]
    [else
     (define ids (installed-toolchain-ids idx))
     (define all-meta
       (for/list ([id ids])
         (cons id (read-toolchain-meta id))))
     (resolve-name-with-meta name ids all-meta
                             #:error-on-ambiguous? #t)]))

;; Return the short names that uniquely resolve to this toolchain.
;; Accepts optional #:all-meta to avoid redundant file reads when
;; called in a loop (e.g. from cmd-list).
(define (toolchain-short-names id [idx (load-index)] #:all-meta [preloaded-meta #f])
  (define ids (installed-toolchain-ids idx))
  (define all-meta
    (or preloaded-meta
        (for/list ([tid ids])
          (cons tid (read-toolchain-meta tid)))))
  (define m (cdr (assoc id all-meta)))
  (define candidates (toolchain-meta-names m))
  (filter (lambda (name) (equal? id (resolve-name-with-meta name ids all-meta)))
          (remove-duplicates candidates)))

;; Determine whether a toolchain's metadata indicates it is
;; channel-based (upgradeable).  The kind field is 'release for both
;; stable and version-pinned installs, so we check requested-spec.
(define (upgradeable-meta? m)
  (and (hash? m)
       (let ([spec (hash-ref m 'requested-spec #f)]
             [kind (hash-ref m 'kind #f)])
         (or (equal? spec "stable")
             (equal? spec "pre-release")
             (equal? spec "pre")
             (and (string? spec) (string-prefix? spec "snapshot"))
             (eq? kind 'pre-release)
             (eq? kind 'snapshot)))))

;; Return a list of (cons id meta) for toolchains that are
;; channel-based (upgradeable).  When filter-spec is non-#f, further
;; restrict to toolchains matching that channel.
(define (upgradeable-toolchains [filter-spec #f])
  (define idx (load-index))
  (define ids (installed-toolchain-ids idx))
  (define filter-channel
    (and filter-spec
         (match filter-spec
           ["stable" "stable"]
           ["pre-release" "pre-release"]
           ["pre" "pre-release"]
           ["snapshot" "snapshot"]
           [(regexp #px"^snapshot:") "snapshot"]
           [_ "unknown"])))
  (for*/list ([id (in-list ids)]
              [m (in-value (read-toolchain-meta id))]
              #:when (and (upgradeable-meta? m)
                          (or (not filter-channel)
                              (let ([spec (hash-ref m 'requested-spec #f)])
                                (cond
                                  [(equal? filter-channel "snapshot")
                                   (and (string? spec)
                                        (or (equal? spec "snapshot")
                                            (string-prefix? spec "snapshot:")))]
                                  [else
                                   (equal? spec filter-channel)])))))
    (cons id m)))

(define (ensure-toolchain-addon-dir! id)
  (ensure-directory* (rackup-addon-dir id)))

;; Plain-text config file: one flag name per line.
(define (read-config-flags)
  (if (file-exists? (rackup-config-file))
      (filter (lambda (s) (not (string-blank? s)))
              (map string-trim (file->lines (rackup-config-file))))
      null))

(define (config-flag-set? flag)
  (member flag (read-config-flags)))

(define (set-config-flag! flag)
  (define flags (read-config-flags))
  (unless (member flag flags)
    (write-string-file (rackup-config-file)
                       (string-join (append flags (list flag)) "\n"))))

(define (clear-config-flag! flag)
  (define flags (read-config-flags))
  (when (member flag flags)
    (write-string-file (rackup-config-file)
                       (string-join (remove flag flags) "\n"))))
