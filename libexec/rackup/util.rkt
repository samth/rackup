#lang racket/base

(require file/sha1
         racket/date
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system)

(provide rackup-error
         ensure-directory*
         replace-path!
         path->string*
         string-blank?
         executable-file?
         resolve-command-path
         system*/check
         shell-exe
         capture-program-output
         probe-local-racket-version+variant+addon-dir
         current-iso8601
         path-basename-string
         http-url?
         require-checksummed-http-installer!
         file-sha256
         file-sha1
         verify-installer-sha256!
         verify-installer-checksum!
         valid-toolchain-id?
         ensure-valid-toolchain-id!
         valid-pkg-name?
         string-has-control-char?
         ensure-string-without-control-chars!
         ensure-path-without-control-chars!
         sh-single-quote
         env-var-export-line
         color-enabled?
         ansi
         sanitized-racket-env-vars
         restore-saved-racket-env-vars!)

(define (rackup-error fmt . args)
  (raise-user-error 'rackup (apply format fmt args)))

(define (ensure-directory* p)
  (make-directory* p)
  p)

;; Replace the filesystem entry at `dest` with `src` using explicit mode:
;; - #:mode 'link      => create symlink at `dest` pointing to `src`
;; - #:mode 'file      => copy file bytes/permissions from `src` to `dest`
;; - #:mode 'directory => recursively copy directory tree from `src` to `dest`
;;
;; Existing links/files/directories at `dest` are removed first. This is
;; intentionally destructive and non-transactional: if the final creation/copy
;; fails, `dest` remains absent. Any deletion or creation failure raises the
;; originating filesystem exception.
(define (replace-path! dest src #:mode [mode 'link])
  (when (link-exists? dest)
    (delete-file dest))
  (when (file-exists? dest)
    (delete-file dest))
  (when (directory-exists? dest)
    (delete-directory/files dest))
  (case mode
    [(link) (make-file-or-directory-link src dest)]
    [(file) (copy-file src dest #t)]
    [(directory) (copy-directory/files src dest #t)]
    [else
     (raise-argument-error 'replace-path! "(or/c 'link 'file 'directory)" mode)]))

(define (path->string* p)
  (cond
    [(path? p) (path->string p)]
    [(string? p) p]
    [else (format "~a" p)]))

(define (string-blank? s)
  (string=? "" (string-trim s)))

(define (executable-file? p)
  (and (file-exists? p)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (member 'execute (file-or-directory-permissions p)))))

(define (resolve-command-path cmd path-string)
  (cond
    [(or (path? cmd)
         (and (string? cmd) (regexp-match? #px"/" cmd)))
     cmd]
    [else
     (for/or ([dir (in-list (string-split (or path-string "") ":" #:trim? #f))])
       (define base
         (if (string-blank? dir)
             (current-directory)
             (string->path dir)))
       (define candidate (build-path base (format "~a" cmd)))
       (and (executable-file? candidate) candidate))]))

(define (system*/check who . args)
  (define ok? (apply system* args))
  (unless ok?
    (rackup-error "~a failed: ~a" who (string-join (map path->string* args) " "))))

(define (shell-exe)
  (or (find-executable-path "sh") (string->path "/bin/sh")))

(define (pad2 n)
  (~r n #:min-width 2 #:pad-string "0"))

(define (pad4 n)
  (~r n #:min-width 4 #:pad-string "0"))

(define (current-iso8601)
  (define d (seconds->date (current-seconds) #t))
  (string-append (pad4 (date-year d))
                 "-"
                 (pad2 (date-month d))
                 "-"
                 (pad2 (date-day d))
                 "T"
                 (pad2 (date-hour d))
                 ":"
                 (pad2 (date-minute d))
                 ":"
                 (pad2 (date-second d))
                 "Z"))

(define (path-basename-string p)
  (define name (file-name-from-path p))
  (if name
      (path->string name)
      (path->string* p)))

(define (->env-bytes v)
  (and v
       (if (bytes? v)
           v
           (string->bytes/utf-8 (format "~a" v)))))

(define (capture-program-output #:env [env-vars null] exe . args)
  (define env (environment-variables-copy (current-environment-variables)))
  (for ([kv (in-list env-vars)])
    (environment-variables-set! env
                                (string->bytes/utf-8 (format "~a" (car kv)))
                                (->env-bytes (cdr kv))))
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-environment-variables env]
                 [current-output-port out]
                 [current-error-port err])
    (if (apply system* exe args)
        (string-trim (get-output-string out))
        #f)))

;; Probe a local Racket binary for its version, variant ('cs/'bc), and
;; native addon-dir.  Returns three values, any of which may be #f if
;; the probe fails (e.g., the binary cannot run).  `env-vars` is an
;; alist of additional environment to apply for the probe.
(define (probe-local-racket-version+variant+addon-dir bin-dir env-vars)
  (define racket-exe (build-path (string->path bin-dir) "racket"))
  (define combined-out
    (capture-program-output
     #:env env-vars
     racket-exe
     "-e"
     (string-append
      "(displayln (version))"
      "(displayln (let ([v (system-type 'vm)])"
      "  (if (symbol? v) (symbol->string v) (format \"~a\" v))))"
      "(display (find-system-path 'addon-dir))")))
  (define (normalize-vm-name s)
    (and s (not (string-blank? s))
         (match (string-downcase s)
           ["chez-scheme" "cs"]
           ["racket" "bc"]
           [v v])))
  (define-values (version-out variant-out addon-out)
    (if combined-out
        (let ([lines (string-split combined-out "\n")])
          (if (>= (length lines) 3)
              (values (first lines) (second lines)
                      (string-join (drop lines 2) "\n"))
              (values #f #f #f)))
        (values #f #f #f)))
  (values (and version-out (not (string-blank? version-out)) version-out)
          (normalize-vm-name variant-out)
          (and addon-out (not (string-blank? addon-out)) addon-out)))

(define (http-url? s)
  (and (string? s) (regexp-match? #px"(?i:^http://)" s)))

(define (require-checksummed-http-installer! installer-url expected-sha256)
  (when (and (http-url? installer-url)
             (or (not (string? expected-sha256))
                 (string-blank? expected-sha256)))
    (rackup-error
     "refusing to download installer over HTTP without a hardcoded SHA-256 checksum: ~a"
     installer-url)))

(define (sha256-exe)
  (cond
    [(find-executable-path "sha256sum") => (lambda (p) (cons 'sha256sum p))]
    [(find-executable-path "shasum") => (lambda (p) (cons 'shasum p))]
    [(find-executable-path "openssl") => (lambda (p) (cons 'openssl p))]
    [else #f]))

(define (sha256-capture-string who . args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-output-port out]
                 [current-error-port err])
    (if (apply system* args)
        (string-trim (get-output-string out))
        (rackup-error "~a failed: ~a~a"
                      who
                      (string-join (map path->string* args) " ")
                      (let ([e (string-trim (get-output-string err))])
                        (if (string-blank? e) "" (string-append "\n" e)))))))

(define (file-sha256 p)
  (match (sha256-exe)
    [(cons 'sha256sum exe)
     (car (string-split (sha256-capture-string 'sha256sum exe p)))]
    [(cons 'shasum exe)
     (car (string-split (sha256-capture-string 'shasum exe "-a" "256" p)))]
    [(cons 'openssl exe)
     (last (string-split (sha256-capture-string 'openssl exe "dgst" "-sha256" p)))]
    [_ (rackup-error "could not find sha256sum, shasum, or openssl to verify downloads")]))

(define (verify-installer-sha256! installer-path expected-sha256)
  (when expected-sha256
    (define actual-sha256 (file-sha256 installer-path))
    (unless (equal? (string-downcase actual-sha256) (string-downcase expected-sha256))
      (rackup-error "download checksum mismatch for ~a\nexpected: ~a\nactual:   ~a"
                    (path->string* installer-path)
                    expected-sha256
                    actual-sha256))))

(define (file-sha1 p)
  (call-with-input-file p sha1))

(define (verify-installer-checksum! installer-path
                                    #:sha256 [expected-sha256 #f]
                                    #:sha1 [expected-sha1 #f])
  (cond
    [expected-sha256
     (verify-installer-sha256! installer-path expected-sha256)]
    [expected-sha1
     (define actual (file-sha1 installer-path))
     (unless (equal? (string-downcase actual) (string-downcase expected-sha1))
       (rackup-error "download checksum mismatch (SHA1) for ~a\nexpected: ~a\nactual:   ~a"
                     (path->string* installer-path)
                     expected-sha1
                     actual))]))

;; Toolchain ID validation: positive allowlist
(define toolchain-id-rx #px"^[A-Za-z0-9._-]+$")

(define (valid-toolchain-id? s)
  (and (string? s)
       (not (string-blank? s))
       (regexp-match? toolchain-id-rx s)))

(define (ensure-valid-toolchain-id! s [what "toolchain id"])
  (unless (valid-toolchain-id? s)
    (rackup-error "invalid ~a: ~v" what s))
  s)

;; Package name validation: positive allowlist matching Racket's pkg
;; name rules.  Used to filter stray tokens out of `raco pkg show`
;; output before passing them to `raco pkg install`.
(define (valid-pkg-name? s)
  (and (string? s)
       (not (string-blank? s))
       (regexp-match? #px"^[a-zA-Z0-9][a-zA-Z0-9_.+-]*$" s)))

;; Control character detection
(define (string-has-control-char? s)
  (and (string? s)
       (for/or ([ch (in-string s)])
         (or (char<? ch #\space) (char=? ch #\rubout)))))

(define (ensure-string-without-control-chars! s what)
  (when (string-has-control-char? s)
    (rackup-error "refusing unsafe ~a with control characters" what))
  s)

(define (ensure-path-without-control-chars! p what)
  (ensure-string-without-control-chars! (path->string* p) what)
  p)

(define (sh-single-quote s)
  (define str (format "~a" s))
  (string-append "'" (regexp-replace* #px"'" str "'\"'\"'") "'"))

;; Produce a shell `export` line for an env-var pair.
;; env.sh is sourced by the shim dispatcher, scoped to each invocation.
;; All variables are exported unconditionally.
(define (env-var-export-line key value)
  (format "export ~a=~a\n" key (sh-single-quote value)))

;; Racket env vars that bin/rackup saves as _RACKUP_ORIG_* and clears
;; so the hidden runtime is not affected. restore-saved-racket-env-vars!
;; puts them back for user toolchain subprocesses (rackup run).
(define sanitized-racket-env-vars
  '("PLTCOLLECTS" "PLTADDONDIR" "PLTCOMPILEDROOTS"
    "PLTUSERHOME" "RACKET_XPATCH" "PLT_COMPILED_FILE_CHECK"))

(define (restore-saved-racket-env-vars! env)
  (for ([var (in-list sanitized-racket-env-vars)])
    (define saved-key (string->bytes/utf-8 (string-append "_RACKUP_ORIG_" var)))
    (define saved-val (environment-variables-ref env saved-key))
    (when saved-val
      (environment-variables-set! env (string->bytes/utf-8 var) saved-val))
    (environment-variables-set! env saved-key #f)))

(define (color-enabled?)
  (and (terminal-port? (current-output-port)) (not (getenv "NO_COLOR"))))

(define (ansi code s)
  (if (color-enabled?)
      (string-append "\e[" code "m" s "\e[0m")
      s))
