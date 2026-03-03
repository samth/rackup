#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         "paths.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!
         shell-helper-script
         strip-managed-block
         remove-shell-init-blocks!)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

(define (shell-wrapper-function)
  (string-append "rackup() {\n"
                 "  local _rackup_bin=\"${RACKUP_HOME:-$HOME/.rackup}/bin/rackup\"\n"
                 "  if [ \"$#\" -gt 0 ]; then\n"
                 "    case \"$1\" in\n"
                 "      shell|switch)\n"
                 "        if [ \"$#\" -ge 2 ] && [ \"$2\" != \"--help\" ] && [ \"$2\" != \"-h\" ]; then\n"
                 "          local _rackup_cmd=\"$1\"\n"
                 "          local _rackup_eval _rackup_status\n"
                 "          shift\n"
                 "          _rackup_eval=\"$(\"$_rackup_bin\" \"$_rackup_cmd\" \"$@\")\"\n"
                 "          _rackup_status=$?\n"
                 "          if [ \"$_rackup_status\" -ne 0 ]; then\n"
                 "            return \"$_rackup_status\"\n"
                 "          fi\n"
                 "          eval \"$_rackup_eval\"\n"
                 "          return\n"
                 "        fi\n"
                 "        ;;\n"
                 "    esac\n"
                 "  fi\n"
                 "  \"$_rackup_bin\" \"$@\"\n"
                 "}\n"))

(define (bash-completion-script)
  (string-append
   "\n# rackup bash completion\n"
   "_rackup_toolchains() {\n"
   "  local dir=\"${RACKUP_HOME:-$HOME/.rackup}/toolchains\"\n"
   "  if [ -d \"$dir\" ]; then\n"
   "    local f\n"
   "    for f in \"$dir\"/*/; do\n"
   "      [ -d \"$f\" ] && basename \"$f\"\n"
   "    done\n"
   "  fi\n"
   "}\n"
   "\n"
   "_rackup() {\n"
   "  local cur prev words cword\n"
   "  cur=\"${COMP_WORDS[COMP_CWORD]}\"\n"
   "  prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n"
   "  words=(\"${COMP_WORDS[@]}\")\n"
   "  cword=$COMP_CWORD\n"
   "\n"
   "  local commands=\"available install link list default current which switch shell run prompt remove reshim init uninstall self-upgrade runtime doctor version help\"\n"
   "\n"
   "  if [ \"$cword\" -eq 1 ]; then\n"
   "    COMPREPLY=($(compgen -W \"$commands\" -- \"$cur\"))\n"
   "    return\n"
   "  fi\n"
   "\n"
   "  # flag argument completion\n"
   "  case \"$prev\" in\n"
   "    --variant)      COMPREPLY=($(compgen -W \"cs bc\" -- \"$cur\")); return ;;\n"
   "    --distribution) COMPREPLY=($(compgen -W \"full minimal\" -- \"$cur\")); return ;;\n"
   "    --snapshot-site) COMPREPLY=($(compgen -W \"auto utah northwestern\" -- \"$cur\")); return ;;\n"
   "    --arch)         COMPREPLY=($(compgen -W \"x86_64 aarch64 i386 arm riscv64 ppc\" -- \"$cur\")); return ;;\n"
   "    --shell)        COMPREPLY=($(compgen -W \"bash zsh\" -- \"$cur\")); return ;;\n"
   "    --toolchain)    COMPREPLY=($(compgen -W \"$(_rackup_toolchains)\" -- \"$cur\")); return ;;\n"
   "  esac\n"
   "\n"
   "  local cmd=\"${words[1]}\"\n"
   "  case \"$cmd\" in\n"
   "    available)\n"
   "      COMPREPLY=($(compgen -W \"--all --limit\" -- \"$cur\"))\n"
   "      ;;\n"
   "    install)\n"
   "      COMPREPLY=($(compgen -W \"stable pre-release snapshot snapshot:utah snapshot:northwestern --variant --distribution --snapshot-site --arch --set-default --force --no-cache --quiet --verbose\" -- \"$cur\"))\n"
   "      ;;\n"
   "    link)\n"
   "      COMPREPLY=($(compgen -W \"--set-default --force\" -- \"$cur\"))\n"
   "      ;;\n"
   "    default)\n"
   "      COMPREPLY=($(compgen -W \"id status set clear --unset $(_rackup_toolchains)\" -- \"$cur\"))\n"
   "      ;;\n"
   "    current)\n"
   "      COMPREPLY=($(compgen -W \"id source line\" -- \"$cur\"))\n"
   "      ;;\n"
   "    which)\n"
   "      COMPREPLY=($(compgen -W \"--toolchain\" -- \"$cur\"))\n"
   "      ;;\n"
   "    switch)\n"
   "      COMPREPLY=($(compgen -W \"--unset $(_rackup_toolchains)\" -- \"$cur\"))\n"
   "      ;;\n"
   "    shell)\n"
   "      COMPREPLY=($(compgen -W \"--deactivate $(_rackup_toolchains)\" -- \"$cur\"))\n"
   "      ;;\n"
   "    run)\n"
   "      COMPREPLY=($(compgen -W \"$(_rackup_toolchains)\" -- \"$cur\"))\n"
   "      ;;\n"
   "    prompt)\n"
   "      COMPREPLY=($(compgen -W \"--long --short --raw --source\" -- \"$cur\"))\n"
   "      ;;\n"
   "    remove)\n"
   "      COMPREPLY=($(compgen -W \"$(_rackup_toolchains)\" -- \"$cur\"))\n"
   "      ;;\n"
   "    init)\n"
   "      COMPREPLY=($(compgen -W \"--shell\" -- \"$cur\"))\n"
   "      ;;\n"
   "    uninstall)\n"
   "      COMPREPLY=($(compgen -W \"--yes\" -- \"$cur\"))\n"
   "      ;;\n"
   "    self-upgrade)\n"
   "      COMPREPLY=($(compgen -W \"--with-init\" -- \"$cur\"))\n"
   "      ;;\n"
   "    runtime)\n"
   "      COMPREPLY=($(compgen -W \"status install upgrade\" -- \"$cur\"))\n"
   "      ;;\n"
   "    help)\n"
   "      COMPREPLY=($(compgen -W \"$commands\" -- \"$cur\"))\n"
   "      ;;\n"
   "  esac\n"
   "}\n"
   "\n"
   "complete -F _rackup rackup\n"))

