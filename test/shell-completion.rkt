#lang racket/base

(require rackunit
         racket/string
         "../libexec/rackup/shell.rkt")

(define (contains? haystack needle)
  (regexp-match? (regexp-quote needle) haystack))

(module+ test
  (define bash-output (shell-helper-script "bash"))
  (define zsh-output (shell-helper-script "zsh"))

  ;; Bash output contains bash completion registration
  (check-true (contains? bash-output "complete -F _rackup rackup"))

  ;; Zsh output contains zsh completion registration
  (check-true (contains? zsh-output "compdef _rackup rackup"))

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

  ;; Both contain the shell wrapper function
  (check-true (contains? bash-output "rackup()"))
  (check-true (contains? zsh-output "rackup()"))

  ;; Bash has bash-specific constructs
  (check-true (contains? bash-output "COMP_WORDS"))
  (check-true (contains? bash-output "COMPREPLY"))

  ;; Zsh has zsh-specific constructs
  (check-true (contains? zsh-output "_describe"))
  (check-true (contains? zsh-output "_arguments"))

  ;; Bash flag-argument completions
  (check-true (contains? bash-output "\"cs bc\"") "bash completion missing --variant values")
  (check-true (contains? bash-output "\"full minimal\"") "bash completion missing --distribution values")
  (check-true (contains? bash-output "\"auto utah northwestern\"") "bash completion missing --snapshot-site values")
  (check-true (contains? bash-output "\"x86_64 aarch64 i386 arm riscv64 ppc\"") "bash completion missing --arch values")
  (check-true (contains? bash-output "\"bash zsh\"") "bash completion missing --shell values")

  ;; Zsh structured _arguments for install
  (check-true (contains? zsh-output "'--variant[VM variant]:variant:(cs bc)'") "zsh completion missing --variant spec")
  (check-true (contains? zsh-output "'--distribution[Distribution type]:distribution:(full minimal)'") "zsh completion missing --distribution spec")
  (check-true (contains? zsh-output "'--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)'") "zsh completion missing --arch spec")

  ;; Zsh structured _arguments for init
  (check-true (contains? zsh-output "'--shell[Shell type]:shell:(bash zsh)'") "zsh completion missing --shell spec for init"))
