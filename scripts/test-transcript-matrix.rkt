#lang racket/base

(require racket/runtime-path
         racket/string
         racket/file
         "docker-run-transcript-matrix.rkt")

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

(define host-racket (or (getenv "RACKUP_E2E_HOST_RACKET") "absent"))
(define trace (or (getenv "RACKUP_TRANSCRIPT_TRACE") "0"))
(define transcript-path
  (or (getenv "RACKUP_TRANSCRIPT_PATH")
      (path->string
       (build-path root-dir "artifacts" "transcripts" "docker-transcript-matrix-test.txt"))))

(make-parent-directory* transcript-path)

(printf "Running transcript matrix test...\n")
(printf "host_racket=~a\n" host-racket)
(printf "trace=~a\n" trace)
(printf "transcript=~a\n" transcript-path)

(run-transcript-matrix #:host-racket host-racket
                       #:trace trace
                       #:transcript-path transcript-path)

(printf "Asserting transcript content...\n")

(define transcript (file->string transcript-path))

(define (require-pattern pattern label)
  (unless (regexp-match? (pregexp (string-append "(?m)" pattern)) transcript)
    (eprintf "FAIL: missing expected transcript marker: ~a (~a)\n" label pattern)
    (exit 1)))

(define (reject-pattern pattern label)
  (when (regexp-match? (pregexp (string-append "(?m)" pattern)) transcript)
    (eprintf "FAIL: found error marker in transcript: ~a (~a)\n" label pattern)
    (for ([line (in-list (string-split transcript "\n"))]
          [n (in-naturals 1)])
      (when (regexp-match? (pregexp pattern) line)
        (eprintf "~a:~a\n" n line)))
    (exit 1)))

(require-pattern "== Done ==" "matrix completion")
(require-pattern "Installed release-5\\.2-bc-x86_64-linux-minimal" "legacy minimal install")
(require-pattern "Installed release-9\\.1-cs-x86_64-linux-full" "stable full install")
(require-pattern "package isolation confirmed" "package isolation check")
(require-pattern "rackup uninstalled\\." "final uninstall")
(require-pattern "release-5\\.2-bc-x86_64-linux-minimal\\s+\\(default\\)" "legacy default switch")

(reject-pattern "E2E failure:" "script failure sentinel")
(reject-pattern "^rackup: no matching installed toolchain:" "toolchain resolution errors")
(reject-pattern "unknown install flag:" "flag parser failures")
(reject-pattern "timed out" "timeout failures")
(reject-pattern "unexpected shared package visibility" "package leakage")
(reject-pattern "cannot open shared object file" "missing runtime deps surfaced in session")

(printf "Transcript matrix test PASSED\n")
