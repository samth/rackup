#lang racket/base

(require racket/date
         racket/file
         racket/format
         racket/path
         racket/string)

(provide rackup-error
         ensure-directory*
         path->string*
         string-blank?
         current-iso8601
         path-basename-string
         sh-single-quote
         env-var-export-line
         color-enabled?
         ansi)

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

(define (pad2 n) (~r n #:min-width 2 #:pad-string "0"))
(define (pad4 n) (~r n #:min-width 4 #:pad-string "0"))

(define (current-iso8601)
  (define d (seconds->date (current-seconds) #t))
  (string-append (pad4 (date-year d)) "-" (pad2 (date-month d)) "-" (pad2 (date-day d))
                 "T" (pad2 (date-hour d)) ":" (pad2 (date-minute d)) ":" (pad2 (date-second d)) "Z"))

(define (path-basename-string p)
  (define name (file-name-from-path p))
  (if name (path->string name) (path->string* p)))

(define (sh-single-quote s)
  (define str (format "~a" s))
  (string-append "'" (regexp-replace* #px"'" str "'\"'\"'") "'"))

(define (env-var-export-line key value)
  (format "export ~a=~a\n" key (sh-single-quote value)))

(define (color-enabled?)
  (and (terminal-port? (current-output-port)) (not (getenv "NO_COLOR"))))

(define (ansi code s)
  (if (color-enabled?)
      (string-append "\e[" code "m" s "\e[0m")
      s))
