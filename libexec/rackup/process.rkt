#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "text.rkt")

(provide executable-file?
         resolve-command-path
         system*/check
         shell-exe
         capture-program-output
         probe-local-racket-version+variant+addon-dir)

(define (executable-file? p)
  (and (file-exists? p)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (member 'execute (file-or-directory-permissions p)))))

(define (resolve-command-path cmd path-string)
  (cond
    [(or (path? cmd)
         (and (string? cmd) (regexp-match? #px"/" cmd)))
     cmd]
    [else
     (for/or ([dir (in-list (string-split (or path-string "") ":" #:trim? #f))])
       (define base
         (if (string-blank? dir)
             (current-directory)
             (string->path dir)))
       (define candidate (build-path base (format "~a" cmd)))
       (and (executable-file? candidate) candidate))]))

(define (system*/check who . args)
  (define ok? (apply system* args))
  (unless ok?
    (rackup-error "~a failed: ~a" who (string-join (map path->string* args) " "))))

(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))

(define (->env-bytes v)
  (and v
       (if (bytes? v)
           v
           (string->bytes/utf-8 (format "~a" v)))))

(define (capture-program-output #:env [env-vars null] exe . args)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([kv (in-list env-vars)])
    (environment-variables-set! env
                                (string->bytes/utf-8 (format "~a" (car kv)))
                                (->env-bytes (cdr kv))))
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-environment-variables env]
                 [current-output-port out]
                 [current-error-port err])
    (if (apply system* exe args)
        (string-trim (get-output-string out))
        #f)))

(define (probe-local-racket-version+variant+addon-dir bin-dir env-vars)
  (define racket-exe (build-path (string->path bin-dir) "racket"))
  (define combined-out
    (capture-program-output
     #:env env-vars
     racket-exe
     "-e"
     (string-append
      "(displayln (version))"
      "(displayln (let ([v (system-type 'vm)])"
      "  (if (symbol? v) (symbol->string v) (format \"~a\" v))))"
      "(display (find-system-path 'addon-dir))")))
  (define (normalize-vm-name s)
    (and s (not (string-blank? s))
         (match (string-downcase s)
           ["chez-scheme" "cs"]
           ["racket" "bc"]
           [v v])))
  (define-values (version-out variant-out addon-out)
    (if combined-out
        (let ([lines (string-split combined-out "\n")])
          (if (>= (length lines) 3)
              (values (first lines) (second lines)
                      (string-join (drop lines 2) "\n"))
              (values #f #f #f)))
        (values #f #f #f)))
  (values (and version-out (not (string-blank? version-out)) version-out)
          (normalize-vm-name variant-out)
          (and addon-out (not (string-blank? addon-out)) addon-out)))
