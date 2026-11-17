#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/port
         racket/string
         racket/system
         scribble/text
         "commands-data.rkt"
         "error.rkt"
         "paths.rkt"
         "platform.rkt"
         "rktd-io.rkt"
         "shims.rkt"
         "state.rkt"
         "text.rkt")

(provide emit-shell-activation
         emit-shell-deactivation
         init-shell!
         refresh-shell-integration!
         strip-managed-block
         remove-shell-init-blocks!
         current-macos?
         current-home-dir
         current-documents-dir
         shell-syntax
         powershell-execution-policy-hint)

(define start-marker "# >>> rackup initialize >>>")
(define end-marker "# <<< rackup initialize <<<")

;; The rackup subcommand list lives in commands-data.rkt; the dispatcher
;; in main.rkt is generated from the same data via a macro, so the two
;; cannot drift apart.

(define commands-line (string-join (map car rackup-commands) " "))

(define (write-bash-completion-script)
  (define bash-command-cases (include/text "templates/bash-command-cases.scrbl"))
  (output (include/text "templates/bash-completion.scrbl")))

;; Escape a command description for use in a zsh `_describe`
;; `'name:description'` entry.  Two layers: `:` and `\` are special to
;; `_describe` (so backslash-escape them), and the whole thing sits inside a
;; single-quoted shell string (so turn `'` into the `'\''` idiom).  Without
;; this, a description like "Racket's ..." closes the quote early and breaks
;; zsh parsing of the entire completion file.
(define (zsh-describe-escape s)
  (let* ([s (string-replace s "\\" "\\\\")]
         [s (string-replace s ":" "\\:")]
         [s (string-replace s "'" "'\\''")])
    s))

(define (write-zsh-completion-script)
  (define command-describe-list
    ;; '_describe'-format `'name:description'` lines, one per command.
    (apply string-append
           (for/list ([e (in-list rackup-commands)])
             (string-append "    '" (car e) ":" (zsh-describe-escape (cdr e)) "'\n"))))
  (output (include/text "templates/zsh-completion.scrbl")))

;; Write the shell helper to current-output-port.  Production callers
;; wrap in `with-output-to-file`; the for-testing submodule exposes a
;; with-output-to-string convenience for snapshot tests.
(define (write-shell-helper-script shell-name)
  (if (equal? shell-name "powershell")
      (write-powershell-helper-script)
      (write-posix-shell-helper-script shell-name)))

(define (write-posix-shell-helper-script shell-name)
  (display "# rackup shell helper\n")
  (display path-prepend)
  (output (include/text "templates/shell-wrapper.scrbl"))
  (newline)
  (match shell-name
    ["bash" (write-bash-completion-script)]
    ["zsh" (write-zsh-completion-script)]))

(define path-prepend
  (string-append
   "if [ -d \"${RACKUP_HOME:-$HOME/.rackup}/shims\" ]; then\n"
   "  case \":$PATH:\" in *\":${RACKUP_HOME:-$HOME/.rackup}/shims:\"*) ;;"
   " *) export PATH=\"${RACKUP_HOME:-$HOME/.rackup}/shims:$PATH\" ;; esac\n"
   "fi\n"))

(define ps-home-expr
  "$(if ($env:RACKUP_HOME) { $env:RACKUP_HOME } else { Join-Path $env:LOCALAPPDATA 'rackup' })")

(define ps-path-prepend
  (string-append
   "$__rackupShims = Join-Path " ps-home-expr " 'shims'\n"
   "if ((Test-Path -LiteralPath $__rackupShims) -and"
   " -not (($env:Path -split ';') -contains $__rackupShims)) {"
   " $env:Path = \"$__rackupShims;$env:Path\" }\n"
   "Remove-Variable __rackupShims\n"))

;; Commands whose arguments include toolchain names, with their other
;; completions, for the PowerShell completer.
(define ps-toolchain-commands
  '(("switch" "--unset")
    ("shell" "--deactivate")
    ("default" "id" "status" "set" "clear" "--unset")
    ("remove" "--clean-compiled")
    ("rebuild" "--pull" "--jobs" "--dry-run" "--no-update-meta")
    ("run")))

(define (ps-string-array strs)
  (string-append "@(" (string-join (map ps-single-quote strs) ", ") ")"))

;; The PowerShell helper: PATH, a `rackup` function that evaluates the
;; output of `rackup switch` / `rackup shell` in the calling session, and
;; tab completion.
(define (write-powershell-helper-script)
  (display "# rackup shell helper (PowerShell)\n")
  (display ps-path-prepend)
  (display
   (string-append
    "function rackup {\n"
    "  $exe = Join-Path " ps-home-expr " 'shims\\rackup.exe'\n"
    "  if ($args.Count -ge 2 -and ($args[0] -eq 'switch' -or $args[0] -eq 'shell') -and"
    " $args[1] -ne '--help' -and $args[1] -ne '-h') {\n"
    "    $env:RACKUP_SHELL = 'powershell'\n"
    "    try { $code = & $exe @args } finally {"
    " Remove-Item -LiteralPath Env:RACKUP_SHELL -ErrorAction SilentlyContinue }\n"
    "    if ($LASTEXITCODE -ne 0) { return }\n"
    "    if ($code) { Invoke-Expression ($code -join \"`n\") }\n"
    "    return\n"
    "  }\n"
    "  & $exe @args\n"
    "}\n"
    "Register-ArgumentCompleter -Native -CommandName rackup -ScriptBlock {\n"
    "  param($word, $ast, $cursor)\n"
    "  $elems = @($ast.CommandElements | Where-Object { $_.Extent.EndOffset -lt $cursor } | ForEach-Object { $_.Extent.Text })\n"
    "  $commands = " (ps-string-array (map car rackup-commands)) "\n"
    "  $toolchainWords = @{\n"
    (apply string-append
           (for/list ([e (in-list ps-toolchain-commands)])
             (string-append "    " (ps-single-quote (car e)) " = "
                            (ps-string-array (cdr e)) "\n")))
    "  }\n"
    "  if ($elems.Count -le 1) {\n"
    "    $candidates = $commands\n"
    "  } elseif ($toolchainWords.ContainsKey($elems[1])) {\n"
    "    $dir = Join-Path " ps-home-expr " 'toolchains'\n"
    "    $ids = @(if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object { $_.Name } })\n"
    "    $candidates = @($toolchainWords[$elems[1]]) + $ids\n"
    "  } elseif ($elems[1] -eq 'help') {\n"
    "    $candidates = $commands\n"
    "  } else {\n"
    "    return\n"
    "  }\n"
    "  $candidates | Where-Object { $_ -like \"$word*\" } | ForEach-Object {\n"
    "    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)\n"
    "  }\n"
    "}\n")))

