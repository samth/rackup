#lang racket/base

;; Docker operations that remote-shell/docker doesn't (yet) expose.
;; Tracked as gaps in https://github.com/samth/rackup/issues/84.
;; When remote-shell grows the corresponding flags, callers can switch
;; over without reaching into the docker CLI here.
;;
;;   docker exec --user / --workdir
;;     remote-shell's docker-exec doesn't surface either, so we shell
;;     out via `subprocess` for the one-shot exec used by E2E runs.
;;
;;   docker build --build-arg / --file / --platform / cache-from / cache-to
;;     none are exposed by remote-shell's docker-build, so the E2E
;;     image build shells out via `system*`.

(require racket/format
         racket/path
         racket/port
         racket/string
         racket/system
         remote-shell/docker)

(provide with-fresh-container/exec
         run-in-fresh-container!
         run-in-fresh-container/transcript!
         build-e2e-image!)

(define docker-exe (find-executable-path "docker"))

(define (->string-arg a) (if (path? a) (path->string a) a))

(define (resolve-exe prog)
  (cond
    [(path? prog) prog]
    [(absolute-path? prog) (string->path prog)]
    [(find-executable-path prog) => values]
    [else (error 'docker-extras "executable not found: ~a" prog)]))

(define (parse-volume-spec s)
  ;; "host:container[:mode]" → (list host container mode) for docker-create.
  (define parts (string-split s ":"))
  (case (length parts)
    [(2) (list (car parts) (cadr parts) 'rw)]
    [(3) (list (car parts) (cadr parts) (string->symbol (caddr parts)))]
    [else (error 'parse-volume-spec "expected host:container[:mode], got ~v" s)]))

(define (env-vars->hash env-vars home)
  (for/fold ([h (hasheq)]
             #:result (hash-set h "HOME" home))
            ([kv (in-list env-vars)])
    (hash-set h (format "~a" (car kv)) (format "~a" (cdr kv)))))

(define (fresh-container-name [prefix "rackup-e2e"])
  (format "~a-~a-~a" prefix (random 1000000000) (random 1000000000)))

;; Run `command-args` in a fresh container started from `image-tag`,
;; piping its merged stdout/stderr through `output-handler`.  The
;; container is removed in the cleanup phase.
(define (with-fresh-container/exec image-tag command-args output-handler
                                   #:platform platform
                                   #:user user
                                   #:home home
                                   #:volumes volumes
                                   #:env-vars env-vars
                                   #:workdir workdir
                                   #:who who)
  (define name (fresh-container-name))
  (docker-create #:name name
                 #:image-name image-tag
                 #:platform platform
                 #:volumes (map parse-volume-spec volumes)
                 #:envvars (env-vars->hash env-vars home)
                 #:replace? #t)
  (dynamic-wind
   (lambda () (docker-start #:name name))
   (lambda ()
     (define-values (sp stdout stdin stderr)
       (apply subprocess
              #f #f 'stdout docker-exe
              "exec" "--user" user "-w" workdir name
              (map ->string-arg command-args)))
     (close-output-port stdin)
     (define copy-thread (thread (lambda () (output-handler stdout))))
     (subprocess-wait sp)
     (thread-wait copy-thread)
     (close-input-port stdout)
     (unless (zero? (subprocess-status sp))
       (error who "container exec exited with status ~a" (subprocess-status sp))))
   (lambda ()
     (when (docker-running? #:name name)
       (docker-stop #:name name))
     (with-handlers ([exn:fail? void]) (docker-remove #:name name)))))

;; Run a one-shot command in a fresh container, streaming output to the
;; current output port.  Returns #t on success; raises on failure.
(define (run-in-fresh-container! #:image image-tag
                                 #:command command-args
                                 #:platform [platform #f]
                                 #:user user
                                 #:home home
                                 #:volumes [volumes '()]
                                 #:env-vars [env-vars '()]
                                 #:extra-args [extra-args '()]
                                 #:workdir [workdir "/work"])
  (when (pair? extra-args)
    (error 'run-in-fresh-container! "extra-args is not supported with the remote-shell backend"))
  (with-fresh-container/exec image-tag command-args
                             (lambda (port) (copy-port port (current-output-port)))
                             #:platform platform
                             #:user user
                             #:home home
                             #:volumes volumes
                             #:env-vars env-vars
                             #:workdir workdir
                             #:who 'run-in-fresh-container!)
  #t)

;; Same as run-in-fresh-container! but also tee output into a transcript file.
(define (run-in-fresh-container/transcript! #:image image-tag
                                            #:command command-args
                                            #:transcript-path transcript-path
                                            #:header header
                                            #:platform [platform #f]
                                            #:user user
                                            #:home home
                                            #:volumes [volumes '()]
                                            #:env-vars [env-vars '()]
                                            #:workdir [workdir "/work"])
  (call-with-output-file transcript-path
    #:exists 'truncate/replace
    (lambda (out)
      (display header out)
      (with-fresh-container/exec image-tag command-args
                                 (lambda (port) (copy-port port out (current-output-port)))
                                 #:platform platform
                                 #:user user
                                 #:home home
                                 #:volumes volumes
                                 #:env-vars env-vars
                                 #:workdir workdir
                                 #:who 'run-in-fresh-container/transcript!))))

;; Build the E2E Docker image with --build-arg/--file/--platform plus
;; optional buildx GHA cache flags.  Returns the image tag.
(define (build-e2e-image! #:image-tag image-tag
                          #:dockerfile dockerfile
                          #:context-dir context-dir
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
  (define full-cmd
    (append build-cmd
            (if platform (list "--platform" platform) '())
            (list "--build-arg" (format "BASE_IMAGE=~a" base-image)
                  "--build-arg" (format "INCLUDE_SYSTEM_RACKET=~a" include-system-racket))
            extra-build-args
            (list "-t" image-tag
                  "-f" (path->string dockerfile)
                  (path->string context-dir))))
  (printf "Building Docker image ~a (base=~a, platform=~a)...\n"
          image-tag base-image (or platform "native"))
  (unless (apply system* (resolve-exe (car full-cmd)) (cdr full-cmd))
    (error 'build-e2e-image! "docker build failed"))
  image-tag)
