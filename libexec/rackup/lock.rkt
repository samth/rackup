#lang racket/base

(require racket/file
         "util.rkt")

(provide define-file-lock)

;; (define-file-lock with-name lock-dir-expr lock-label)
;;
;; Defines:
;;   with-name : (-> A) -> A — holds the lock for the duration of thunk
;;
;; lock-dir-expr is evaluated each time the lock is acquired (typically a
;; call like (rackup-runtime-lock-dir)).
;;
;; The lock is a directory created with make-directory; creation is atomic
;; on POSIX and Windows, so two processes racing to acquire will have exactly
;; one succeed and the other see exn:fail:filesystem?.
(define-syntax-rule (define-file-lock with-name lock-dir-expr lock-label)
  (define (with-name thunk)
    (define lock-dir lock-dir-expr)
    (dynamic-wind
      (lambda ()
        (with-handlers ([exn:fail:filesystem?
                         (lambda (_)
                           (cond
                             [(file-exists? lock-dir)
                              (rackup-error
                               "~a lock path exists and is not a directory: ~a"
                               lock-label (path->string* lock-dir))]
                             [else
                              (rackup-error "~a is locked: ~a"
                                            lock-label (path->string* lock-dir))]))])
          (make-directory lock-dir)))
      thunk
      (lambda ()
        (when (directory-exists? lock-dir)
          (delete-directory lock-dir))))))
