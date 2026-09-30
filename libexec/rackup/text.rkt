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
         yes-answer?
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

;; Interpret an interactive yes/no answer.  Non-strings (#f, eof) count
;; as no answer.  `#:empty-means-yes?` selects the default for a bare
;; enter: #t for a "[Y/n]" prompt, #f for a "[y/N]" prompt.
(define (yes-answer? s #:empty-means-yes? [empty-yes? #f])
  (define a (and (string? s) (string-downcase (string-trim s))))
  (cond
    [(not a) #f]
    [(string=? a "") empty-yes?]
    [else (and (member a '("y" "yes")) #t)]))

(define (color-enabled?)
  (and (terminal-port? (current-output-port)) (not (getenv "NO_COLOR"))))

(define (ansi code s)
  (if (color-enabled?)
      (string-append "\e[" code "m" s "\e[0m")
      s))
