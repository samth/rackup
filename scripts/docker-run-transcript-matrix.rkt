#lang racket/base

(require racket/cmdline
         racket/file
         racket/format
         racket/port
         racket/string
         racket/system
         "docker-e2e.rkt")

(provide run-transcript-matrix)

(define (run-transcript-matrix #:host-racket [host-racket "absent"]
                               #:build? [build? #t]
                               #:trace [trace "0"]
                               #:image-tag [image-tag #f]
                               #:transcript-path [transcript-path #f])
  (define actual-image-tag (or image-tag (format "rackup-e2e:~a" host-racket)))

  (define actual-transcript-path
    (or transcript-path
        (let ([stamp (string-trim (with-output-to-string (lambda ()
                                                           (system "date -u '+%Y%m%dT%H%M%SZ'"))))])
          (path->string (build-path root-dir
                                    "artifacts"
                                    "transcripts"
                                    (format "docker-transcript-matrix-~a.txt" stamp))))))

  (make-parent-directory* actual-transcript-path)

  (when build?
    (docker-build-e2e-image #:image-tag actual-image-tag #:host-racket host-racket))

  ;; Write transcript header and run container, teeing to file.
  (define commit
    (string-trim (with-output-to-string
                  (lambda () (system (format "git -C ~a rev-parse HEAD" (path->string root-dir)))))))

  (define header
    (string-join (list "rackup expanded docker transcript"
                       (format "commit: ~a" commit)
                       (format "generated: ~a"
                               (string-trim (with-output-to-string
                                             (lambda () (system "date -u '+%Y-%m-%dT%H:%M:%SZ'")))))
                       (format "image: ~a" actual-image-tag)
                       (format "host_racket: ~a" host-racket)
                       (format "trace: ~a" trace)
                       "")
                 "\n"))

  ;; Use shell pipeline to tee output to the transcript file,
  ;; matching the original: { header; docker run ... } 2>&1 | tee PATH
  (define shell-cmd
    (format "{ printf '~a\\n' ; ~a ; } 2>&1 | tee ~a"
            (regexp-replace* #rx"'" header "'\\\\''")
            (string-join (list "docker"
                               "run"
                               "--rm"
                               "--user"
                               (format "'~a'" uid-gid)
                               "-e"
                               "HOME=/tmp/rackup-transcript-home"
                               "-e"
                               (format "RACKUP_TRANSCRIPT_TRACE=~a" trace)
                               "-v"
                               (format "'~a:/work'" (path->string root-dir))
                               "-w"
                               "/work"
                               actual-image-tag
                               "bash"
                               "/work/scripts/e2e-transcript-matrix-container.sh")
                         " ")
            actual-transcript-path))

  (unless (system shell-cmd)
    (error 'docker-run-transcript-matrix "container run failed"))

  (printf "Transcript written to ~a\n" actual-transcript-path))

(module+ main
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

  (run-transcript-matrix #:host-racket host-racket
                         #:build? build?
                         #:trace trace
                         #:image-tag image-tag
                         #:transcript-path transcript-path))
