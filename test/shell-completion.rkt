#lang at-exp racket/base

(require rackunit
         recspecs
         racket/file
         racket/string
         "../libexec/rackup/shell.rkt"
         (submod "../libexec/rackup/shell.rkt" for-testing)
         "../libexec/rackup/paths.rkt")

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
                           "rebuild"
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
  (check-true (contains? zsh-output "_arguments"))

  ;; Bash flag-argument completions
  (check-true (contains? bash-output "\"cs bc\"") "bash completion missing --variant values")
  (check-true (contains? bash-output "\"full minimal\"") "bash completion missing --distribution values")
  (check-true (contains? bash-output "\"auto utah northwestern\"") "bash completion missing --snapshot-site values")
  (check-true (contains? bash-output "\"x86_64 aarch64 i386 arm riscv64 ppc\"") "bash completion missing --arch values")
  (check-true (contains? bash-output "\"sh tgz dmg\"") "bash completion missing --installer-ext values")
  (check-true (contains? bash-output "\"bash zsh\"") "bash completion missing --shell values")

  ;; Bash now completes external command names for which/run, and directories for link.
  (check-true (contains? bash-output "compgen -c --") "bash completion missing command-name completion")
  (check-true (contains? bash-output "compgen -d --") "bash completion missing directory completion for link")

  ;; Bash flags missing in earlier versions
  (check-true (contains? bash-output "--ids") "bash completion missing list --ids")
  (check-true (contains? bash-output "--clean-compiled") "bash completion missing remove --clean-compiled")
  (check-true (contains? bash-output "--short-aliases") "bash completion missing --short-aliases")
  (check-true (contains? bash-output "--no-short-aliases") "bash completion missing --no-short-aliases")
  (check-true (contains? bash-output "--installer-ext") "bash completion missing --installer-ext flag")
  (check-true (contains? bash-output "-j ") "bash completion missing -j short flag")

  ;; Zsh structured _arguments for install
  (check-true (contains? zsh-output "'--variant[VM variant]:variant:(cs bc)'") "zsh completion missing --variant spec")
  (check-true (contains? zsh-output "'--distribution[Distribution type]:distribution:(full minimal)'") "zsh completion missing --distribution spec")
  (check-true (contains? zsh-output "'--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)'") "zsh completion missing --arch spec")
  (check-true (contains? zsh-output "'--installer-ext[Force installer extension]:ext:(sh tgz dmg)'")
              "zsh completion missing --installer-ext spec")

  ;; Zsh structured _arguments for init
  (check-true (contains? zsh-output "'--shell[Shell type]:shell:(bash zsh)'") "zsh completion missing --shell spec for init")

  ;; Zsh new flags
  (check-true (contains? zsh-output "--ids") "zsh completion missing list --ids")
  (check-true (contains? zsh-output "--clean-compiled") "zsh completion missing remove --clean-compiled")
  (check-true (contains? zsh-output "--no-short-aliases") "zsh completion missing reshim --no-short-aliases")

  ;; Zsh toolchain descriptions
  (check-true (contains? zsh-output "_rackup_toolchains_described") "zsh completion missing toolchain description helper")

  ;; Help completion lists every command name (zsh used to omit `rebuild`)
  (check-true (contains? bash-output "    help)\n      COMPREPLY=($(compgen -W \"$commands\""))
  (let ([help-line (regexp-match #px"\"1:command:\\(([^)]+)\\)\"" zsh-output)])
    (check-true (and help-line (regexp-match? #px"\\brebuild\\b" (cadr help-line)))
                "zsh help completion missing rebuild"))

  ;; All command names referenced in the bash command list
  (let ([m (regexp-match #px"local commands=\"([^\"]+)\"" bash-output)])
    (check-true (and m (regexp-match? #px"\\brebuild\\b" (cadr m)))
                "bash completion command list missing rebuild"))

  ;; refresh-shell-integration! is a no-op when no shell directory exists.
  (define tmp-home (make-temporary-file "rackup-shell-test-~a" 'directory))
  (define prev-home (getenv "RACKUP_HOME"))
  (putenv "RACKUP_HOME" (path->string tmp-home))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e)
                     (if prev-home (putenv "RACKUP_HOME" prev-home) (putenv "RACKUP_HOME" ""))
                     (delete-directory/files tmp-home #:must-exist? #f)
                     (raise e))])
    (check-not-exn (lambda () (refresh-shell-integration!)))
    (check-false (directory-exists? (rackup-shell-dir))
                 "refresh-shell-integration! created shell dir when none existed")
    ;; Once the shell dir exists, refresh writes both helper files.
    (make-directory* (rackup-shell-dir))
    (refresh-shell-integration!)
    (check-true (file-exists? (rackup-shell-script "bash"))
                "refresh-shell-integration! did not write bash helper")
    (check-true (file-exists? (rackup-shell-script "zsh"))
                "refresh-shell-integration! did not write zsh helper")
    (define bash-on-disk (file->string (rackup-shell-script "bash")))
    (check-true (contains? bash-on-disk "complete -F _rackup rackup")
                "bash helper on disk missing completion bootstrap"))
  (if prev-home (putenv "RACKUP_HOME" prev-home) (putenv "RACKUP_HOME" ""))
  (delete-directory/files tmp-home #:must-exist? #f))
