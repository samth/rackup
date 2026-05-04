#lang racket/base

(require racket/file
         racket/format
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         "error.rkt"
         "text.rkt")

(provide executable-file?
         system*/check
         find-executable-path/default
         shell-exe
         capture-program-output
         probe-local-racket-version+variant+addon-dir)

(define (executable-file? p)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (member 'execute (file-or-directory-permissions p)) #t)))

(define (system*/check who . args)
  (unless (apply system* args)
    (rackup-error "~a failed: ~a" who (string-join (map path->string* args) " "))))

;; `find-executable-path` returning a fallback absolute path when not on PATH.
(define (find-executable-path/default name fallback)
  (or (find-executable-path name) (string->path fallback)))

(define (shell-exe)
  (find-executable-path/default "sh" "/bin/sh"))

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
    (and (apply system* exe args)
         (string-trim (get-output-string out)))))

(define (string->value s)
  (and (string? s) (not (equal? s ""))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (read (open-input-string s)))))

;; Probe a local Racket binary for its version, variant ("cs"|"bc"), and
;; native addon-dir.  The probe is written to a temp file and run with
;; `racket -f`; it `write`s a single list, and we `read` it back — the
;; round-trip preserves embedded whitespace and the bare vm symbol that
;; `(system-type 'vm)` returns.
(define (probe-local-racket-version+variant+addon-dir bin-dir env-vars)
  (define racket-exe (build-path (string->path bin-dir) "racket"))
  (define probe-file (make-temporary-file "rackup-probe-~a.rkt"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file probe-file #:exists 'truncate
       (lambda (out)
         (write '(write (list (version)
                              (system-type 'vm)
                              (path->string (find-system-path 'addon-dir))))
                out)))
     (define raw (capture-program-output #:env env-vars racket-exe "-f" probe-file))
     (match (string->value raw)
       [(list (? string? version) (? symbol? vm) (? string? addon))
        (values (non-blank version) (vm-symbol->variant vm) (non-blank addon))]
       [_ (values #f #f #f)]))
   (lambda () (delete-file probe-file))))

(define (non-blank s) (and (string? s) (not (string-blank? s)) s))

(define (vm-symbol->variant vm)
  (case vm
    [(chez-scheme) "cs"]
    [(racket) "bc"]
    [else (symbol->string vm)]))
