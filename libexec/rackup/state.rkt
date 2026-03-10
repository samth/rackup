#lang racket/base

(require racket/file
         racket/list
         racket/match
         racket/path
         racket/string
         "paths.rkt"
         "rktd-io.rkt"
         "util.rkt")

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
         register-toolchain!
         unregister-toolchain!
         find-local-toolchain
         toolchain-short-names
         ensure-toolchain-addon-dir!)

(define (empty-index)
  (hash 'installed-toolchains (hash) 'aliases (hash) 'default-toolchain #f))

(define (normalize-index idx)
  (cond
    [(hash? idx)
     (hash 'installed-toolchains
           (if (hash? (hash-ref idx 'installed-toolchains #f))
               (hash-ref idx 'installed-toolchains)
               (hash))
           'aliases
           (if (hash? (hash-ref idx 'aliases #f))
               (hash-ref idx 'aliases)
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
    (write-rktd-file (rackup-config-file) (hash)))
  (load-index))

(define (installed-toolchains [idx (load-index)])
  (hash-ref idx 'installed-toolchains (hash)))

(define (installed-toolchain-ids [idx (load-index)])
  (sort (hash-keys (installed-toolchains idx)) string<?))

(define (toolchain-exists? id [idx (load-index)])
  (hash-has-key? (installed-toolchains idx) id))

(define (get-default-toolchain [idx (load-index)])
  (or (read-string-file (rackup-default-file) #f) (hash-ref idx 'default-toolchain #f)))

(define (set-default-toolchain! id)
  (ensure-index!)
  (define idx (load-index))
  (unless (toolchain-exists? id idx)
    (rackup-error "toolchain not installed: ~a" id))
  (write-string-file (rackup-default-file) id)
  (save-index! (hash-set idx 'default-toolchain id)))

(define (clear-default-toolchain!)
  (when (file-exists? (rackup-default-file))
    (delete-file (rackup-default-file)))
  (when (file-exists? (rackup-index-file))
    (define idx (load-index))
    (save-index! (hash-set idx 'default-toolchain #f))))

(define (read-toolchain-meta id)
  (read-rktd-file (rackup-toolchain-meta-file id) #f))

(define (write-toolchain-meta! id meta)
  (write-rktd-file (rackup-toolchain-meta-file id) meta))

(define (toolchain-env-vars id)
  (define m (read-toolchain-meta id))
  (define raw (and (hash? m) (hash-ref m 'env-vars #f)))
  (cond
    [(hash? raw)
     (for/list ([k (in-list (sort (hash-keys raw) string<?))])
       (cons k (hash-ref raw k)))]
    [(list? raw)
     (for/list ([entry (in-list raw)]
                #:when (and (list? entry) (= (length entry) 2)))
       (cons (format "~a" (car entry)) (format "~a" (cadr entry))))]
    [else null]))

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

(define (register-toolchain! id meta)
  (ensure-index!)
  (write-toolchain-meta! id meta)
  (define idx (load-index))
  (define new-installed (hash-set (installed-toolchains idx) id (meta-summary meta)))
  (save-index! (hash-set idx 'installed-toolchains new-installed))
  (when (not (get-default-toolchain))
    (set-default-toolchain! id)))

(define (unregister-toolchain! id)
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
(define (resolve-name-with-meta name ids aliases all-meta
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
    [(hash-has-key? aliases name) (hash-ref aliases name)]
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
     (define aliases (hash-ref idx 'aliases (hash)))
     (define all-meta
       (for/list ([id ids])
         (cons id (read-toolchain-meta id))))
     (resolve-name-with-meta name ids aliases all-meta
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
  (define aliases (hash-ref idx 'aliases (hash)))
  (define alias-names
    (for/list ([(k v) (in-hash aliases)]
               #:when (equal? v id))
      k))
  (filter (lambda (name) (equal? id (resolve-name-with-meta name ids aliases all-meta)))
          (remove-duplicates (append alias-names candidates))))

(define (ensure-toolchain-addon-dir! id)
  (ensure-directory* (rackup-addon-dir id)))