(define (zsh-completion-script)
  (string-append
   "\n# rackup zsh completion\n"
   "_rackup_toolchains() {\n"
   "  local dir=\"${RACKUP_HOME:-$HOME/.rackup}/toolchains\"\n"
   "  if [ -d \"$dir\" ]; then\n"
   "    local f\n"
   "    for f in \"$dir\"/*/; do\n"
   "      [ -d \"$f\" ] && basename \"$f\"\n"
   "    done\n"
   "  fi\n"
   "}\n"
   "\n"
   "_rackup() {\n"
   "  local -a commands\n"
   "  commands=(\n"
   "    'available:List remote install specs and recent release versions'\n"
   "    'install:Install a Racket toolchain'\n"
   "    'link:Link an in-place/local Racket build as a managed toolchain'\n"
   "    'list:List installed toolchains'\n"
   "    'default:Show, set, or clear the global default toolchain'\n"
   "    'current:Show the active toolchain and where it came from'\n"
   "    'which:Show the real executable path for a tool'\n"
   "    'switch:Switch the active toolchain in this shell'\n"
   "    'shell:Emit shell code to activate/deactivate a toolchain'\n"
   "    'run:Run a command using a specific toolchain'\n"
   "    'prompt:Print prompt info for PS1'\n"
   "    'remove:Remove an installed or linked toolchain'\n"
   "    'reshim:Rebuild executable shims'\n"
   "    'init:Install/update shell integration'\n"
   "    'uninstall:Remove rackup and its data'\n"
   "    'self-upgrade:Upgrade rackup code'\n"
   "    'runtime:Manage internal runtime'\n"
   "    'doctor:Print diagnostics'\n"
   "    'version:Print version info'\n"
   "    'help:Show help'\n"
   "  )\n"
   "\n"
   "  if (( CURRENT == 2 )); then\n"
   "    _describe 'command' commands\n"
   "    return\n"
   "  fi\n"
   "\n"
   "  local cmd=\"${words[2]}\"\n"
   "  case \"$cmd\" in\n"
   "    available)\n"
   "      _arguments '*:option:(--all --limit)'\n"
   "      ;;\n"
   "    install)\n"
   "      _arguments \\\n"
   "        '::spec:(stable pre-release snapshot snapshot\\:utah snapshot\\:northwestern)' \\\n"
   "        '--variant[VM variant]:variant:(cs bc)' \\\n"
   "        '--distribution[Distribution type]:distribution:(full minimal)' \\\n"
   "        '--snapshot-site[Snapshot mirror]:site:(auto utah northwestern)' \\\n"
   "        '--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)' \\\n"
   "        '--set-default[Set as default]' \\\n"
   "        '--force[Force reinstall]' \\\n"
   "        '--no-cache[Skip download cache]' \\\n"
   "        '--quiet[Quiet output]' \\\n"
   "        '--verbose[Verbose output]'\n"
   "      ;;\n"
   "    link)\n"
   "      _arguments '1:name:' '2:path:_directories' '*:option:(--set-default --force)'\n"
   "      ;;\n"
   "    default)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \"*:option:(id status set clear --unset $toolchains)\"\n"
   "      ;;\n"
   "    current)\n"
   "      _arguments '*:subcommand:(id source line)'\n"
   "      ;;\n"
   "    which)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \\\n"
   "        \"--toolchain[Use specific toolchain]:toolchain:($toolchains)\" \\\n"
   "        '1:command:'\n"
   "      ;;\n"
   "    switch)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \"*:toolchain:(--unset $toolchains)\"\n"
   "      ;;\n"
   "    shell)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \"*:toolchain:(--deactivate $toolchains)\"\n"
   "      ;;\n"
   "    run)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \"1:toolchain:($toolchains)\"\n"
   "      ;;\n"
   "    prompt)\n"
   "      _arguments '*:option:(--long --short --raw --source)'\n"
   "      ;;\n"
   "    remove)\n"
   "      local -a toolchains\n"
   "      toolchains=(${(f)\"$(_rackup_toolchains)\"})\n"
   "      _arguments \"1:toolchain:($toolchains)\"\n"
   "      ;;\n"
   "    init)\n"
   "      _arguments '--shell[Shell type]:shell:(bash zsh)'\n"
   "      ;;\n"
   "    uninstall)\n"
   "      _arguments '*:option:(--yes)'\n"
   "      ;;\n"
   "    self-upgrade)\n"
   "      _arguments '*:option:(--with-init)'\n"
   "      ;;\n"
   "    runtime)\n"
   "      _arguments '*:subcommand:(status install upgrade)'\n"
   "      ;;\n"
   "    help)\n"
   "      local -a cmd_names\n"
   "      cmd_names=(available install link list default current which switch shell run prompt remove reshim init uninstall self-upgrade runtime doctor version help)\n"
   "      _arguments \"1:command:($cmd_names)\"\n"
   "      ;;\n"
   "  esac\n"
   "}\n"
   "\n"
   "if (( $+functions[compdef] )); then compdef _rackup rackup; fi\n"))

