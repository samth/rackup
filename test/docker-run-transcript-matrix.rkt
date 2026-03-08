#lang racket/base

(require racket/cmdline
         racket/file
         racket/format
         racket/port
         racket/string
         racket/system
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
  (define stamp
    (string-trim (with-output-to-string (lambda () (system "date -u '+%Y%m%dT%H%M%SZ'")))))
  (set! transcript-path
        (path->string (build-path root-dir
                                  "artifacts"
                                  "transcripts"
                                  (format "docker-transcript-matrix-~a.txt" stamp)))))

(make-parent-directory* transcript-path)

(when build?
  (docker-build-e2e-image #:image-tag image-tag #:host-racket host-racket))

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
                     (format "image: ~a" image-tag)
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
                             image-tag
                             "bash"
                             "/work/test/e2e-transcript-matrix-container.sh")
                       " ")
          transcript-path))

(unless (system shell-cmd)
  (error 'docker-run-transcript-matrix "container run failed"))

(printf "Transcript written to ~a\n" transcript-path)
