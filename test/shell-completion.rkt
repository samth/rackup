#lang at-exp racket/base

(require rackunit
         recspecs
         racket/string
         "../libexec/rackup/shell.rkt")

(define (contains? haystack needle)
  (regexp-match? (regexp-quote needle) haystack))

(module+ test
  (define bash-output (shell-helper-script "bash"))
  (define zsh-output (shell-helper-script "zsh"))

  ;; Record full output for each shell helper script.
  ;; These expectations auto-update with RECSPECS_UPDATE=1.
  (expect (display bash-output) (string-copy bash-output))
  (expect (display zsh-output) (string-copy zsh-output))

  ;; Both contain all command names
  (for ([cmd '("available" "install"
                           "link"
                           "list"
                           "default"
                           "current"
                           "which"
                           "switch"
                           "shell"
                           "run"
                           "prompt"
                           "remove"
                           "reshim"
                           "init"
                           "uninstall"
                           "self-upgrade"
                           "runtime"
                           "doctor"
                           "version"
                           "help")])
    (check-true (contains? bash-output cmd) (format "bash completion missing command: ~a" cmd))
    (check-true (contains? zsh-output cmd) (format "zsh completion missing command: ~a" cmd)))

  ;; Bash and zsh outputs differ (shell-specific completions)
  (check-false (equal? bash-output zsh-output))

  ;; Bash has bash-specific constructs
  (check-true (contains? bash-output "complete -F _rackup rackup"))
  (check-true (contains? bash-output "rackup()"))
  (check-true (contains? bash-output "COMP_WORDS"))
  (check-true (contains? bash-output "COMPREPLY"))

  ;; Zsh has zsh-specific constructs
  (check-true (contains? zsh-output "compdef _rackup rackup"))
  (check-true (contains? zsh-output "rackup()"))
  (check-true (contains? zsh-output "_describe"))
  (check-true (contains? zsh-output "_arguments")))
