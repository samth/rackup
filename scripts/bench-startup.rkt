#lang racket/base

;; Benchmark rackup startup time: per-module .zo vs demodularized .zo
;;
;; Usage: racket -y scripts/bench-startup.rkt [ITERATIONS]
;;   Run from the rackup repo root.

(require racket/port
         racket/runtime-path
         racket/string
         racket/system)

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))
(define libexec-dir (build-path root-dir "libexec"))
(define core-rkt (build-path libexec-dir "rackup-core.rkt"))
(define merged-zo (build-path libexec-dir "compiled" "rackup-core_rkt_merged.zo"))
(define build-demod (build-path root-dir "scripts" "build-demod.sh"))

(define iterations
  (let ([args (current-command-line-arguments)])
    (if (> (vector-length args) 0)
        (string->number (vector-ref args 0))
        10)))

(define racket-exe (find-executable-path "racket"))

(define (bench label . cmd+args)
  (printf "\n=== ~a ===\n" label)
  ;; warm-up
  (parameterize ([current-output-port (open-output-nowhere)]
                 [current-error-port (open-output-nowhere)])
    (apply system* (append cmd+args (list "version"))))
  (define times
    (for/list ([i (in-range iterations)])
      (define start (current-inexact-monotonic-milliseconds))
      (parameterize ([current-output-port (open-output-nowhere)]
                     [current-error-port (open-output-nowhere)])
        (apply system* (append cmd+args (list "version"))))
      (define elapsed (- (current-inexact-monotonic-milliseconds) start))
      (printf "  run ~a: ~a ms\n" (add1 i) (inexact->exact (round elapsed)))
      elapsed))
  (define avg (/ (apply + times) iterations))
  (printf "  avg: ~a ms (~a iterations)\n" (inexact->exact (round avg)) iterations))

;; Mode 1: per-module .zo (current approach)
(printf "Preparing Mode 1: compiling per-module .zo from source...\n")
(unless (system* racket-exe
                 "-l-"
                 "compiler/cm"
                 "-e"
                 (format "(managed-compile-zo (path->complete-path ~s))" (path->string core-rkt)))
  (error 'bench "failed to compile per-module .zo"))

(bench "Mode 1: Source .rkt (per-module machine-dependent .zo)"
       racket-exe
       "-U"
       (path->string core-rkt))

;; Mode 2: demodularized .zo
(unless (file-exists? merged-zo)
  (printf "\nBuilding demodularized .zo...\n")
  (unless (system* build-demod (path->string libexec-dir))
    (error 'bench "failed to build demod .zo")))

(bench "Mode 2: Demodularized machine-dependent .zo" racket-exe "-U" (path->string merged-zo))

(printf "\nDone.\n")
