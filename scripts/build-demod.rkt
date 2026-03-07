#lang racket/base

;; Build demodularized .zo from rackup-core.rkt
;;
;; Usage: racket -y scripts/build-demod.rkt LIBEXEC_DIR
;;
;; Flags used with raco demod:
;;   -s  preserve syntax (required for define-runtime-path)
;;   -r  recompile for optimization
;;   -o  explicit output path into compiled/ directory

(require racket/file
         racket/path
         racket/system)

(define libexec-dir
  (let ([args (current-command-line-arguments)])
    (when (zero? (vector-length args))
      (eprintf "Usage: build-demod.rkt LIBEXEC_DIR\n")
      (exit 2))
    (vector-ref args 0)))

(define core (build-path libexec-dir "rackup-core.rkt"))

(unless (file-exists? core)
  (eprintf "build-demod.rkt: rackup-core.rkt not found at ~a\n" core)
  (exit 1))

(define merged (build-path libexec-dir "compiled" "rackup-core_rkt_merged.zo"))
(make-directory* (path-only merged))

(unless (system* (find-executable-path "raco")
                 "demod"
                 "-s"
                 "-r"
                 "-o"
                 (path->string merged)
                 (path->string core))
  (eprintf "build-demod.rkt: raco demod failed\n")
  (exit 1))

(unless (file-exists? merged)
  (eprintf "build-demod.rkt: expected output not found at ~a\n" merged)
  (exit 1))

(printf "build-demod.rkt: created ~a\n" merged)
