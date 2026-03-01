#lang racket/base

(require racket/date
         racket/file
         racket/format
         racket/path
         racket/string
         racket/system)

(provide rackup-error
         ensure-directory*
         path->string*
         string-blank?
         executable-file?
         resolve-command-path
         system*/check
         shell-exe
         capture-program-output
         current-iso8601
         path-basename-string
         http-url?
         require-checksummed-http-installer!
         sh-single-quote)

(define (rackup-error fmt . args)
  (raise-user-error 'rackup (apply format fmt args)))

(define (ensure-directory* p)
  (make-directory* p)
  p)

(define (path->string* p)
  (cond
    [(path? p) (path->string p)]
    [(string? p) p]
    [else (format "~a" p)]))

(define (string-blank? s)
  (string=? "" (string-trim s)))

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

(define (pad2 n)
  (~r n #:min-width 2 #:pad-string "0"))

(define (pad4 n)
  (~r n #:min-width 4 #:pad-string "0"))

(define (current-iso8601)
  (define d (seconds->date (current-seconds) #t))
  (string-append (pad4 (date-year d))
                 "-"
                 (pad2 (date-month d))
                 "-"
                 (pad2 (date-day d))
                 "T"
                 (pad2 (date-hour d))
                 ":"
                 (pad2 (date-minute d))
                 ":"
                 (pad2 (date-second d))
                 "Z"))

(define (path-basename-string p)
  (define name (file-name-from-path p))
  (if name
      (path->string name)
      (path->string* p)))

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

(define (http-url? s)
  (and (string? s) (regexp-match? #px"(?i:^http://)" s)))

(define (require-checksummed-http-installer! installer-url expected-sha256)
  (when (and (http-url? installer-url)
             (or (not (string? expected-sha256))
                 (string-blank? expected-sha256)))
    (rackup-error
     "refusing to download installer over HTTP without a hardcoded SHA-256 checksum: ~a"
     installer-url)))

(define (sh-single-quote s)
  (define str (format "~a" s))
  (string-append "'" (regexp-replace* #px"'" str "'\"'\"'") "'"))
