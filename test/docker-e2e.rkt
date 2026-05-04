#lang at-exp racket/base

;; Shared Docker E2E helpers used by the Racket-ported orchestration scripts.
;; The container/image fallbacks that remote-shell/docker doesn't support
;; live in test/docker-extras.rkt — when remote-shell grows the relevant
;; flags we can drop that file and call remote-shell directly.

(require racket/format
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         recspecs
         "../libexec/rackup/text.rkt"
         "docker-extras.rkt")

(provide root-dir
         docker-build-e2e-image
         docker-run-container
         run/check
         command-output/check
         current-utc-stamp
         git-head-commit
         transcript-header
         standard-container-env
         run/container->transcript
         uid-gid
         sanitize-tag
         csv-join)

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

(define (resolve-exe prog)
  (cond
    [(path? prog) prog]
    [(absolute-path? prog) (string->path prog)]
    [(find-executable-path prog) => values]
    [else (error 'run/check "executable not found: ~a" prog)]))

(define (->string-arg a)
  (if (path? a) (path->string a) a))

;; Run a command, raising an error on failure. Subprocess output streams
;; to the current ports.
(define (run/check prog . args)
  (unless (apply system* (resolve-exe prog) (map ->string-arg args))
    (error 'run/check "command failed: ~a"
           (string-join (map ~a (cons prog args)) " "))))

;; Run a command and return trimmed stdout, raising an error (with
;; stderr appended) on failure.
(define (command-output/check prog . args)
  (define ok? #t)
  (define-values (out err)
    (capture-output/split
     (lambda ()
       (set! ok? (apply system* (resolve-exe prog) (map ->string-arg args))))))
  (unless ok?
    (error 'command-output/check
           "command failed: ~a\nstderr: ~a"
           (string-join (map ~a (cons prog args)) " ")
           (string-trim err)))
  (string-trim out))

;; Current uid:gid string for --user.
(define uid-gid
  (format "~a:~a" (command-output/check "id" "-u") (command-output/check "id" "-g")))

;; "YYYY-MM-DDTHH:MM:SSZ" for transcript headers, or compact
;; "YYYYMMDDTHHMMSSZ" for filenames.  `current-iso8601` already produces
;; the separator form; strip non-digits (preserving the trailing "Z")
;; for the filename form.
(define (current-utc-stamp #:for-filename? [for-filename? #f])
  (define iso (current-iso8601))
  (if for-filename? (regexp-replace* #px"[-:]" iso "") iso))

(define (git-head-commit)
  (command-output/check "git" "-C" (path->string root-dir) "rev-parse" "HEAD"))

(define (transcript-header #:image image-tag
                           #:host-racket host-racket
                           #:trace trace)
  @~a{rackup expanded docker transcript
      commit: @(git-head-commit)
      generated: @(current-utc-stamp)
      image: @|image-tag|
      host_racket: @|host-racket|
      trace: @|trace|

      })

;; Standard env-var alist for the container (HOME/WORKDIR/TMPDIR/PATH plus extras).
(define (standard-container-env #:home home
                                #:workdir [workdir "/work"]
                                #:trace [trace #f]
                                #:extra [extra '()])
  (append (list (cons "HOME" home)
                (cons "WORKDIR" workdir)
                (cons "TMPDIR" "/tmp")
                (cons "PATH" "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"))
          (if trace (list (cons "RACKUP_TRANSCRIPT_TRACE" trace)) '())
          extra))

;; Sanitize a string for use as a Docker tag component.
(define (sanitize-tag s)
  (regexp-replace* #rx"[^A-Za-z0-9._-]" s "-"))

;; Join strings with commas.
(define (csv-join strs)
  (string-join strs ","))

;; Thin wrapper over docker-extras' run-in-fresh-container! that fills
;; in the rackup-specific defaults (uid-gid, /tmp/rackup-e2e-home, /work).
(define (docker-run-container #:image image-tag
                              #:command command-args
                              #:platform [platform #f]
                              #:user [user uid-gid]
                              #:home [home "/tmp/rackup-e2e-home"]
                              #:volumes [volumes '()]
                              #:env-vars [env-vars '()]
                              #:extra-args [extra-args '()]
                              #:workdir [workdir "/work"])
  (run-in-fresh-container! #:image image-tag
                           #:command command-args
                           #:platform platform
                           #:user user
                           #:home home
                           #:volumes volumes
                           #:env-vars env-vars
                           #:extra-args extra-args
                           #:workdir workdir))

;; Same, with a transcript file.
(define (run/container->transcript #:image image-tag
                                   #:command command-args
                                   #:transcript-path transcript-path
                                   #:header header
                                   #:platform [platform #f]
                                   #:user [user uid-gid]
                                   #:home [home "/tmp/rackup-e2e-home"]
                                   #:volumes [volumes '()]
                                   #:env-vars [env-vars '()]
                                   #:workdir [workdir "/work"])
  (run-in-fresh-container/transcript! #:image image-tag
                                      #:command command-args
                                      #:transcript-path transcript-path
                                      #:header header
                                      #:platform platform
                                      #:user user
                                      #:home home
                                      #:volumes volumes
                                      #:env-vars env-vars
                                      #:workdir workdir))

;; Build the E2E Docker image.  Returns the image tag.
(define (docker-build-e2e-image #:image-tag image-tag
                                #:host-racket [host-racket "present"]
                                #:base-image [base-image "ubuntu:24.04"]
                                #:platform [platform #f]
                                #:use-buildx-cache? [use-buildx-cache? #f]
                                #:cache-scope [cache-scope #f]
                                #:extra-build-args [extra-build-args '()])
  (build-e2e-image! #:image-tag image-tag
                    #:dockerfile (build-path root-dir "docker" "Dockerfile.e2e")
                    #:context-dir root-dir
                    #:host-racket host-racket
                    #:base-image base-image
                    #:platform platform
                    #:use-buildx-cache? use-buildx-cache?
                    #:cache-scope cache-scope
                    #:extra-build-args extra-build-args))
