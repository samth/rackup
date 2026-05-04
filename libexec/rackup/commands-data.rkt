#lang racket/base

(require racket/list
         (for-syntax racket/base
                     racket/list
                     racket/syntax))

(provide command-registry
         command-registry-data
         command-spec?
         command-spec-name
         command-spec-aliases
         command-spec-arg-schema
         command-spec-short-description
         command-spec-completion-hints
         rackup-hidden-commands
         rackup-command-names
         rackup-command-alias-map
         rackup-public-commands
         rackup-public-command-names)

(struct command-spec
  (name aliases arg-schema short-description completion-hints)
  #:transparent)

(define-for-syntax registry-entries
  '(("available" () "available [--all|--limit N]" "List remote install specs and recent release versions" ((top-level ("--all" "--limit")) (flag-values ()) (help-target? #t)))
    ("install" () "install <version> [flags]" "Install a Racket toolchain" ((top-level ("stable" "pre-release" "snapshot" "snapshot:utah" "snapshot:northwestern" "--variant" "--distribution" "--snapshot-site" "--arch" "--installer-ext" "--set-default" "--force" "--no-cache" "--short-aliases" "--quiet" "--verbose")) (flag-values (("--variant" ("cs" "bc")) ("--distribution" ("full" "minimal")) ("--snapshot-site" ("auto" "utah" "northwestern")) ("--arch" ("x86_64" "aarch64" "i386" "arm" "riscv64" "ppc")) ("--installer-ext" ("sh" "tgz" "dmg")))) (help-target? #t)))
    ("link" () "link <name> <path> [flags]" "Link an in-place/local Racket build as a managed toolchain" ((top-level ("--set-default" "--force")) (flag-values ()) (help-target? #t)))
    ("rebuild" () "rebuild [<name>] [flags] [-- <make-args>...]" "Rebuild a linked source toolchain in place" ((top-level ("--pull" "--jobs" "-j" "--dry-run" "--no-update-meta")) (flag-values ()) (help-target? #t)))
    ("list" () "list [--ids]" "List installed toolchains" ((top-level ("--ids")) (flag-values ()) (help-target? #t)))
    ("default" () "default [id|status|set <toolchain>|clear|<toolchain>|--unset]" "Show, set, or clear the global default toolchain" ((top-level ("id" "status" "set" "clear" "--unset")) (flag-values ()) (help-target? #t)))
    ("current" () "current [id|source|line]" "Show the active toolchain and where it came from" ((top-level ("id" "source" "line")) (flag-values ()) (help-target? #t)))
    ("which" () "which <exe> [--toolchain <toolchain>]" "Show the real executable path for a tool" ((top-level ("--toolchain")) (flag-values ()) (help-target? #t)))
    ("switch" () "switch <toolchain> | switch --unset" "Switch the active toolchain in this shell" ((top-level ("--unset")) (flag-values ()) (help-target? #t)))
    ("shell" () "shell <toolchain> | shell --deactivate" "Emit shell code to activate/deactivate a toolchain" ((top-level ("--deactivate")) (flag-values ()) (help-target? #t)))
    ("run" () "run <toolchain> -- <command> [args...]" "Run a command using a specific toolchain" ((top-level ()) (flag-values ()) (help-target? #t)))
    ("prompt" () "prompt [--long|--short|--raw|--source]" "Print prompt info for PS1" ((top-level ("--long" "--short" "--raw" "--source")) (flag-values ()) (help-target? #t)))
    ("upgrade" ("self-upgrade") "upgrade [version] [--force]" "Deprecated: alias for self-upgrade" ((top-level ("--force" "--no-cache")) (flag-values ()) (help-target? #f)))
    ("remove" () "remove <toolchain>" "Remove an installed or linked toolchain" ((top-level ("--clean-compiled")) (flag-values ()) (help-target? #t)))
    ("reshim" () "reshim" "Rebuild executable shims" ((top-level ("--short-aliases" "--no-short-aliases")) (flag-values ()) (help-target? #t)))
    ("init" () "init [--shell bash|zsh]" "Install/update shell integration" ((top-level ("--shell")) (flag-values (("--shell" ("bash" "zsh")))) (help-target? #t)))
    ("uninstall" () "uninstall [--dangerously-delete-without-prompting]" "Remove rackup and its data" ((top-level ("--dangerously-delete-without-prompting")) (flag-values ()) (help-target? #t)))
    ("self-upgrade" () "self-upgrade [--with-init] [--exe | --source] [--ref <ref>] [--repo <owner/repo>]" "Upgrade rackup code" ((top-level ("--with-init" "--exe" "--source" "--ref" "--repo")) (flag-values ()) (help-target? #t)))
    ("runtime" () "runtime status|install|upgrade" "Manage internal runtime" ((top-level ("status" "install" "upgrade")) (flag-values ()) (help-target? #t)))
    ("doctor" () "doctor" "Print diagnostics" ((top-level ()) (flag-values ()) (help-target? #t)))
    ("version" () "version" "Print version info" ((top-level ()) (flag-values ()) (help-target? #t)))
    ("help" () "help [command]" "Show help" ((top-level ()) (flag-values ()) (help-target? #f)))))

(define-syntax (command-registry stx)
  (syntax-case stx ()
    [(_ make)
     (with-syntax ([(entry ...)
                    (for/list ([entry (in-list registry-entries)])
                      (define name (list-ref entry 0))
                      (define aliases (list-ref entry 1))
                      (define arg-schema (list-ref entry 2))
                      (define short-desc (list-ref entry 3))
                      (define hints (list-ref entry 4))
                      #`(make #,name
                              '#,aliases
                              #,arg-schema
                              #,short-desc
                              '#,hints
                              #,(format-id stx "cmd-~a" name)))])
       #'(list entry ...))]))

(define command-registry-data
  (command-registry
   (lambda (name aliases arg-schema short-desc hints _handler)
     (command-spec name aliases arg-schema short-desc hints))))

(define rackup-hidden-commands '("upgrade"))
(define rackup-command-names (map command-spec-name command-registry-data))
(define rackup-command-alias-map
  (for*/hash ([spec (in-list command-registry-data)]
              [alias (in-list (command-spec-aliases spec))])
    (values alias (command-spec-name spec))))
(define rackup-public-commands
  (for/list ([spec (in-list command-registry-data)]
             #:unless (member (command-spec-name spec) rackup-hidden-commands))
    (cons (command-spec-name spec) (command-spec-short-description spec))))
(define rackup-public-command-names (map car rackup-public-commands))
