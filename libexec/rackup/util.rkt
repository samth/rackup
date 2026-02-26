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
         system*/check
         current-iso8601
         path-basename-string
         maybe-string->symbol)

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
  (regexp-match? #px"^\\s*$" s))

(define (executable-file? p)
  (and (file-exists? p)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (member 'execute (file-or-directory-permissions p)))))

(define (system*/check who . args)
  (define ok? (apply system* args))
  (unless ok?
    (rackup-error "~a failed: ~a"
                  who
                  (string-join (map path->string* args) " "))))

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
  (path->string (file-name-from-path p)))

(define (maybe-string->symbol v)
  (cond
    [(symbol? v) v]
    [(string? v) (string->symbol v)]
    [else #f]))
