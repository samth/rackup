#lang racket/base

(provide sanitized-racket-env-vars
         restore-saved-racket-env-vars!)

(define sanitized-racket-env-vars
  '("PLTCOLLECTS" "PLTADDONDIR" "PLTCOMPILEDROOTS"
    "PLTUSERHOME" "RACKET_XPATCH" "PLT_COMPILED_FILE_CHECK"))

(define (restore-saved-racket-env-vars! env)
  (for ([var (in-list sanitized-racket-env-vars)])
    (define saved-key (string->bytes/utf-8 (string-append "_RACKUP_ORIG_" var)))
    (define saved-val (environment-variables-ref env saved-key))
    (when saved-val
      (environment-variables-set! env (string->bytes/utf-8 var) saved-val))
    (environment-variables-set! env saved-key #f)))
