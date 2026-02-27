#lang at-exp racket/base

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/set
         racket/string
         "paths.rkt"
         "state.rkt"
         "rktd-io.rkt"
         "util.rkt")

(provide ensure-shim-dispatcher!
         ensure-core-rackup-shim!
         resolve-active-toolchain-id
         resolve-executable-path
         reshim!
         current-toolchain-source)

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
DEFAULT_FILE="$HOME_DIR/state/default-toolchain"
ENV_FILE=""
ACTIVE="${RACKUP_TOOLCHAIN:-}"
if [[ -z "$ACTIVE" && -f "$DEFAULT_FILE" ]]; then
  ACTIVE="$(tr -d '\r\n' < "$DEFAULT_FILE")"
fi
if [[ -z "$ACTIVE" ]]; then
  echo "rackup: '$SHIM_NAME' is managed by rackup, but no active toolchain is configured." >&2
  echo "Install one with: rackup install stable" >&2
  echo "Or select one with: rackup default <toolchain>" >&2
  echo "Inspect choices with: rackup list | rackup available --limit 20" >&2
  exit 2
fi
TARGET="$HOME_DIR/toolchains/$ACTIVE/bin/$SHIM_NAME"
ENV_FILE="$HOME_DIR/toolchains/$ACTIVE/env.sh"
if [[ ! -x "$TARGET" ]]; then
  echo "rackup: executable '$SHIM_NAME' not found in toolchain '$ACTIVE'" >&2
  echo "Try: rackup which $SHIM_NAME --toolchain $ACTIVE" >&2
  exit 127
fi
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
if [[ -z "${PLTADDONDIR:-}" ]]; then
  export PLTADDONDIR="$HOME_DIR/addons/$ACTIVE"
fi

rackup_warn_missing_loader() {
  local target="$1"
  local desc host_machine
  if ! command -v file >/dev/null 2>&1; then
    return 0
  fi
  desc="$(file "$target" 2>/dev/null || true)"
  case "$desc" in
    *"ELF 32-bit"*)
      host_machine="$(uname -m 2>/dev/null || true)"
      case "$host_machine" in
        x86_64|amd64)
          for loader in /lib/ld-linux.so.2 \
                        /lib32/ld-linux.so.2 \
                        /lib/i386-linux-gnu/ld-linux.so.2 \
                        /lib/i686-linux-gnu/ld-linux.so.2 \
                        /usr/i386-linux-gnu/lib/ld-linux.so.2; do
            if [[ -e "$loader" ]]; then
              return 0
            fi
          done
          echo "rackup: '$SHIM_NAME' from toolchain '$ACTIVE' is a 32-bit Linux executable, but this host appears to lack the 32-bit loader/runtime needed to start it." >&2
          echo "Try installing 32-bit compatibility packages, or use a newer x86_64-capable Racket/PLT release." >&2
          ;;
      esac
      ;;
  esac
}

if "$TARGET" "$@"; then
  exit 0
fi
STATUS=$?
case "$STATUS" in
  126|127) rackup_warn_missing_loader "$TARGET" ;;
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
  (define shim (build-path (rackup-shims-dir) "rackup"))
  (when (or (link-exists? shim) (file-exists? shim))
    (delete-file shim))
  (make-file-or-directory-link (rackup-bin-entry) shim)
  shim)

(define (resolve-active-toolchain-id)
  (define env (getenv "RACKUP_TOOLCHAIN"))
  (cond
    [(and env (not (string-blank? env))) env]
    [else (get-default-toolchain)]))

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
  (define p (build-path (rackup-toolchain-bin-link id) exe))
  (if (file-exists? p) p #f))

(define (rackup-managed-shim? p)
  (and (link-exists? p)
       (let ([target (simplify-path (resolve-path p) #t)])
         (or (equal? target (simplify-path (rackup-shim-dispatcher) #t))
             (equal? target (simplify-path (rackup-bin-entry) #t))))))

(define (all-installed-executables)
  (define ids (installed-toolchain-ids))
  (sort (remove-duplicates (append* (for/list ([id ids])
                                      (define m (read-toolchain-meta id))
                                      (if (and (hash? m) (list? (hash-ref m 'executables #f)))
                                          (hash-ref m 'executables)
                                          null))))
        string<?))

(define (reshim!)
  (ensure-shim-dispatcher!)
  (ensure-core-rackup-shim!)
  (define shims-dir (rackup-shims-dir))
  (define dispatcher (rackup-shim-dispatcher))
  (define desired
    (list->set (append '("rackup") bootstrap-shim-names (all-installed-executables))))
  (for ([name (in-set desired)])
    (unless (equal? name "rackup")
      (define p (build-path shims-dir name))
      (when (link-exists? p)
        (delete-file p))
      (make-file-or-directory-link dispatcher p)))
  (for ([p (in-list (directory-list shims-dir #:build? #t))])
    (define name (path-basename-string p))
    (when (and (not (set-member? desired name)) (rackup-managed-shim? p))
      (delete-file p))))