(define (managed-rc-block shell-name)
  (if (equal? shell-name "powershell")
      (managed-profile-block)
      (posix-managed-rc-block shell-name)))

(define (managed-profile-block)
  (string-append start-marker "\n"
                 "$__rackupHelper = Join-Path " ps-home-expr " 'shell\\rackup.ps1'\n"
                 "if (Test-Path -LiteralPath $__rackupHelper) { . $__rackupHelper }\n"
                 "Remove-Variable __rackupHelper\n"
                 end-marker "\n"))

(define (posix-managed-rc-block shell-name)
  (define shell-script
    (string-append "${RACKUP_HOME:-$HOME/.rackup}/shell/rackup." shell-name))
  (string-append start-marker "\n"
                 "[ -f \"" shell-script "\" ] && . \"" shell-script "\"\n"
                 end-marker "\n"))

(define (emit-shell-activation toolchain-id #:syntax [syntax (shell-syntax)])
  (unless (toolchain-exists? toolchain-id)
    (rackup-error "toolchain not installed: ~a" toolchain-id))
  ;; Only set RACKUP_TOOLCHAIN and PATH.  Racket-specific env vars
  ;; (PLTCOMPILEDROOTS, PLTADDONDIR, PLTHOME) are set internally by the
  ;; shim dispatcher via env.sh, scoped to each invocation — not exported
  ;; into the user's shell where they would leak into non-rackup commands.
  (case syntax
    [(powershell)
     (string-append ps-path-prepend
                    "$env:RACKUP_TOOLCHAIN = " (ps-single-quote toolchain-id) "\n")]
    [else
     (string-append path-prepend
                    "export RACKUP_TOOLCHAIN=" (sh-single-quote toolchain-id) "\n")]))

(define (deactivation-extra-vars)
  (define active (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and active (toolchain-exists? active))
     (remove-duplicates (map car (toolchain-env-vars active)))]
    [else null]))

