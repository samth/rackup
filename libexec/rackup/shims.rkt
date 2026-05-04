#lang racket/base

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/set
         racket/string
         "paths.rkt"
         "state.rkt"
         "state-lock.rkt"
         "error.rkt"
         "rktd-io.rkt"
         "fs.rkt"
         "process.rkt"
         "security.rkt"
         "text.rkt")

(provide ensure-shim-dispatcher!
         ensure-core-rackup-shim!
         resolve-active-toolchain-id
         resolve-executable-path
         reshim!
         current-toolchain-source
         shim-aliases-installed?
         install-shim-aliases!
         remove-shim-aliases!
         reprobe-local-toolchain)

(define bootstrap-shim-names
  '("racket" "raco"))

(define (dispatcher-script)
  #<<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF="${BASH_SOURCE[0]}"
LIBEXEC_DIR="$(cd -P "$(dirname "$SELF")" && pwd)"
HOME_DIR="${RACKUP_HOME:-$(cd -P "$LIBEXEC_DIR/.." && pwd)}"
SHIM_NAME="$(basename "$0")"
case "$SHIM_NAME" in
  r) SHIM_NAME=racket ;;
  dr) SHIM_NAME=drracket ;;
esac
DEFAULT_FILE="$HOME_DIR/state/default-toolchain"
DEFAULT_ID=""
ENV_FILE=""
ACTIVE="${RACKUP_TOOLCHAIN:-}"
if [[ -f "$DEFAULT_FILE" ]]; then
  DEFAULT_ID="$(tr -d '\r\n' < "$DEFAULT_FILE")"
fi
if [[ -z "$ACTIVE" && -n "$DEFAULT_ID" ]]; then
  ACTIVE="$DEFAULT_ID"
fi
if [[ -z "$ACTIVE" ]]; then
  echo "rackup: '$SHIM_NAME' is managed by rackup, but no active toolchain is configured." >&2
  echo "Install one with: rackup install stable" >&2
  echo "Or select one with: rackup default <toolchain>" >&2
  echo "Inspect choices with: rackup list | rackup available --limit 20" >&2
  exit 2
