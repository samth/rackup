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

(define (find-local-toolchain name [idx (load-index)])
  (define ids (installed-toolchain-ids idx))
  (cond
    [(or (not name) (string-blank? name)) (get-default-toolchain idx)]
    [(hash-has-key? (hash-ref idx 'aliases (hash)) name) (hash-ref (hash-ref idx 'aliases) name)]
    [(member name ids) name]
    [else
     (define (unique xs)
       (and (= (length xs) 1) (car xs)))
     (or (unique (filter (lambda (id) (string-prefix? id name)) ids))
         (let ([matches (for/list ([id ids]
                                   #:when
                                   (let ([m (read-toolchain-meta id)])
                                     (and (hash? m)
                                          (or (equal? name (hash-ref m 'requested-spec #f))
                                              (equal? name (hash-ref m 'resolved-version #f))))))
                          id)])
           (unique matches))
         #f)]))

(define (ensure-toolchain-addon-dir! id)
  (ensure-directory* (rackup-addon-dir id)))
