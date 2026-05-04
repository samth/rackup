#lang racket/base

(require racket/cmdline
         racket/file
         racket/format
         "docker-e2e.rkt")

(define host-racket "absent")
(define build? #t)
(define trace "0")
(define image-tag #f)
(define transcript-path #f)

(command-line #:program "docker-run-transcript-matrix"
              #:once-each ["--host-racket"
                           mode
                           "present|absent (default: absent)"
                           (unless (member mode '("present" "absent"))
                             (raise-user-error "invalid --host-racket: ~a" mode))
                           (set! host-racket mode)]
              ["--image" tag "Docker image tag" (set! image-tag tag)]
              ["--no-build" "Reuse existing image" (set! build? #f)]
              ["--trace"
               val
               "0|1 enable set -x (default: 0)"
               (unless (member val '("0" "1"))
                 (raise-user-error "invalid --trace: ~a" val))
               (set! trace val)]
              ["--transcript" path "Output transcript path" (set! transcript-path path)])

(unless image-tag
  (set! image-tag (format "rackup-e2e:~a" host-racket)))

(unless transcript-path
  (set! transcript-path
        (path->string (build-path root-dir
                                  "artifacts"
                                  "transcripts"
                                  (format "docker-transcript-matrix-~a.txt"
                                          (current-utc-stamp #:for-filename? #t))))))

(make-parent-directory* transcript-path)

(when build?
  (docker-build-e2e-image #:image-tag image-tag #:host-racket host-racket))

(define home "/tmp/rackup-transcript-home")

(run/container->transcript
 #:image image-tag
 #:command (list "bash" "/work/test/e2e-transcript-matrix-container.sh")
 #:transcript-path transcript-path
 #:header (transcript-header #:image image-tag
                             #:host-racket host-racket
                             #:trace trace)
 #:home home
 #:volumes (list (format "~a:/work" (path->string root-dir)))
 #:env-vars (standard-container-env #:home home #:trace trace))

(printf "Transcript written to ~a\n" transcript-path)
