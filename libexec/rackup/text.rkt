#lang racket/base

(require racket/date
         racket/path
         racket/string)

(provide path->string*
         string-blank?
         current-iso8601
         path-basename-string
         sh-single-quote
         env-var-export-line
         color-enabled?
         ansi)

(define (path->string* p)
  (if (path? p) (path->string p) p))

(define (string-blank? s)
  (string=? "" (string-trim s)))

;; "YYYY-MM-DDTHH:MM:SSZ" (UTC). `racket/date`'s 'iso-8601 format omits
;; the timezone, so append the trailing "Z" ourselves.
(define (current-iso8601)
  (parameterize ([date-display-format 'iso-8601])
    (string-append (date->string (seconds->date (current-seconds) #t) #t) "Z")))

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