fi
if [[ ! "$ACTIVE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "rackup: invalid toolchain ID: $ACTIVE" >&2
  exit 2
fi
BIN_DIR="$HOME_DIR/toolchains/$ACTIVE/bin"
BIN_REAL="$(cd -P "$BIN_DIR" 2>/dev/null && pwd)" || BIN_REAL="$BIN_DIR"
TARGET="$BIN_REAL/$SHIM_NAME"
ENV_FILE="$HOME_DIR/toolchains/$ACTIVE/env.sh"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
if [[ -z "${PLTADDONDIR:-}" ]]; then
  export PLTADDONDIR="$HOME_DIR/addons/$ACTIVE"
fi
if [[ ! -x "$TARGET" ]]; then
  ADDON_TARGET=""
  for _candidate in "$PLTADDONDIR"/bin/"$SHIM_NAME" "$PLTADDONDIR"/*/bin/"$SHIM_NAME"; do
    if [[ -x "$_candidate" ]]; then
      ADDON_TARGET="$_candidate"
      break
    fi
  done
  if [[ -n "$ADDON_TARGET" ]]; then
    TARGET="$ADDON_TARGET"
  else
    echo "rackup: executable '$SHIM_NAME' not found in toolchain '$ACTIVE'" >&2
    if [[ -n "${RACKUP_TOOLCHAIN:-}" ]]; then
      if [[ -n "$DEFAULT_ID" ]]; then
        echo "rackup: active toolchain came from RACKUP_TOOLCHAIN and overrides default toolchain '$DEFAULT_ID'." >&2
      else
        echo "rackup: active toolchain came from RACKUP_TOOLCHAIN." >&2
      fi
      echo "Clear it with: rackup switch --unset" >&2
      echo "Or unset it manually with: unset RACKUP_TOOLCHAIN" >&2
    fi
    echo "Try: rackup which $SHIM_NAME --toolchain $ACTIVE" >&2
    exit 127
  fi
fi

rackup_is_elf32() {
  local probe="$1" header
  if ! command -v od >/dev/null 2>&1; then
    return 1
  fi
  header="$(od -An -t u1 -N 5 "$probe" 2>/dev/null | tr -s "[:space:]" " " | sed -e "s/^ //" -e "s/ $//")"
  [[ "$header" == "127 69 76 70 1" ]]
}

rackup_resolve_inspect_target() {
  local target="$1" inspect_target sys candidate
  local install_root
  install_root="$(dirname "$BIN_REAL")"
  inspect_target="$target"
  if ! rackup_is_elf32 "$inspect_target"; then
    if [[ -d "$install_root/.bin" ]]; then
      if [[ -x "$install_root/bin/archsys" ]]; then
        sys="$("$install_root/bin/archsys" z 2>/dev/null || true)"
        if [[ -n "$sys" && -x "$install_root/.bin/$sys/$SHIM_NAME" ]]; then
          inspect_target="$install_root/.bin/$sys/$SHIM_NAME"
        fi
      fi
      if [[ "$inspect_target" == "$target" ]]; then
        for candidate in "$install_root"/.bin/*/"$SHIM_NAME"; do
          if [[ -x "$candidate" ]]; then
            inspect_target="$candidate"
            break
          fi
        done
      fi
    fi
  fi
  printf '%s\n' "$inspect_target"
}

rackup_qemu_i386_binfmt_entry_path() {
  local root="${RACKUP_TEST_BINFMT_MISC_DIR:-/proc/sys/fs/binfmt_misc}"
  printf '%s/qemu-i386\n' "$root"
}

rackup_qemu_i386_binfmt_enabled() {
  local entry
  entry="$(rackup_qemu_i386_binfmt_entry_path)"
  if [[ ! -r "$entry" ]]; then
    return 1
  fi
  if ! grep -Fqx "enabled" "$entry" >/dev/null 2>&1; then
    return 1
  fi
  if ! grep -Fq "interpreter /usr/bin/qemu-i386" "$entry" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

rackup_host_machine() {
  if [[ -n "${RACKUP_TEST_HOST_MACHINE:-}" ]]; then
    printf '%s\n' "$RACKUP_TEST_HOST_MACHINE"
  else
    uname -m 2>/dev/null || true
  fi
}

rackup_i386_loader_present() {
  if [[ -n "${RACKUP_TEST_ASSUME_I386_LOADER:-}" ]]; then
    [[ "$RACKUP_TEST_ASSUME_I386_LOADER" == "1" ]]
    return
  fi
  for loader in /lib/ld-linux.so.2 \
                /lib32/ld-linux.so.2 \
                /lib/i386-linux-gnu/ld-linux.so.2 \
                /lib/i686-linux-gnu/ld-linux.so.2 \
                /usr/i386-linux-gnu/lib/ld-linux.so.2; do
    if [[ -e "$loader" ]]; then
      return 0
    fi
  done
  return 1
}

rackup_aslr_sensitive_legacy_i386_toolchain() {
  [[ "$ACTIVE" =~ ^release-(053|103|103p1)-bc-i386-linux- ]]
}

rackup_print_missing_loader_message() {
  local target="$1"
  local inspect_target host_machine
  inspect_target="$(rackup_resolve_inspect_target "$target")"
  if ! rackup_is_elf32 "$inspect_target"; then
    return 1
  fi
  host_machine="$(rackup_host_machine)"
  case "$host_machine" in
    x86_64|amd64)
      if rackup_i386_loader_present; then
        return 1
      fi
      echo "rackup: '$SHIM_NAME' from toolchain '$ACTIVE' needs 32-bit Linux runtime support, but this host appears to lack the 32-bit loader/runtime needed to start it." >&2
      if [[ "$inspect_target" != "$target" ]]; then
        echo "rackup: resolved underlying executable: $inspect_target" >&2
      fi
      echo "Try installing 32-bit compatibility packages, or use a newer x86_64-capable Racket/PLT release." >&2
      return 0
      ;;
  esac
  return 1
}

rackup_print_qemu_i386_aslr_message() {
  local target="$1"
  local inspect_target host_machine
  inspect_target="$(rackup_resolve_inspect_target "$target")"
  if ! rackup_is_elf32 "$inspect_target"; then
    return 1
  fi
  if ! rackup_aslr_sensitive_legacy_i386_toolchain; then
    return 1
  fi
  host_machine="$(rackup_host_machine)"
  case "$host_machine" in
    x86_64|amd64) ;;
    *) return 1 ;;
  esac
  if ! rackup_qemu_i386_binfmt_enabled; then
    return 1
  fi
  echo "rackup: '$SHIM_NAME' from toolchain '$ACTIVE' appears to be running through qemu-i386 via binfmt_misc on this host." >&2
  if [[ "$inspect_target" != "$target" ]]; then
    echo "rackup: resolved underlying executable: $inspect_target" >&2
  fi
  echo "rackup: for very old i386 PLT releases such as 053/103/103p1, 'setarch i386 -R' only helps when the binary is running natively, not through qemu-user." >&2
  echo "rackup: disable qemu-i386 binfmt_misc and retry, or use a true native i386 environment/VM." >&2
  return 0
}

