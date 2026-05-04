#lang racket/base

(require racket/file
         racket/stxparam
         (for-syntax racket/base
                     racket/stxparam
                     syntax/parse
                     syntax/parse/lib/function-header
                     racket/syntax)
         "error.rkt"
         "text.rkt")

(provide define-file-lock)

;; (define-file-lock with-name define/locked-name lock-dir-expr lock-label)
;;
;; Defines:
;;   with-name : body ... -> A — macro that holds the lock for body ...
;;   define/locked-name — macro for defining functions that require the lock
;;
;; lock-dir-expr is evaluated each time the lock is acquired (typically a
;; call like (rackup-runtime-lock-dir)).
;;
;; The lock is a directory created with make-directory; creation is atomic
;; on POSIX and Windows, so two processes racing to acquire will have exactly
;; one succeed and the other see exn:fail:filesystem?.
;;
;; Static checking: functions defined with define/locked-name can only be
;; called inside with-name (enforced at compile time via syntax parameters).
(define-syntax (define-file-lock stx)
  (syntax-parse stx
    [(_ with-name:id define/locked-name:id lock-dir-expr:expr lock-label:expr)
     (with-syntax ([lock-held? (generate-temporary #'with-name)]
                   [with-name-impl (generate-temporary #'with-name)])
       #'(begin
           (define-syntax-parameter lock-held? #f)

           (define (with-name-impl thunk)
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
                                                     lock-label
                                                     (path->string* lock-dir))]))])
                   (make-directory lock-dir)))
               thunk
               (lambda ()
                 (when (directory-exists? lock-dir)
                   (delete-directory lock-dir)))))

           (define-syntax-rule (with-name body (... ...))
             (syntax-parameterize ([lock-held? #t])
               (with-name-impl (lambda () body (... ...)))))

           (define-syntax (define/locked-name dl-stx)
             (syntax-parse dl-stx
               [(_ header:function-header body:expr (... ...+))
                (with-syntax ([fname-impl (format-id #'header.name "~a-impl" #'header.name)])
                  #'(begin
                      (define (fname-impl . header.args)
                        (syntax-parameterize ([lock-held? #t])
                          body (... ...)))
                      (define-syntax (header.name use-stx)
                        (syntax-parse use-stx
                          [(_ . rest-args)
                           #:when (syntax-parameter-value #'lock-held?)
                           #'(fname-impl . rest-args)]
                          [_
                           (raise-syntax-error #f
                             (string-append "must be called inside "
                                            (symbol->string 'with-name))
                             use-stx)]))))]))))]))
