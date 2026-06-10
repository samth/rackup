#lang racket/base

(provide rackup-error
         try-or)

(define (rackup-error fmt . args)
  (raise-user-error 'rackup (apply format fmt args)))

;; Evaluate body, returning `default` if it raises exn:fail.  For the
;; pervasive "best effort, fall back to a default" pattern; use a full
;; with-handlers form when the handler needs to log or inspect the
;; exception.
(define-syntax-rule (try-or default body ...)
  (with-handlers ([exn:fail? (lambda (_) default)])
    body ...))
