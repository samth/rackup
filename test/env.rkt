#lang racket/base

(require rackunit
         "../libexec/rackup/env.rkt")

(module+ test
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"_RACKUP_ORIG_PLTCOLLECTS" #"/tmp/colls")
  (environment-variables-set! env #"_RACKUP_ORIG_PLTADDONDIR" #"/tmp/addon")
  (restore-saved-racket-env-vars! env)
  (check-equal? (environment-variables-ref env #"PLTCOLLECTS") #"/tmp/colls")
  (check-equal? (environment-variables-ref env #"PLTADDONDIR") #"/tmp/addon")
  (check-false (environment-variables-ref env #"_RACKUP_ORIG_PLTCOLLECTS")))
