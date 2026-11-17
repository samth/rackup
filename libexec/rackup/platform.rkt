#lang racket/base

;; Host-OS differences that the rest of rackup branches on.
;;
;; On Windows, rackup avoids symbolic links (they need Developer Mode or
;; an admin privilege) and shell scripts.  Executables carry an `.exe`
;; suffix, and every file reports the `execute` permission, so the suffix
;; is what marks a file as runnable.

(require racket/path
         racket/string)

(provide windows?
         exe-file-name
         executable-name?
         exe-file->tool-name
         path-list-separator
         set-file-mode!
         prepend-path-list-entry)

(define (windows?)
  (eq? (system-type 'os) 'windows))

;; The file name of the executable for tool `name` ("racket" ->
;; "racket.exe" on Windows, unchanged elsewhere).
(define (exe-file-name name)
  (if (windows?)
      (string-append name ".exe")
      name))

;; On Windows, true for a file name ending in `.exe`.  Elsewhere the
;; name says nothing, so this is always true and callers check the
;; permission bits.
(define (executable-name? p)
  (or (not (windows?))
      (let ([ext (path-get-extension p)])
        (and ext (string-ci=? (bytes->string/utf-8 ext) ".exe")))))

;; The tool name a shim uses for executable file `p`: the bare file name
;; on Unix, and the lowercased name without `.exe` on Windows
;; ("DrRacket.exe" -> "drracket"), since Windows file names are
;; case-insensitive.
(define (exe-file->tool-name p)
  (define name (path->string (file-name-from-path p)))
  (if (windows?)
      (string-downcase (regexp-replace #rx"(?i:[.]exe)$" name ""))
      name))

;; The separator in PATH-style lists (PATH, PLTCOMPILEDROOTS).
(define (path-list-separator)
  (if (windows?) ";" ":"))

;; `entry` followed by the entries of PATH-style list `old`, unless
;; `old` already has it.  Windows paths compare case-insensitively.
(define (prepend-path-list-entry entry old)
  (define sep (path-list-separator))
  (define (norm s) (if (windows?) (string-downcase s) s))
  (if (member (norm entry) (map norm (string-split old sep)))
      old
      (if (string=? old "")
          entry
          (string-append entry sep old))))

;; Set Unix permission bits.  A no-op on Windows, where Racket accepts
;; only read/write combinations and the bits carry no execute meaning.
(define (set-file-mode! p mode)
  (unless (windows?)
    (file-or-directory-permissions p mode)))