if rackup_print_missing_loader_message "$TARGET"; then
  exit 126
fi

set +e
"$TARGET" "$@"
STATUS=$?
set -e
case "$STATUS" in
  126|127) rackup_print_missing_loader_message "$TARGET" || true ;;
  139) rackup_print_qemu_i386_aslr_message "$TARGET" || true ;;
esac
exit "$STATUS"
EOF
  )

(define (ensure-shim-dispatcher!)
  (ensure-rackup-layout!)
  (define p (rackup-shim-dispatcher))
  (write-string-file p (dispatcher-script))
  (file-or-directory-permissions p #o755)
  p)

(define (ensure-core-rackup-shim!)
  (ensure-rackup-layout!)
  (define shim (rackup-shim-path "rackup"))
  (replace-path! shim (rackup-bin-entry) #:mode 'link)
  shim)

(define (resolve-active-toolchain-id)
  (define env (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and env (not (string-blank? env)))
     (ensure-valid-toolchain-id! env "RACKUP_TOOLCHAIN")]
    [else
     (define default (get-default-toolchain))
     (and default (ensure-valid-toolchain-id! default "default-toolchain file"))]))

(define (current-toolchain-source)
  (define env (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and env (not (string-blank? env))) 'env]
    [(get-default-toolchain) 'default]
    [else #f]))

(define (resolve-executable-path exe [toolchain-id #f])
  (define id (or toolchain-id (resolve-active-toolchain-id)))
  (unless id
    (rackup-error "no active/default toolchain configured"))
  (define p (rackup-toolchain-exe-path id exe))
  (if (file-exists? p)
      p
      (find-addon-bin-exe (rackup-addon-dir id) exe)))

(define (rackup-managed-shim? p)
  (and (link-exists? p)
       (let ([target (simplify-path (resolve-path p) #t)])
         (or (equal? target (simplify-path (rackup-shim-dispatcher) #t))
             (equal? target (simplify-path (rackup-bin-entry) #t))))))

;; Return the list of bin directories under addon-dir to search for
;; user-scope executables: $PLTADDONDIR/bin/ and $PLTADDONDIR/*/bin/
;; (Racket nests user-scope packages under the installation name).
(define (addon-bin-dirs addon-dir)
  (cons (build-path addon-dir "bin")
        (if (directory-exists? addon-dir)
            (for/list ([sub (in-list (directory-list addon-dir #:build? #t))]
                       #:when (directory-exists? sub))
              (build-path sub "bin"))
            null)))

(define (find-addon-bin-exe addon-dir exe)
  (for/or ([bin-dir (in-list (addon-bin-dirs addon-dir))])
    (define candidate (build-path bin-dir exe))
    (and (file-exists? candidate) candidate)))

(define (addon-bin-executables id)
  (define addon-dir (rackup-addon-dir id))
  (define (bin-dir-executables bin-dir)
    (if (directory-exists? bin-dir)
        (for/list ([p (in-list (directory-list bin-dir #:build? #t))]
                   #:when (and (file-exists? p)
                               (member 'execute (file-or-directory-permissions p))))
          (path-basename-string p))
        null))
  (remove-duplicates
   (append* (for/list ([bin-dir (in-list (addon-bin-dirs addon-dir))])
              (bin-dir-executables bin-dir)))))

(define (all-installed-executables)
  (define ids (installed-toolchain-ids))
  (sort (remove-duplicates (append* (for/list ([id ids])
                                      (define m (read-toolchain-meta id))
                                      (append
                                       (if (and (hash? m) (list? (hash-ref m 'executables #f)))
                                           (hash-ref m 'executables)
                                           null)
                                       (addon-bin-executables id)))))
        string<?))

;; Short aliases: r -> racket, dr -> drracket.
;; The dispatcher script already contains the case statement to remap these.
;; These are opt-in: enabled via `rackup install --aliases` or
;; `rackup reshim --aliases`.
(define shim-alias-pairs '(("r" . "racket") ("dr" . "drracket")))

(define (shim-aliases-installed?)
  (and (config-flag-set? "short-aliases") #t))

(define/state-locked (install-shim-aliases!)
  (set-config-flag! "short-aliases"))

(define/state-locked (remove-shim-aliases!)
  (clear-config-flag! "short-aliases"))

(define (write-env-file! id env-vars)
  (define p (rackup-toolchain-env-file id))
  (define body
    (string-append "#!/usr/bin/env bash\n"
                   "# rackup managed toolchain environment\n"
                   (apply string-append
                          (for/list ([kv (in-list env-vars)])
                            (env-var-export-line (car kv) (cdr kv))))))
  (define existing
    (and (file-exists? p)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (file->string p))))
  (unless (equal? existing body)
    (write-string-file p body)
    (file-or-directory-permissions p #o644)))

(define (delete-env-file! id)
  (define p (rackup-toolchain-env-file id))
  (when (file-exists? p)
    (delete-file p)))

;; Re-probe a linked toolchain's racket binary.  Returns (values
;; version variant addon-dir), all #f if the binary is missing or
;; fails to run.  Restores _RACKUP_ORIG_PLTCOMPILEDROOTS so the probe
;; can find its own .zo files.
(define (reprobe-local-toolchain real-bin-dir-str)
  (cond
    [(not (string? real-bin-dir-str)) (values #f #f #f)]
    [(not (file-exists? (build-path (string->path real-bin-dir-str) "racket")))
     (values #f #f #f)]
    [else
     (probe-local-racket-version+variant+addon-dir
      real-bin-dir-str (saved-pltcompiledroots-env))]))

(define (saved-pltcompiledroots-env)
  (define saved (getenv "_RACKUP_ORIG_PLTCOMPILEDROOTS"))
  (if saved (list (cons "PLTCOMPILEDROOTS" saved)) null))

(define (lookup-env-var alist key)
  (define p (assoc key alist))
  (and p (cadr p)))

;; Re-probe the linked toolchain's racket binary on every call so
;; addon-dir, version, and variant reflect the current source-tree
;; state.  Returns the new env-vars list and the probed (or fallback)
;; version+variant.  Does not fall back to <source-root>/add-on for
;; PLTADDONDIR: that location is usually wrong for users whose
;; packages live in their native addon-dir.
(define (compute-local-env-vars meta)
  (define real-bin-dir-str (hash-ref meta 'real-bin-dir #f))
  (define-values (probed-version probed-variant probed-addon)
    (reprobe-local-toolchain real-bin-dir-str))
  (define version (or probed-version (hash-ref meta 'resolved-version #f)))
  (define variant
    (or (and probed-variant (string->symbol probed-variant))
        (hash-ref meta 'variant #f)))
  (define addon-dir
    (or probed-addon
        (lookup-env-var (hash-ref meta 'env-vars '()) "PLTADDONDIR")))
  (define addon-entry
    (if (and (string? addon-dir) (not (string-blank? addon-dir)))
        (list (cons "PLTADDONDIR" addon-dir))
        null))
  (define existing-roots
    (if real-bin-dir-str
        (read-toolchain-compiled-file-roots (string->path real-bin-dir-str))
        '(same)))
  (define local-name
    (and (eq? (hash-ref meta 'kind #f) 'local)
         (hash-ref meta 'requested-spec #f)))
  (define compiled-roots-entry
    (cond
      [(compiled-roots-value version variant existing-roots local-name)
       =>
       (lambda (v) (list (cons "PLTCOMPILEDROOTS" v)))]
      [else null]))
  (values (append addon-entry compiled-roots-entry)
          version
          variant))

;; Backfill PLTCOMPILEDROOTS into an installed toolchain whose metadata
;; predates per-toolchain compiled roots.  Adds the entry to env-vars in
;; meta.rktd and rewrites env.sh.  Idempotent: does nothing if the
;; toolchain already has PLTCOMPILEDROOTS or if a value cannot be
;; computed from its version+variant.
(define (backfill-installed-env-vars! id meta)
  (define current (meta->env-vars meta))
  (define has-pcr? (assoc "PLTCOMPILEDROOTS" current))
  (define computed-pcr
    (compiled-roots-value (hash-ref meta 'resolved-version #f)
                          (hash-ref meta 'variant #f)))
  (when (and computed-pcr (not has-pcr?))
    (define new-env-vars
      (append current (list (cons "PLTCOMPILEDROOTS" computed-pcr))))
    (define new-meta
      (hash-set meta 'env-vars
                (for/list ([kv (in-list new-env-vars)])
                  (list (car kv) (cdr kv)))))
    (write-toolchain-meta! id new-meta)
    (write-env-file! id new-env-vars)))

(define (regenerate-env-files!)
  (for ([id (in-list (installed-toolchain-ids))])
    (define meta (read-toolchain-meta id))
    (when (hash? meta)
      (define kind (hash-ref meta 'kind #f))
      (cond
        ;; Replacing env-vars wholesale also cleans up legacy
        ;; PLTHOME/PLTCOLLECTS entries from older rackup versions.
        [(eq? kind 'local)
         (define-values (env-vars new-version new-variant)
           (compute-local-env-vars meta))
         (define updates
           (filter values
                   (list (cons 'env-vars
                               (for/list ([kv (in-list env-vars)])
                                 (list (car kv) (cdr kv))))
                         (and new-version (cons 'resolved-version new-version))
                         (and new-variant (cons 'variant new-variant)))))
         (define new-meta
           (for/fold ([m meta]) ([u (in-list updates)])
             (hash-set m (car u) (cdr u))))
         (unless (equal? new-meta meta)
           (write-toolchain-meta! id new-meta))
         (if (pair? env-vars)
             (write-env-file! id env-vars)
             (delete-env-file! id))]
        [else
         (backfill-installed-env-vars! id meta)]))))

(define/state-locked (reshim!)
  (regenerate-env-files!)
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (define shims-dir (rackup-shims-dir))
  (define dispatcher (rackup-shim-dispatcher))
  (define aliases-on? (shim-aliases-installed?))
  (define desired
    (list->set (append '("rackup")
                       bootstrap-shim-names
                       (all-installed-executables)
                       (if aliases-on? (map car shim-alias-pairs) null))))
  (for ([name (in-set desired)])
    (unless (equal? name "rackup")
      (define p (build-path shims-dir name))
      (replace-path! p dispatcher #:mode 'link)))
  (for ([p (in-list (directory-list shims-dir #:build? #t))])
    (define name (path-basename-string p))
    (when (and (not (set-member? desired name)) (rackup-managed-shim? p))
      (delete-file p))))
