#lang racket/base

(provide rackup-error)

(define (rackup-error fmt . args)
  (raise-user-error 'rackup (apply format fmt args)))
