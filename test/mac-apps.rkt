#lang racket/base

(require rackunit
         racket/file
         racket/string
         "../libexec/rackup/mac-apps.rkt"
         (submod "../libexec/rackup/mac-apps.rkt" for-testing)
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/state.rkt")

(module+ test
  (define (with-temp-dir proc)
    (define dir (make-temporary-file "rackup-macapps-test~a" 'directory))
    (dynamic-wind void (lambda () (proc dir))
                  (lambda () (delete-directory/files dir #:must-exist? #f))))

  (define (read-file p) (file->string p))
  (define (app-dir apps display) (build-path apps (string-append display ".app")))

  ;; ---- info-plist -----------------------------------------------------

  (let ([pl (info-plist "DrRacket" "drracket" #f)])
    (check-true (string-contains? pl "<key>CFBundleExecutable</key>"))
    (check-true (string-contains? pl "<string>DrRacket</string>"))
    (check-true (string-contains? pl "org.racket-lang.rackup.drracket"))
    (check-true (string-contains? pl "<string>APPL</string>"))
    ;; No icon key unless an icon was written.
    (check-false (string-contains? pl "CFBundleIconFile")))
  (check-true (string-contains? (info-plist "DrRacket" "drracket" #t)
                                "<key>CFBundleIconFile</key>"))

  ;; ---- write-mac-app! bundle structure --------------------------------

  (with-temp-dir
   (lambda (apps)
     (define shim "/home/u/.rackup/shims/drracket")
     (define result (write-mac-app! apps "DrRacket" "drracket" shim))
     (define dir (app-dir apps "DrRacket"))
     (check-equal? result dir)
     ;; Bundle layout.
     (check-true (file-exists? (build-path dir "Contents" "Info.plist")))
     (check-true (file-exists? (build-path dir "Contents" "PkgInfo")))
     (define exe (build-path dir "Contents" "MacOS" "DrRacket"))
     (check-true (file-exists? exe))
     ;; Launcher is executable and execs the shim.
     (check-true (and (memq 'execute (file-or-directory-permissions exe)) #t)
                 "launcher must be executable")
     (define script (read-file exe))
     (check-true (string-prefix? script "#!/bin/sh"))
     (check-true (string-contains? script "exec '/home/u/.rackup/shims/drracket' \"$@\""))
     ;; Marker present -> recognized as ours.
     (check-true (rackup-managed-app? dir))))

  ;; ---- non-clobber: leave a user-owned bundle alone -------------------

  (with-temp-dir
   (lambda (apps)
     (define dir (app-dir apps "DrRacket"))
     (make-directory* (build-path dir "Contents" "MacOS"))
     (define exe (build-path dir "Contents" "MacOS" "DrRacket"))
     (call-with-output-file exe (lambda (o) (display "user's own app" o)))
     (check-false (rackup-managed-app? dir))
     (define result
       (parameterize ([current-error-port (open-output-string)])
         (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket")))
     ;; Refused, and the user's file is untouched.
     (check-false result)
     (check-equal? (read-file exe) "user's own app")))

  ;; ---- regenerate / remove integration --------------------------------

  (define (with-temp-rackup-home proc)
    (define home (make-temporary-file "rackup-macapps-home~a" 'directory))
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string home)))
    (dynamic-wind void
                  (lambda ()
                    (parameterize ([current-environment-variables env]) (proc home)))
                  (lambda () (delete-directory/files home #:must-exist? #f))))

  (with-temp-rackup-home
   (lambda (home)
     (ensure-index!)
     (define apps (build-path home "Applications"))
     (define drr (app-dir apps "DrRacket"))
     ;; A drracket shim exists for the GUI wrapper to point at.
     (call-with-output-file (build-path (rackup-shims-dir) "drracket")
       (lambda (o) (display "#!/bin/sh\n" o)))
     (parameterize ([current-mac-apps-os? #t]
                    [current-user-applications-dir apps])
       ;; Flag off -> nothing generated.
       (regenerate-mac-apps!)
       (check-false (directory-exists? drr))
       ;; Flag on -> wrapper generated.
       (set-config-flag! "mac-apps")
       (regenerate-mac-apps!)
       (check-true (directory-exists? drr))
       (check-true (rackup-managed-app? drr))
       ;; Flag on but shim gone -> stale wrapper removed.
       (delete-file (build-path (rackup-shims-dir) "drracket"))
       (regenerate-mac-apps!)
       (check-false (directory-exists? drr))
       ;; Regenerate (shim back), then clearing the flag removes it.
       (call-with-output-file (build-path (rackup-shims-dir) "drracket")
         (lambda (o) (display "#!/bin/sh\n" o)))
       (regenerate-mac-apps!)
       (check-true (directory-exists? drr))
       (clear-config-flag! "mac-apps")
       (regenerate-mac-apps!)
       (check-false (directory-exists? drr)))))

  ;; remove-mac-apps! removes managed wrappers but leaves user-owned ones.
  (with-temp-rackup-home
   (lambda (home)
     (ensure-index!)
     (define apps (build-path home "Applications"))
     (make-directory* apps)
     (parameterize ([current-mac-apps-os? #t]
                    [current-user-applications-dir apps])
       ;; Our managed wrapper.
       (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket")
       ;; A user-owned bundle with the same conventional name space.
       (define mine (app-dir apps "Slideshow"))
       (make-directory* (build-path mine "Contents"))
       (remove-mac-apps!)
       (check-false (directory-exists? (app-dir apps "DrRacket"))
                    "managed wrapper removed")
       (check-true (directory-exists? mine)
                   "unmanaged bundle left intact")))))
