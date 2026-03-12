#lang racket/base

(require "lock.rkt"
         "paths.rkt")

(provide with-state-lock
         define/state-locked)

(define-file-lock with-state-lock define/state-locked
  (rackup-state-lock-dir) "rackup state")
