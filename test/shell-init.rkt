#lang racket/base

;; `rackup init` writes the rackup block into the right startup files, and
;; uninstall removes it from all of them.  A login bash (every new macOS
;; Terminal window) reads ~/.bash_profile, ~/.bash_login, or ~/.profile,
;; never ~/.bashrc, so init must cover that file too.

(require rackunit
         racket/file
         racket/string
         "../libexec/rackup/shell.rkt")

;; Run proc with a scratch home directory (via current-home-dir, not HOME,
;; which find-system-path does not reread) and a scratch RACKUP_HOME.
(define (with-temp-homes proc)
  (define home (make-temporary-file "rackup-init-home-~a" 'directory))
  (define rackup-home (make-temporary-file "rackup-init-rh-~a" 'directory))
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string rackup-home)))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-environment-variables env]
                    [current-home-dir home])
       (proc home)))
   (lambda ()
     (delete-directory/files home #:must-exist? #f)
     (delete-directory/files rackup-home #:must-exist? #f))))

(define (has-block? p)
  (and (file-exists? p) (string-contains? (file->string p) "# >>> rackup initialize >>>")))

(define (block-count p)
  (length (regexp-match* #rx"# >>> rackup initialize >>>" (file->string p))))

(define (names home)
  (sort (for/list ([n (in-list '(".bashrc" ".zshrc" ".bash_profile" ".bash_login" ".profile"))]
                   #:when (has-block? (build-path home n)))
          n)
        string<?))

(module+ test
  ;; macOS, no login file yet: create ~/.bash_profile alongside ~/.bashrc.
  (with-temp-homes (lambda (home)
                     (parameterize ([current-macos? #t])
                       (check-equal? (length (init-shell! "bash")) 2))
                     (check-equal? (names home) '(".bash_profile" ".bashrc"))))

  ;; Elsewhere, no login file: only ~/.bashrc; never create ~/.bash_profile.
  (with-temp-homes (lambda (home)
                     (parameterize ([current-macos? #f])
                       (init-shell! "bash"))
                     (check-equal? (names home) '(".bashrc"))
                     (check-false (file-exists? (build-path home ".bash_profile")))))

  ;; An existing ~/.profile is the login file; it keeps its content and
  ;; no ~/.bash_profile appears to shadow it.
  (with-temp-homes (lambda (home)
                     (write-to-file "existing" (build-path home ".profile") #:mode 'text)
                     (parameterize ([current-macos? #f])
                       (init-shell! "bash"))
                     (check-equal? (names home) '(".bashrc" ".profile"))
                     (check-true (string-contains? (file->string (build-path home ".profile"))
                                                   "existing"))
                     (check-false (file-exists? (build-path home ".bash_profile")))))

  ;; ~/.bash_profile wins over ~/.profile, as in bash itself.
  (with-temp-homes (lambda (home)
                     (write-to-file "a" (build-path home ".bash_profile") #:mode 'text)
                     (write-to-file "b" (build-path home ".profile") #:mode 'text)
                     (parameterize ([current-macos? #t])
                       (init-shell! "bash"))
                     (check-equal? (names home) '(".bash_profile" ".bashrc"))))

  ;; zsh reads ~/.zshrc in login and non-login interactive shells alike.
  (with-temp-homes (lambda (home)
                     (parameterize ([current-macos? #t])
                       (check-equal? (length (init-shell! "zsh")) 1))
                     (check-equal? (names home) '(".zshrc"))))

  ;; Running init again replaces the block instead of adding another.
  (with-temp-homes (lambda (home)
                     (parameterize ([current-macos? #t])
                       (init-shell! "bash")
                       (init-shell! "bash"))
                     (check-equal? (block-count (build-path home ".bashrc")) 1)
                     (check-equal? (block-count (build-path home ".bash_profile")) 1)))

  ;; Uninstall's cleanup removes the block from every file, keeping the rest.
  (with-temp-homes (lambda (home)
                     (write-to-file "existing" (build-path home ".profile") #:mode 'text)
                     (parameterize ([current-macos? #f])
                       (init-shell! "bash")
                       (init-shell! "zsh"))
                     (check-equal? (names home) '(".bashrc" ".profile" ".zshrc"))
                     (remove-shell-init-blocks!)
                     (check-equal? (names home) '())
                     (check-true (string-contains? (file->string (build-path home ".profile"))
                                                   "existing")))))
