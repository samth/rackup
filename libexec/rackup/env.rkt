#lang racket/base

(provide sanitized-racket-env-vars
         restore-saved-racket-env-vars!
         managed-compiled-roots-marker)

;; Records the PLTCOMPILEDROOTS value rackup itself exported (from a
;; toolchain's env.sh or `rackup run`).  A PLTCOMPILEDROOTS equal to it was
;; inherited from an enclosing rackup-launched process, not set by the
;; user, so a nested launch of a different toolchain must replace it rather
;; than honor it as a user override.
(define managed-compiled-roots-marker "_RACKUP_MANAGED_PLTCOMPILEDROOTS")

(define sanitized-racket-env-vars
  '(#"PLTCOLLECTS" #"PLTADDONDIR" #"PLTCOMPILEDROOTS"
    #"PLTUSERHOME" #"RACKET_XPATCH" #"PLT_COMPILED_FILE_CHECK"))

(define (restore-saved-racket-env-vars! env)
  (for ([var (in-list sanitized-racket-env-vars)])
    (define saved-key (bytes-append #"_RACKUP_ORIG_" var))
    (define saved-val (environment-variables-ref env saved-key))
    (when saved-val
      (environment-variables-set! env var saved-val))
    (environment-variables-set! env saved-key #f)))