(define (emit-shell-deactivation #:syntax [syntax (shell-syntax)])
  ;; Unset RACKUP_TOOLCHAIN and any Racket env vars that might be
  ;; lingering from prior sessions (backwards compatibility).
  (define vars
    (remove-duplicates
     (append (deactivation-extra-vars)
             '("RACKUP_TOOLCHAIN" "PLTADDONDIR" "PLTCOMPILEDROOTS" "PLTHOME"))))
  (case syntax
    [(powershell)
     (apply string-append
            ps-path-prepend
            (for/list ([k (in-list vars)])
              (~a "Remove-Item -LiteralPath Env:" k " -ErrorAction SilentlyContinue\n")))]
    [else
     (apply string-append
            path-prepend
            (for/list ([k (in-list vars)])
              (~a "unset " k "\n")))]))

;; Which shell's syntax `rackup switch` / `rackup shell` print.  The
;; PowerShell helper function sets RACKUP_SHELL=powershell around its call.
(define (shell-syntax)
  (if (equal? (getenv "RACKUP_SHELL") "powershell") 'powershell 'posix))

(define (ps-single-quote s)
  (string-append "'" (string-replace s "'" "''") "'"))

(define (guess-shell)
  (cond
    [(windows?) "powershell"]
    [(regexp-match? #px"/zsh$" (or (getenv "SHELL") "")) "zsh"]
    [else "bash"]))

;; The directory holding the user's shell startup files.  A parameter so
;; tests can point it at a scratch directory: find-system-path reads HOME
;; once at startup, so changing HOME at run time does not redirect it.
(define current-home-dir (make-parameter #f))
(define (home-dir) (or (current-home-dir) (find-system-path 'home-dir)))

(define (rc-path shell-name)
  (build-path (home-dir) (format ".~arc" shell-name)))

;; A login bash -- every new window in macOS Terminal -- reads the first of
;; these that exists and never reads ~/.bashrc unless that file sources it.
(define bash-login-names '(".bash_profile" ".bash_login" ".profile"))

(define current-macos? (make-parameter (eq? (system-type 'os) 'macosx)))

;; The login file `rackup init --shell bash` also writes: the first one
;; bash would read, or a new ~/.bash_profile on macOS.  Elsewhere, with no
;; login file, return #f: terminals there start non-login shells that read
;; ~/.bashrc, and creating ~/.bash_profile would hide an existing
;; ~/.profile from bash.
(define (bash-login-path)
  (define home (home-dir))
  (or (for/first ([n (in-list bash-login-names)]
                  #:when (file-exists? (build-path home n)))
        (build-path home n))
      (and (current-macos?) (build-path home ".bash_profile"))))

;; The Documents folder, which holds PowerShell's profiles.  A parameter
;; for tests, like current-home-dir.
(define current-documents-dir (make-parameter #f))
(define (documents-dir) (or (current-documents-dir) (find-system-path 'doc-dir)))

;; PowerShell's "current user, all hosts" profiles: Windows PowerShell 5.1
;; reads Documents\WindowsPowerShell\profile.ps1 and PowerShell 7 reads
;; Documents\PowerShell\profile.ps1.
(define (powershell-profile-paths)
  (define docs (documents-dir))
  (list (build-path docs "WindowsPowerShell" "profile.ps1")
        (build-path docs "PowerShell" "profile.ps1")))

;; The profiles `rackup init --shell powershell` writes: Windows
;; PowerShell's always, PowerShell 7's when it is installed or already
;; has a profile folder.
(define (powershell-init-paths)
  (match-define (list wps ps7) (powershell-profile-paths))
  (define-values (ps7-dir _n _d) (split-path ps7))
  (if (or (directory-exists? ps7-dir) (find-executable-path "pwsh.exe") (find-executable-path "pwsh"))
      (list wps ps7)
      (list wps)))

;; Every file `rackup init` may have written a block into.
(define (all-rc-paths)
  (define home (home-dir))
  (append (list (rc-path "bash") (rc-path "zsh"))
          (for/list ([n (in-list bash-login-names)]) (build-path home n))
          (if (windows?) (powershell-profile-paths) null)))

;; The full managed `# >>> rackup ... # <<< rackup\n?` block as a regex,
;; including any trailing newline so removal doesn't leave a blank line.
(define managed-block-rx
  (pregexp (string-append "(?m:^)" (regexp-quote start-marker)
                          "[\\s\\S]*?" (regexp-quote end-marker) "\n?")))

(define (replace-managed-block existing new-block)
  (cond
    [(regexp-match? managed-block-rx existing)
     ;; Pass the replacement via a procedure so `&` / `\\1` in `new-block`
     ;; aren't interpreted as backreferences.
     (regexp-replace managed-block-rx existing (lambda _ new-block))]
    [(string-blank? existing) new-block]
    [else (string-append existing "\n" new-block)]))

(define (strip-managed-block existing)
  (define stripped (regexp-replace managed-block-rx existing ""))
  (cond
    [(equal? stripped existing) (values existing #f)]
    [(string-blank? stripped) (values "" #t)]
    [else (values stripped #t)]))

(define (remove-shell-init-blocks!)
  (for/fold ([removed '()] #:result (reverse removed))
            ([rc (in-list (all-rc-paths))])
    (cond
      [(not (file-exists? rc)) removed]
      [else
       (define-values (updated changed?) (strip-managed-block (read-string-file rc "")))
       (cond
         [changed? (write-string-file rc updated) (cons rc removed)]
         [else removed])])))

(define (helper-shells)
  (if (windows?) '("powershell") '("bash" "zsh")))

(define (write-shell-helper-files!)
  (make-directory* (rackup-shell-dir))
  (for ([s (in-list (helper-shells))])
    (with-output-to-file (rackup-shell-script s)
      #:exists 'truncate/replace
      (lambda () (write-shell-helper-script s)))))

;; Refresh helper scripts in-place (e.g. after `self-upgrade`) so any
;; new commands or flags become tab-completable in existing shells
;; without requiring the user to rerun `rackup init`.  Only writes the
;; helper scripts; does NOT modify the user's rc files.  No-op if the
;; user has not previously run `rackup init` (no helper directory).
(define (refresh-shell-integration!)
  (when (directory-exists? (rackup-shell-dir))
    (write-shell-helper-files!)))

(define (init-shell! [shell-name #f])
  (ensure-rackup-layout!)
  (define shell* (or shell-name (guess-shell)))
  (unless (member shell* (helper-shells))
    (rackup-error "unsupported shell for init: ~a (use ~a)"
                  shell* (string-join (helper-shells) " or ")))
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (write-shell-helper-files!)
  ;; Returns the files written: the shell's rc file and, for bash, the
  ;; login file (see bash-login-path).
  (define rcs
    (cond
      [(equal? shell* "powershell") (powershell-init-paths)]
      [else
       (cons (rc-path shell*)
             (if (equal? shell* "bash")
                 (let ([login (bash-login-path)]) (if login (list login) null))
                 null))]))
  (for ([rc (in-list rcs)])
    (make-parent-directory* rc)
    (define existing (read-string-file rc ""))
    (write-string-file rc (replace-managed-block existing (managed-rc-block shell*))))
  rcs)

;; The execution policy a new PowerShell session gets.  The Process scope
;; is skipped: install.ps1 runs under `-ExecutionPolicy Bypass`, which a
;; child powershell.exe inherits through PSExecutionPolicyPreference.
(define profile-policy-command
  (string-append
   "$l = Get-ExecutionPolicy -List; "
   "foreach ($s in 'MachinePolicy','UserPolicy','CurrentUser','LocalMachine') { "
   "$p = \"$(($l | Where-Object { \"$($_.Scope)\" -eq $s }).ExecutionPolicy)\"; "
   "if ($p -and $p -ne 'Undefined') { $p; exit } }; 'Undefined'"))

;; PowerShell runs no profile under the Restricted or AllSigned execution
;; policies (Restricted is the default on Windows clients).  Returns a
;; hint for the user when the effective policy would block the profile,
;; else #f.  Asks powershell.exe, so it costs a process start.
(define (powershell-execution-policy-hint)
  ;; Windows PowerShell and PowerShell 7 keep separate policies.
  (define blocked
    (for*/list ([name (in-list '("powershell.exe" "pwsh.exe"))]
                [ps (in-value (find-executable-path name))]
                #:when ps
                [policy (in-value
                         (with-handlers ([exn:fail? (lambda (e) #f)])
                           (string-trim
                            (with-output-to-string
                              (lambda ()
                                (parameterize ([current-error-port (open-output-nowhere)]
                                               [current-environment-variables (powershell-environment)])
                                  (system* ps "-NoProfile" "-NonInteractive"
                                           "-Command" profile-policy-command)))))))]
                #:when (and policy
                            (member (string-downcase policy) '("restricted" "allsigned" "undefined"))))
      (format "~a (~a)" (if (equal? name "pwsh.exe") "PowerShell 7" "Windows PowerShell") policy)))
  (and (pair? blocked)
       (format (string-append
                "the execution policy of ~a does not run profile scripts,\n"
                "so `rackup switch` will not work there until you allow them; in that shell run:\n"
                "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned")
               (string-join blocked " and "))))

(module+ for-testing
  (provide shell-helper-script
           zsh-describe-escape
           powershell-profile-paths)
  (define (shell-helper-script shell-name)
    (with-output-to-string
      (lambda () (write-shell-helper-script shell-name)))))