(define (shell-helper-script shell-name)
  (string-append "# rackup shell helper\n"
                 (emit-path-prepend)
                 (shell-wrapper-function)
                 (cond
                   [(equal? shell-name "bash") (bash-completion-script)]
                   [(equal? shell-name "zsh") (zsh-completion-script)]
                   [else ""])))

(define (managed-rc-block shell-name)
  (define base "${RACKUP_HOME:-$HOME/.rackup}")
  (define shell-script (format "~a/shell/rackup.~a" base shell-name))
  (string-append start-marker
                 "\n"
                 "[ -f \""
                 shell-script
                 "\" ] && . \""
                 shell-script
                 "\"\n"
                 end-marker
                 "\n"))

(define (emit-path-prepend)
  "if [ -d \"${RACKUP_HOME:-$HOME/.rackup}/shims\" ]; then\n  case \":$PATH:\" in *\":${RACKUP_HOME:-$HOME/.rackup}/shims:\"*) ;; *) export PATH=\"${RACKUP_HOME:-$HOME/.rackup}/shims:$PATH\" ;; esac\nfi\n")

(define (emit-env-exports vars)
  (apply string-append
         (for/list ([kv (in-list vars)])
           (define k (car kv))
           (define v (cdr kv))
           (format "export ~a=~a\n" k (sh-single-quote v)))))

