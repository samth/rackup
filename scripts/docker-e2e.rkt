#lang racket/base

;; Shared Docker E2E helpers used by the Racket-ported orchestration scripts.

(require racket/format
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system)

(provide root-dir
         docker-build-e2e-image
         docker-run-container
         run/check
         uid-gid
         sanitize-tag
         csv-join)

(define-runtime-path here ".")
(define root-dir (simplify-path (build-path here "..")))

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
  (unless (apply system* full-cmd)
    (error 'docker-build-e2e-image "docker build failed"))
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
    (append (list "docker" "run" "--rm")
            (if platform
                (list "--platform" platform)
                '())
            (list "--user" user)
            (append-map (lambda (v) (list "-v" v)) volumes)
            (append-map (lambda (e) (list "-e" (format "~a=~a" (car e) (cdr e)))) env-vars)
            (list "-e" (format "HOME=~a" home))
            (list "-w" workdir)
            extra-args
            (list image-tag)
            command-args))
  (apply system* cmd))
