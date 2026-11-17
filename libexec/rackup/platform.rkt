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
         prepend-path-list-entry
         powershell-environment
         pe-subsystem
         pe-with-subsystem
         gui-executable?
         pe-subsystem-gui
         pe-subsystem-console)

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

;; The environment for starting a PowerShell.  PowerShell 7 puts its own
;; module folders on PSModulePath, and a Windows PowerShell started from
;; it then fails to load even core cmdlets (Get-FileHash,
;; Get-ExecutionPolicy).  Without PSModulePath each PowerShell builds its
;; own default.
(define (powershell-environment)
  (define env (environment-variables-copy (current-environment-variables)))
  (environment-variables-set! env #"PSModulePath" #f)
  env)

;; --- PE headers ------------------------------------------------------------
;; The Subsystem field of a Windows executable decides whether it gets a
;; console.  It sits 68 bytes into the optional header, after "PE\0\0" and
;; the 20-byte COFF header, in both PE32 and PE32+ files.

(define pe-subsystem-gui 2)
(define pe-subsystem-console 3)

;; The offset of the Subsystem field in `bs` (the start of a file), or #f.
(define (pe-subsystem-offset bs)
  (define len (bytes-length bs))
  (and (>= len #x40)
       (= (bytes-ref bs 0) (char->integer #\M))
       (= (bytes-ref bs 1) (char->integer #\Z))
       (let* ([pe (integer-bytes->integer bs #f #f #x3C #x40)]
              [off (+ pe 4 20 68)])
         (and (<= (+ off 2) len)
              (equal? (subbytes bs pe (+ pe 4)) #"PE\0\0")
              off))))

(define (pe-subsystem bs)
  (define off (pe-subsystem-offset bs))
  (and off (integer-bytes->integer bs #f #f off (+ off 2))))

;; A copy of executable `bs` with its Subsystem set to `subsystem`.
;; Windows does not check the header checksum of programs.
(define (pe-with-subsystem bs subsystem)
  (define off (or (pe-subsystem-offset bs)
                  (error 'pe-with-subsystem "not a PE executable")))
  (define out (bytes-copy bs))
  (integer->integer-bytes subsystem 2 #f #f out off)
  out)

;; True when the file at `p` is a GUI-subsystem executable (DrRacket.exe).
(define (gui-executable? p)
  (define head
    (with-handlers ([exn:fail:filesystem? (lambda (e) #"")])
      (call-with-input-file p (lambda (in) (read-bytes 4096 in)))))
  (and (bytes? head)
       (equal? (pe-subsystem head) pe-subsystem-gui)))