(define (emit-shell-activation toolchain-id)
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  (define extra-env (toolchain-env-vars toolchain-id))
  (define addon (path->string* (rackup-addon-dir toolchain-id)))
  (define has-addon? (assoc "PLTADDONDIR" extra-env))
  (string-append (emit-path-prepend)
                 (emit-env-exports extra-env)
                 "export RACKUP_TOOLCHAIN="
                 (sh-single-quote toolchain-id)
                 "\n"
                 (if has-addon?
                     ""
                     (string-append "export PLTADDONDIR="
                                    (sh-single-quote addon)
                                    "\n"))))

(define (deactivation-extra-vars)
  (define active (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and active (toolchain-exists? active))
     (for/list ([kv (in-list (toolchain-env-vars active))])
       (car kv))]
    [else null]))

(define (emit-shell-deactivation)
  (define extra-vars (remove-duplicates (deactivation-extra-vars)))
  (string-append (emit-path-prepend)
                 (apply string-append
                        (for/list ([k (in-list extra-vars)])
                          (format "unset ~a\n" k)))
                 "unset RACKUP_TOOLCHAIN\n"
                 "unset PLTADDONDIR\n"))

(define (guess-shell)
  (define sh (or (getenv "SHELL") ""))
  (cond
    [(regexp-match? #px"/zsh$" sh) "zsh"]
    [else "bash"]))

(define (rc-path shell-name)
  (build-path (find-system-path 'home-dir) (format ".~arc" shell-name)))

(define (replace-managed-block existing new-block)
  (define start-match (regexp-match-positions (regexp (regexp-quote start-marker)) existing))
  (cond
    [start-match
     (define start-pos (caar start-match))
     (define after-start (substring existing start-pos))
     (define end-match (regexp-match-positions (regexp (regexp-quote end-marker)) after-start))
     (if (not end-match)
         (string-append existing "\n" new-block)
         (let* ([end-pos-rel (cdar end-match)]
                [end-pos (+ start-pos end-pos-rel)]
                [after-end (substring existing end-pos)]
                [after-end* (if (and (positive? (string-length after-end))
                                     (char=? (string-ref after-end 0) #\newline))
                                (substring after-end 1)
                                after-end)])
           (string-append (substring existing 0 start-pos) new-block after-end*)))]
    [else
     (string-append (if (string-blank? existing)
                        ""
                        (string-append existing "\n"))
                    new-block)]))

(define (strip-managed-block existing)
  (define start-match (regexp-match-positions (regexp (regexp-quote start-marker)) existing))
  (cond
    [(not start-match) (values existing #f)]
    [else
     (define start-pos (caar start-match))
     (define after-start (substring existing start-pos))
     (define end-match (regexp-match-positions (regexp (regexp-quote end-marker)) after-start))
     (cond
       [(not end-match) (values existing #f)]
       [else
        (define end-pos-rel (cdar end-match))
        (define end-pos (+ start-pos end-pos-rel))
        (define after-end (substring existing end-pos))
        (define after-end*
          (if (and (positive? (string-length after-end)) (char=? (string-ref after-end 0) #\newline))
              (substring after-end 1)
              after-end))
        (define prefix (substring existing 0 start-pos))
        (define combined (string-append prefix after-end*))
        (define trimmed (string-trim combined))
        (values (if (string-blank? trimmed) "" combined) #t)])]))

(define (remove-shell-init-blocks!)
  (define removed null)
  (for ([shell* '("bash" "zsh")])
    (define rc (rc-path shell*))
    (when (file-exists? rc)
      (define existing (read-string-file rc ""))
      (define-values (updated changed?) (strip-managed-block existing))
      (when changed?
        (write-string-file rc updated)
        (set! removed (cons rc removed)))))
  (reverse removed))

(define (init-shell! [shell-name #f])
  (ensure-rackup-layout!)
  (define shell* (or shell-name (guess-shell)))
  (unless (member shell* '("bash" "zsh"))
    (rackup-error "unsupported shell for init: ~a" shell*))
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (for ([s '("bash" "zsh")])
    (define p (rackup-shell-script s))
    (write-string-file p (shell-helper-script s)))
  (define rc (rc-path shell*))
  (define existing (read-string-file rc ""))
  (write-string-file rc (replace-managed-block existing (managed-rc-block shell*)))
  rc)
