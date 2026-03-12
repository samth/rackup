#lang racket/base

(require rackunit
         racket/file
         "../libexec/rackup/lock.rkt"
         "../libexec/rackup/util.rkt")

;; ---- Set up a test lock ----

(define test-lock-dir
  (build-path (find-system-path 'temp-dir) "rackup-lock-test"))

(define-file-lock with-test-lock define/test-locked
  test-lock-dir "test")

;; ---- define/test-locked: compiles inside with-test-lock ----

(define/test-locked (locked-add x y)
  (+ x y))

(check-equal?
 (with-test-lock (locked-add 3 4))
 7)

;; ---- define/test-locked: error outside with-test-lock ----

(check-exn
 #rx"must be called inside with-test-lock"
 (lambda ()
   (eval #'(locked-add 1 2) (variable-reference->namespace (#%variable-reference)))))

;; ---- bare reference is always a syntax error ----

(check-exn
 #rx"must be called inside with-test-lock"
 (lambda ()
   (eval #'locked-add (variable-reference->namespace (#%variable-reference)))))

(check-exn
 #rx"must be called inside with-test-lock"
 (lambda ()
   (eval #'(with-test-lock locked-add)
         (variable-reference->namespace (#%variable-reference)))))

;; ---- locked function can call another locked function ----

(define/test-locked (locked-double x)
  (locked-add x x))

(check-equal?
 (with-test-lock (locked-double 5))
 10)

;; ---- two independent locks don't cross-contaminate ----

(define test-lock-dir-2
  (build-path (find-system-path 'temp-dir) "rackup-lock-test-2"))

(define-file-lock with-other-lock define/other-locked
  test-lock-dir-2 "other")

(define/other-locked (other-fn x) (* x 2))

;; other-fn inside with-other-lock: ok
(check-equal? (with-other-lock (other-fn 3)) 6)

;; other-fn inside with-test-lock: should fail (wrong lock)
(check-exn
 #rx"must be called inside with-other-lock"
 (lambda ()
   (eval #'(with-test-lock (other-fn 3))
         (variable-reference->namespace (#%variable-reference)))))

;; ---- runtime lock behavior: directory created and removed ----

(when (directory-exists? test-lock-dir)
  (delete-directory test-lock-dir))

(check-false (directory-exists? test-lock-dir))
(with-test-lock (check-true (directory-exists? test-lock-dir)))
(check-false (directory-exists? test-lock-dir))

;; ---- cleanup ----
(when (directory-exists? test-lock-dir)
  (delete-directory test-lock-dir))
(when (directory-exists? test-lock-dir-2)
  (delete-directory test-lock-dir-2))
