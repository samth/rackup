#lang racket/base

;; The user's persistent environment on Windows (HKCU\Environment), which
;; scripts/install.ps1 edits to put the shims folder on PATH and to record
;; RACKUP_HOME.  `rackup uninstall` undoes both.
;;
;; The registry is read and written raw, so a REG_EXPAND_SZ Path keeps its
;; %VAR% references and its type.  The FFI bindings load only when a
;; function that needs them is called, so this module loads everywhere.

(require ffi/unsafe
         racket/list
         racket/string)

(provide remove-path-list-entry
         user-env-get
         user-env-set!
         user-env-delete!
         broadcast-environment-change!
         remove-user-path-entry!
         remove-user-env-var-if!)

;; `old` (a ;-separated list) without the entries naming directory `dir`.
;; Windows paths compare case-insensitively and with or without a trailing
;; backslash.  Empty entries are dropped.  Returns #f when nothing changed.
(define (remove-path-list-entry old dir)
  (define (norm s) (string-downcase (string-trim (string-trim s) "\\" #:left? #f #:repeat? #t)))
  (define target (norm dir))
  (define entries (string-split old ";"))
  (define kept (filter (lambda (e) (and (not (string=? (string-trim e) ""))
                                        (not (string=? (norm e) target))))
                       entries))
  (and (< (length kept) (length (filter (lambda (e) (not (string=? (string-trim e) ""))) entries)))
       (string-join kept ";")))

;; --- UTF-16LE -------------------------------------------------------------

(define (string->utf-16le s)
  (define out (open-output-bytes))
  (define (put u) (write-byte (bitwise-and u #xff) out) (write-byte (arithmetic-shift u -8) out))
  (for ([c (in-string s)])
    (define n (char->integer c))
    (cond
      [(< n #x10000) (put n)]
      [else
       (define m (- n #x10000))
       (put (+ #xD800 (arithmetic-shift m -10)))
       (put (+ #xDC00 (bitwise-and m #x3ff)))]))
  (put 0)
  (get-output-bytes out))

(define (utf-16le->string bs)
  (define n (quotient (bytes-length bs) 2))
  (define units (for/list ([i (in-range n)])
                  (+ (bytes-ref bs (* 2 i)) (arithmetic-shift (bytes-ref bs (add1 (* 2 i))) 8))))
  (let loop ([us (takef units (lambda (u) (not (zero? u))))] [acc '()])
    (cond
      [(null? us) (list->string (reverse acc))]
      [(and (<= #xD800 (car us) #xDBFF) (pair? (cdr us)) (<= #xDC00 (cadr us) #xDFFF))
       (loop (cddr us)
             (cons (integer->char (+ #x10000
                                     (arithmetic-shift (- (car us) #xD800) 10)
                                     (- (cadr us) #xDC00)))
                   acc))]
      [(<= #xD800 (car us) #xDFFF) (loop (cdr us) (cons (integer->char #xFFFD) acc))]
      [else (loop (cdr us) (cons (integer->char (car us)) acc))])))

;; --- FFI ------------------------------------------------------------------

(define REG_SZ 1)
(define REG_EXPAND_SZ 2)
(define KEY_QUERY_VALUE #x0001)
(define KEY_SET_VALUE #x0002)
(define ERROR_SUCCESS 0)
(define ERROR_FILE_NOT_FOUND 2)
(define HWND_BROADCAST #xffff)
(define WM_SETTINGCHANGE #x001A)
(define SMTO_ABORTIFHUNG #x0002)

(define _HKEY _intptr)
(define HKEY_CURRENT_USER (- #x80000001 (expt 2 32)))
(define winapi (if (equal? (system-type 'word) 32) 'stdcall #f))

(define ffi-cache (make-hash))
(define (win-fun lib name type)
  (hash-ref! ffi-cache name
             (lambda () (get-ffi-obj name (ffi-lib lib) type))))

(define (RegOpenKeyExW)
  (win-fun "advapi32" "RegOpenKeyExW"
           (_fun #:abi winapi _HKEY _string/utf-16 _uint32 _uint32 (r : (_ptr o _HKEY))
                 -> (status : _int32) -> (values status r))))
(define (RegCloseKey)
  (win-fun "advapi32" "RegCloseKey" (_fun #:abi winapi _HKEY -> _int32)))
(define (RegQueryValueExW)
  (win-fun "advapi32" "RegQueryValueExW"
           (_fun #:abi winapi _HKEY _string/utf-16 _pointer (type : (_ptr o _uint32))
                 _pointer (len : (_ptr io _uint32))
                 -> (status : _int32) -> (values status type len))))
(define (RegSetValueExW)
  (win-fun "advapi32" "RegSetValueExW"
           (_fun #:abi winapi _HKEY _string/utf-16 _uint32 _uint32 _bytes _uint32 -> _int32)))
(define (RegDeleteValueW)
  (win-fun "advapi32" "RegDeleteValueW" (_fun #:abi winapi _HKEY _string/utf-16 -> _int32)))
(define (SendMessageTimeoutW)
  (win-fun "user32" "SendMessageTimeoutW"
           (_fun #:abi winapi _intptr _uint32 _uintptr _string/utf-16 _uint32 _uint32 _pointer
                 -> _intptr)))

(define (call-with-environment-key access proc)
  (define-values (status key) ((RegOpenKeyExW) HKEY_CURRENT_USER "Environment" 0 access))
  (unless (= status ERROR_SUCCESS)
    (error 'rackup "cannot open HKEY_CURRENT_USER\\Environment (error ~a)" status))
  (dynamic-wind void (lambda () (proc key)) (lambda () ((RegCloseKey) key))))

;; The raw value of user environment variable `name` and whether it is
;; REG_EXPAND_SZ, or (values #f #f) when it is not set.
(define (user-env-get name)
  (call-with-environment-key
   KEY_QUERY_VALUE
   (lambda (key)
     (define-values (s0 type0 len0) ((RegQueryValueExW) key name #f #f 0))
     (cond
       [(= s0 ERROR_FILE_NOT_FOUND) (values #f #f)]
       [(not (= s0 ERROR_SUCCESS)) (error 'rackup "cannot read user variable ~a (error ~a)" name s0)]
       [else
        (define buf (make-bytes (+ len0 2) 0))
        (define-values (s type len) ((RegQueryValueExW) key name #f buf (bytes-length buf)))
        (unless (= s ERROR_SUCCESS)
          (error 'rackup "cannot read user variable ~a (error ~a)" name s))
        (values (utf-16le->string (subbytes buf 0 len)) (= type REG_EXPAND_SZ))]))))

(define (user-env-set! name value expand?)
  (call-with-environment-key
   KEY_SET_VALUE
   (lambda (key)
     (define data (string->utf-16le value))
     (define s ((RegSetValueExW) key name 0 (if expand? REG_EXPAND_SZ REG_SZ) data (bytes-length data)))
     (unless (= s ERROR_SUCCESS)
       (error 'rackup "cannot set user variable ~a (error ~a)" name s)))))

(define (user-env-delete! name)
  (call-with-environment-key
   KEY_SET_VALUE
   (lambda (key)
     (define s ((RegDeleteValueW) key name))
     (unless (memv s (list ERROR_SUCCESS ERROR_FILE_NOT_FOUND))
       (error 'rackup "cannot remove user variable ~a (error ~a)" name s)))))

;; Tell running programs (Explorer in particular) that the environment
;; changed, so terminals started afterwards see it.
(define (broadcast-environment-change!)
  ((SendMessageTimeoutW) HWND_BROADCAST WM_SETTINGCHANGE 0 "Environment"
                         SMTO_ABORTIFHUNG 5000 #f)
  (void))

;; Remove directory `dir` from the user's Path.  Returns #t when it was there.
(define (remove-user-path-entry! dir)
  (define-values (old expand?) (user-env-get "Path"))
  (define new (and old (remove-path-list-entry old dir)))
  (cond
    [new
     (if (string=? new "")
         (user-env-delete! "Path")
         (user-env-set! "Path" new expand?))
     #t]
    [else #f]))

;; Remove user variable `name` when `remove?` accepts its value.  Returns #t
;; when it was removed.
(define (remove-user-env-var-if! name remove?)
  (define-values (v _expand?) (user-env-get name))
  (cond
    [(and v (remove? v)) (user-env-delete! name) #t]
    [else #f]))

(module+ for-testing
  (provide string->utf-16le utf-16le->string))
