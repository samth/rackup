#lang racket/base

(require racket/file
         racket/list
         racket/path
         racket/string
         scribble/text
         "commands-data.rkt"
         "paths.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "util.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!
         refresh-shell-integration!
         shell-helper-script
         strip-managed-block
         remove-shell-init-blocks!)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

;; The rackup subcommand list lives in commands-data.rkt; the dispatcher
;; in main.rkt is generated from the same data via a macro, so the two
;; cannot drift apart.

(define (commands-space-separated)
  (string-join rackup-public-command-names " "))

(define shell-wrapper-template
  (include/text "templates/shell-wrapper.template.sh"))

(define (bash-completion-script)
  (define commands-line (commands-space-separated))
  (define bash-command-cases (include/text "templates/bash-command-cases.template.sh"))
  (include/text "templates/bash-completion.template.sh"))

(define (zsh-command-describe-list)
  ;; Build the zsh `_describe` command list as quoted 'name:description' strings.
  (apply string-append
         (for/list ([entry (in-list rackup-public-commands)])
           (string-append "    '"
                          (car entry)
                          ":"
                          (cdr entry)
                          "'\n"))))

(define (zsh-command-names-list)
  (string-join rackup-public-command-names " "))

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
   "# Emit toolchain id:description pairs for zsh _describe.\n"
   "_rackup_toolchains_described() {\n"
   "  local dir=\"${RACKUP_HOME:-$HOME/.rackup}/toolchains\"\n"
   "  [ -d \"$dir\" ] || return\n"
   "  local f id meta version variant dist desc\n"
   "  for f in \"$dir\"/*/; do\n"
   "    [ -d \"$f\" ] || continue\n"
   "    id=$(basename \"$f\")\n"
   "    meta=\"$f/meta.rktd\"\n"
   "    desc=\"toolchain\"\n"
   "    if [ -f \"$meta\" ]; then\n"
   "      version=$(sed -n \"s/.*'resolved-version[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p\" \"$meta\" 2>/dev/null | head -n1)\n"
   "      variant=$(sed -n \"s/.*'variant[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p\" \"$meta\" 2>/dev/null | head -n1)\n"
   "      dist=$(sed -n \"s/.*'distribution[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p\" \"$meta\" 2>/dev/null | head -n1)\n"
   "      if [ -n \"$version\" ]; then\n"
   "        desc=\"$version${variant:+, $variant}${dist:+, $dist}\"\n"
   "      fi\n"
   "    fi\n"
   "    print -- \"${id}:${desc}\"\n"
   "  done\n"
   "}\n"
   "\n"
   "_rackup() {\n"
   "  local -a commands\n"
   "  commands=(\n"
   (zsh-command-describe-list)
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
   "      _arguments \\\n"
   "        '--all[Show all versions]' \\\n"
   "        '--limit[Maximum versions to show]:n'\n"
   "      ;;\n"
   "    install)\n"
   "      _arguments \\\n"
   "        '::spec:(stable pre-release snapshot snapshot\\:utah snapshot\\:northwestern)' \\\n"
   "        '--variant[VM variant]:variant:(cs bc)' \\\n"
   "        '--distribution[Distribution type]:distribution:(full minimal)' \\\n"
   "        '--snapshot-site[Snapshot mirror]:site:(auto utah northwestern)' \\\n"
   "        '--arch[Target architecture]:arch:(x86_64 aarch64 i386 arm riscv64 ppc)' \\\n"
   "        '--installer-ext[Force installer extension]:ext:(sh tgz dmg)' \\\n"
   "        '--set-default[Set as default]' \\\n"
   "        '--force[Force reinstall]' \\\n"
   "        '--no-cache[Skip download cache]' \\\n"
   "        '--short-aliases[Install short aliases r/dr]' \\\n"
   "        '--quiet[Quiet output]' \\\n"
   "        '--verbose[Verbose output]'\n"
   "      ;;\n"
   "    link)\n"
   "      _arguments '1:name:' '2:path:_directories' '*:option:(--set-default --force)'\n"
   "      ;;\n"
   "    rebuild)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        '--pull[Run git pull --ff-only first]' \\\n"
   "        '--jobs[Parallel jobs for make]:jobs' \\\n"
   "        '-j[Parallel jobs for make]:jobs' \\\n"
   "        '--dry-run[Print planned commands only]' \\\n"
   "        '--no-update-meta[Skip metadata refresh]' \\\n"
   "        \"::toolchain:((${tcs}))\"\n"
   "      ;;\n"
   "    list)\n"
   "      _arguments '--ids[Print only toolchain IDs]'\n"
   "      ;;\n"
   "    default)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        '--unset[Clear the default toolchain]' \\\n"
   "        \"*::action:((id\\:'show id' status\\:'show set/unset' set\\:'set default' clear\\:'clear default' ${tcs}))\"\n"
   "      ;;\n"
   "    current)\n"
   "      _arguments \"1:subcommand:((id\\:'show id' source\\:'show source' line\\:'id and source'))\"\n"
   "      ;;\n"
   "    which)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        \"--toolchain[Use specific toolchain]:toolchain:((${tcs}))\" \\\n"
   "        '1:command:_command_names'\n"
   "      ;;\n"
   "    switch)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        '--unset[Deactivate shell toolchain]' \\\n"
   "        \"1:toolchain:((${tcs}))\"\n"
   "      ;;\n"
   "    shell)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        '--deactivate[Deactivate shell toolchain]' \\\n"
   "        \"1:toolchain:((${tcs}))\"\n"
   "      ;;\n"
   "    run)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        \"1:toolchain:((${tcs}))\" \\\n"
   "        '*:command:_command_names'\n"
   "      ;;\n"
   "    prompt)\n"
   "      _arguments \\\n"
   "        '--long[Long format: \\[rk:<id>\\]]' \\\n"
   "        '--short[Short format (default)]' \\\n"
   "        '--raw[Raw toolchain ID]' \\\n"
   "        '--source[ID and source]'\n"
   "      ;;\n"
   "    remove)\n"
   "      local -a tcs\n"
   "      tcs=(${(f)\"$(_rackup_toolchains_described)\"})\n"
   "      _arguments \\\n"
   "        '--clean-compiled[Remove version-specific compiled directories]' \\\n"
   "        \"1:toolchain:((${tcs}))\"\n"
   "      ;;\n"
   "    reshim)\n"
   "      _arguments \\\n"
   "        '(--no-short-aliases)--short-aliases[Enable short aliases r/dr]' \\\n"
   "        '(--short-aliases)--no-short-aliases[Remove short aliases]'\n"
   "      ;;\n"
   "    init)\n"
   "      _arguments '--shell[Shell type]:shell:(bash zsh)'\n"
   "      ;;\n"
   "    uninstall)\n"
   "      _arguments '--dangerously-delete-without-prompting[Skip confirmation prompt]'\n"
   "      ;;\n"
   "    self-upgrade)\n"
   "      _arguments \\\n"
   "        '--with-init[Also update shell init]' \\\n"
   "        '(--source)--exe[Require prebuilt binary]' \\\n"
   "        '(--exe)--source[Install from source]' \\\n"
   "        '--ref[Git ref]:ref' \\\n"
   "        '--repo[GitHub repository]:owner/repo'\n"
   "      ;;\n"
   "    upgrade)\n"
   "      _arguments \\\n"
   "        '--force[Reinstall even if up to date]' \\\n"
   "        '--no-cache[Re-download installer]' \\\n"
   "        '1:version:'\n"
   "      ;;\n"
   "    runtime)\n"
   "      _arguments \"1:subcommand:((status\\:'show runtime status' install\\:'install runtime' upgrade\\:'upgrade runtime'))\"\n"
   "      ;;\n"
   "    help)\n"
   "      _arguments \"1:command:(" (zsh-command-names-list) ")\"\n"
   "      ;;\n"
   "  esac\n"
   "}\n"
   "\n"
   "if (( $+functions[compdef] )); then compdef _rackup rackup; fi\n"))

