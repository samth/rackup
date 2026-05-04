#lang racket/base

;; Shared Docker E2E helpers used by the Racket-ported orchestration scripts.

(require racket/date
         racket/format
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         remote-shell/ssh)

(provide root-dir
         docker-build-e2e-image
         docker-run-container
         current-utc-stamp
         git-head-commit
         transcript-header
         standard-container-env
         run/container->transcript
         run/check
         uid-gid
         sanitize-tag
         csv-join)

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

(define localhost-remote (remote #:host "localhost"))

(define (sh-quote s)
  (string-append "'" (regexp-replace* #rx"'" s "'\\''") "'"))

(define (run/remote-shell-check cmd)
  (unless (ssh localhost-remote #:mode 'result cmd)
    (error 'run/remote-shell-check "command failed: ~a" cmd)))

(define (current-utc-stamp #:for-filename? [for-filename? #f])
  (parameterize ([date-display-format 'iso-8601])
    (define base (date->string (seconds->date (current-seconds) #t) #t))
    (if for-filename?
        (string-replace (string-replace base ":" "") "-" "")
        base)))

(define (git-head-commit)
  (string-trim
   (with-output-to-string
     (lambda ()
       (run/remote-shell-check
        (format "git -C ~a rev-parse HEAD" (sh-quote (path->string root-dir))))))))

(define (transcript-header #:image image-tag
                           #:host-racket host-racket
                           #:trace trace)
  (string-join (list "rackup expanded docker transcript"
                     (format "commit: ~a" (git-head-commit))
                     (format "generated: ~a" (current-utc-stamp))
                     (format "image: ~a" image-tag)
                     (format "host_racket: ~a" host-racket)
                     (format "trace: ~a" trace)
                     "")
               "\n"))

(define (standard-container-env #:home home
                                #:workdir [workdir "/work"]
                                #:trace [trace #f]
                                #:extra [extra '()])
  (append (list (cons "HOME" home)
                (cons "WORKDIR" workdir)
                (cons "TMPDIR" "/tmp")
                (cons "PATH" "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"))
          (if trace
              (list (cons "RACKUP_TRANSCRIPT_TRACE" trace))
              '())
          extra))

(define (docker-run-argv #:image image-tag
                         #:command command-args
                         #:platform [platform #f]
                         #:user [user uid-gid]
                         #:home [home "/tmp/rackup-e2e-home"]
                         #:volumes [volumes '()]
                         #:env-vars [env-vars '()]
                         #:extra-args [extra-args '()]
                         #:workdir [workdir "/work"])
  (append (list "docker" "run" "--rm")
          (if platform (list "--platform" platform) '())
          (list "--user" user)
          (append-map (lambda (v) (list "-v" v)) volumes)
          (append-map (lambda (e) (list "-e" (format "~a=~a" (car e) (cdr e)))) env-vars)
          (list "-e" (format "HOME=~a" home))
          (list "-w" workdir)
          extra-args
          (list image-tag)
          command-args))

(define (run/container->transcript #:image image-tag
                                   #:command command-args
                                   #:transcript-path transcript-path
                                   #:header header
                                   #:platform [platform #f]
                                   #:user [user uid-gid]
                                   #:home [home "/tmp/rackup-e2e-home"]
                                   #:volumes [volumes '()]
                                   #:env-vars [env-vars '()]
                                   #:extra-args [extra-args '()]
                                   #:workdir [workdir "/work"])
  (call-with-output-file transcript-path
    (lambda (out)
      (display header out))
    #:exists 'truncate/replace)
  (define docker-cmd
    (docker-run-argv #:image image-tag
                     #:command command-args
                     #:platform platform
                     #:user user
                     #:home home
                     #:volumes volumes
                     #:env-vars env-vars
                     #:extra-args extra-args
                     #:workdir workdir))
  (run/remote-shell-check
   (format "~a 2>&1 | tee -a ~a"
           (string-join (map sh-quote docker-cmd) " ")
           (sh-quote (path->string transcript-path)))))

;; Run a command, raising an error on failure.
(define (run/check prog . args)
  (define cmd (cons prog args))
  (unless (apply system*
                 (if (path? prog)
                     (path->string prog)
                     prog)
                 (map (lambda (a)
                        (if (path? a)
                            (path->string a)
                            a))
                      args))
    (error 'run/check "command failed: ~a" (string-join (map ~a cmd) " "))))

;; Current uid:gid string for --user.
(define uid-gid
  (string-trim (with-output-to-string (lambda ()
                                        (system "printf '%s:%s' \"$(id -u)\" \"$(id -g)\"")))))

;; Sanitize a string for use as a Docker tag component.
(define (sanitize-tag s)
  (regexp-replace* #rx"[^A-Za-z0-9._-]" s "-"))

;; Join strings with commas.
(define (csv-join strs)
  (string-join strs ","))

;; Build the E2E Docker image.
;; Returns the image tag used.
(define (docker-build-e2e-image #:image-tag image-tag
                                #:host-racket [host-racket "present"]
                                #:base-image [base-image "ubuntu:24.04"]
                                #:platform [platform #f]
                                #:use-buildx-cache? [use-buildx-cache? #f]
                                #:cache-scope [cache-scope #f]
                                #:extra-build-args [extra-build-args '()])
  (define include-system-racket (if (equal? host-racket "present") "1" "0"))
  (define build-cmd
    (if use-buildx-cache?
        (append (list "docker" "buildx" "build" "--load")
                (if cache-scope
                    (list (format "--cache-from=type=gha,scope=~a" cache-scope)
                          (format "--cache-to=type=gha,scope=~a,mode=max" cache-scope))
                    '()))
        (list "docker" "build")))
  (define build-args
    (append (list "--build-arg"
                  (format "BASE_IMAGE=~a" base-image)
                  "--build-arg"
                  (format "INCLUDE_SYSTEM_RACKET=~a" include-system-racket))
            extra-build-args))
  (define platform-args
    (if platform
        (list "--platform" platform)
        '()))
  (define full-cmd
    (append build-cmd
            platform-args
            build-args
            (list "-t"
                  image-tag
                  "-f"
                  (path->string (build-path root-dir "docker" "Dockerfile.e2e"))
                  (path->string root-dir))))
  (printf "Building Docker image ~a (base=~a, platform=~a)...\n"
          image-tag
          base-image
          (or platform "native"))
  (run/remote-shell-check
   (string-join (map sh-quote full-cmd) " "))
  image-tag)

;; Run a container with standard options.
;; volumes: list of "host:container[:mode]" strings
;; env-vars: list of (name . value) pairs
;; extra-args: additional docker run args before the command
(define (docker-run-container #:image image-tag
                              #:command command-args
                              #:platform [platform #f]
                              #:user [user uid-gid]
                              #:home [home "/tmp/rackup-e2e-home"]
                              #:volumes [volumes '()]
                              #:env-vars [env-vars '()]
                              #:extra-args [extra-args '()]
                              #:workdir [workdir "/work"])
  (define cmd
    (docker-run-argv #:image image-tag
                     #:command command-args
                     #:platform platform
                     #:user user
                     #:home home
                     #:volumes volumes
                     #:env-vars env-vars
                     #:extra-args extra-args
                     #:workdir workdir))
  (ssh localhost-remote #:mode 'result (string-join (map sh-quote cmd) " ")) )