(define (shell-helper-script shell-name)
  (string-append "# rackup shell helper\n"
                 (emit-path-prepend)
                 shell-wrapper-template
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
           (env-var-export-line (car kv) (cdr kv)))))

(define (emit-shell-activation toolchain-id)
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  ;; Only set RACKUP_TOOLCHAIN and PATH.  Racket-specific env vars
  ;; (PLTCOMPILEDROOTS, PLTADDONDIR, PLTHOME) are set internally by the
  ;; shim dispatcher via env.sh, scoped to each invocation — not exported
  ;; into the user's shell where they would leak into non-rackup commands.
  (string-append (emit-path-prepend)
                 "export RACKUP_TOOLCHAIN="
                 (sh-single-quote toolchain-id)
                 "\n"))

(define (deactivation-extra-vars)
  (define active (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and active (toolchain-exists? active))
     (for/list ([kv (in-list (toolchain-env-vars active))])
       (car kv))]
    [else null]))

(define (emit-shell-deactivation)
  (define extra-vars (remove-duplicates (deactivation-extra-vars)))
  ;; Unset RACKUP_TOOLCHAIN and any Racket env vars that might be
  ;; lingering from prior sessions (backwards compatibility).
  (string-append (emit-path-prepend)
                 (apply string-append
                        (for/list ([k (in-list extra-vars)])
                          (format "unset ~a\n" k)))
                 "unset RACKUP_TOOLCHAIN\n"
                 "unset PLTADDONDIR\n"
                 "unset PLTCOMPILEDROOTS\n"
                 "unset PLTHOME\n"))

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

(define (write-shell-helper-files!)
  (for ([s '("bash" "zsh")])
    (define p (rackup-shell-script s))
    (write-string-file p (shell-helper-script s))))

;; Refresh helper scripts in-place (e.g. after `self-upgrade`) so any
;; new commands or flags become tab-completable in existing shells
;; without requiring the user to rerun `rackup init`.  Only writes the
;; helper scripts; does NOT modify the user's rc files.  No-op if the
;; user has not previously run `rackup init` (no helper directory).
(define (refresh-shell-integration!)
  (define shell-dir (rackup-shell-dir))
  (when (directory-exists? shell-dir)
    (write-shell-helper-files!)))

(define (init-shell! [shell-name #f])
  (ensure-rackup-layout!)
  (define shell* (or shell-name (guess-shell)))
  (unless (member shell* '("bash" "zsh"))
    (rackup-error "unsupported shell for init: ~a" shell*))
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (write-shell-helper-files!)
  (define rc (rc-path shell*))
  (define existing (read-string-file rc ""))
  (write-string-file rc (replace-managed-block existing (managed-rc-block shell*)))
  rc)

(module+ for-testing
  (provide shell-helper-script))
