#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/string
         "../libexec/rackup/mac-apps.rkt"
         (submod "../libexec/rackup/mac-apps.rkt" for-testing)
         "../libexec/rackup/paths.rkt"
         "../libexec/rackup/rktd-io.rkt"
         "../libexec/rackup/state.rkt")

(module+ test
  (define (with-temp-dir proc)
    (define dir (make-temporary-file "rackup-macapps-test~a" 'directory))
    (dynamic-wind void (lambda () (proc dir))
                  (lambda () (delete-directory/files dir #:must-exist? #f))))

  (define (read-file p) (file->string p))
  (define (app-dir apps display) (build-path apps (string-append display ".app")))

  (define (touch p [content ""])
    (make-directory* (let-values ([(d _ __) (split-path p)]) d))
    (call-with-output-file p #:exists 'replace (lambda (o) (display content o))))

  ;; Create a fake `.app` bundle under `root`.  `icons` is a list of icns
  ;; basenames to drop in Contents/Resources (e.g. '("DrRacket.icns")).
  (define (make-fake-app! root name #:icon? [icon? #f] #:icons [icons '()])
    (define res (build-path root (string-append name ".app") "Contents" "Resources"))
    (make-directory* res)
    (when icon? (touch (build-path res (string-append name ".icns")) "icns"))
    (for ([i (in-list icons)]) (touch (build-path res i) "icns"))
    (build-path root (string-append name ".app")))

  (define (icns-basename p) (and p (path->string (file-name-from-path p))))

  ;; ---- info-plist -----------------------------------------------------

  (let ([pl (info-plist "DrRacket" "drracket" #f)])
    (check-true (string-contains? pl "<key>CFBundleExecutable</key>"))
    (check-true (string-contains? pl "<string>DrRacket</string>"))
    (check-true (string-contains? pl "org.racket-lang.rackup.drracket"))
    (check-true (string-contains? pl "<string>APPL</string>"))
    (check-false (string-contains? pl "CFBundleIconFile")))
  (check-true (string-contains? (info-plist "DrRacket" "drracket" #t)
                                "<key>CFBundleIconFile</key>"))

  ;; ---- resolve-launcher ----------------------------------------------

  (with-temp-dir
   (lambda (shims)
     (for ([n '("drracket" "gracket" "plt-games")]) (touch (build-path shims n)))
     ;; lowercase mapping
     (check-equal? (resolve-launcher "DrRacket" shims) "drracket")
     (check-equal? (resolve-launcher "GRacket" shims) "gracket")
     ;; multi-word: space -> '-'
     (check-equal? (resolve-launcher "PLT Games" shims) "plt-games")
     ;; no matching shim -> #f
     (check-false (resolve-launcher "Nonesuch" shims))))

  ;; ---- find-gui-apps: discover all shipped GUI apps -------------------

  (with-temp-dir
   (lambda (root)
     (define install (build-path root "install"))
     (define shims (build-path root "shims"))
     (make-directory* shims)
     ;; Three top-level apps + one under lib/.  DrRacket ships several
     ;; icons (incl. document-type ones); GRacket ships only a non-matching
     ;; icon; Slideshow ships none.
     (make-fake-app! install "DrRacket" #:icons '("Document.icns" "DrRacket.icns" "Zebra.icns"))
     (make-fake-app! install "GRacket" #:icons '("misc-doc.icns"))
     (make-fake-app! install "NoLauncher")       ; has no shim -> skipped
     (make-fake-app! (build-path install "lib") "Slideshow")
     (for ([n '("drracket" "gracket" "slideshow")]) (touch (build-path shims n)))
     (define apps (find-gui-apps install shims))
     (define by-name
       (for/hash ([a (in-list apps)]) (values (gui-app-display a) a)))
     ;; DrRacket, GRacket, Slideshow discovered; NoLauncher skipped.
     (check-equal? (sort (hash-keys by-name) string<?)
                   '("DrRacket" "GRacket" "Slideshow"))
     (check-equal? (gui-app-launcher (hash-ref by-name "DrRacket")) "drracket")
     (check-equal? (gui-app-launcher (hash-ref by-name "Slideshow")) "slideshow")
     ;; Icon selection: the app-named `.icns` wins over document icons even
     ;; when it is not alphabetically first.
     (check-equal? (icns-basename (gui-app-icon (hash-ref by-name "DrRacket")))
                   "DrRacket.icns")
     ;; No name-matching icon -> fall back to the bundle's only `.icns`.
     (check-equal? (icns-basename (gui-app-icon (hash-ref by-name "GRacket")))
                   "misc-doc.icns")
     ;; No icon shipped -> none selected.
     (check-false (gui-app-icon (hash-ref by-name "Slideshow")))))

  ;; ---- write-mac-app! bundle structure --------------------------------

  (with-temp-dir
   (lambda (apps)
     (define shim "/home/u/.rackup/shims/drracket")
     (define result (write-mac-app! apps "DrRacket" "drracket" shim))
     (define dir (app-dir apps "DrRacket"))
     (check-equal? result dir)
     (check-true (file-exists? (build-path dir "Contents" "Info.plist")))
     (check-true (file-exists? (build-path dir "Contents" "PkgInfo")))
     (define exe (build-path dir "Contents" "MacOS" "DrRacket"))
     (check-true (file-exists? exe))
     (check-true (and (memq 'execute (file-or-directory-permissions exe)) #t)
                 "launcher must be executable")
     (define script (read-file exe))
     (check-true (string-prefix? script "#!/bin/sh"))
     (check-true (string-contains? script "exec '/home/u/.rackup/shims/drracket' \"$@\""))
     (check-true (rackup-managed-app? dir))))

  ;; ---- non-clobber: leave a user-owned bundle alone -------------------

  (with-temp-dir
   (lambda (apps)
     (define dir (app-dir apps "DrRacket"))
     (define exe (build-path dir "Contents" "MacOS" "DrRacket"))
     (touch exe "user's own app")
     (check-false (rackup-managed-app? dir))
     (define result
       (parameterize ([current-error-port (open-output-string)])
         (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket")))
     (check-false result)
     (check-equal? (read-file exe) "user's own app")))

  ;; ---- regenerate / remove integration --------------------------------

  (define test-tc "release-9.9-cs-x86_64-macosx-full")

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
     ;; A default toolchain whose install tree ships DrRacket + Slideshow.
     (write-string-file (rackup-default-file) test-tc)
     (define install (rackup-toolchain-install-dir test-tc))
     (make-fake-app! install "DrRacket" #:icon? #t)
     (make-fake-app! install "Slideshow")
     (for ([n '("drracket" "slideshow")])
       (touch (build-path (rackup-shims-dir) n)))
     (define apps (build-path home "Applications"))
     (define drr (app-dir apps "DrRacket"))
     (define slide (app-dir apps "Slideshow"))
     (parameterize ([current-mac-apps-os? #t]
                    [current-user-applications-dir apps])
       ;; Flag off -> nothing generated.
       (regenerate-mac-apps!)
       (check-false (directory-exists? drr))
       ;; Flag on -> a wrapper per discovered GUI app, with marker + icon.
       (set-config-flag! "mac-apps")
       (regenerate-mac-apps!)
       (check-true (directory-exists? drr))
       (check-true (directory-exists? slide))
       (check-true (rackup-managed-app? drr))
       ;; The source bundle's icon was copied in AND the Info.plist
       ;; references it (so Finder/Dock actually render it).  Slideshow
       ;; shipped no icon, so its wrapper has none and no icon key.
       (check-true (file-exists? (build-path drr "Contents" "Resources" "DrRacket.icns")))
       (check-true (string-contains? (read-file (build-path drr "Contents" "Info.plist"))
                                     "<key>CFBundleIconFile</key>")
                   "DrRacket wrapper Info.plist must reference its icon")
       (check-false (file-exists? (build-path slide "Contents" "Resources" "Slideshow.icns")))
       (check-false (string-contains? (read-file (build-path slide "Contents" "Info.plist"))
                                      "CFBundleIconFile")
                    "Slideshow wrapper has no icon, so no icon key")
       (check-equal? (length (managed-app-dirs apps)) 2)
       ;; Stop shipping Slideshow -> its stale wrapper is pruned, DrRacket stays.
       (delete-directory/files (build-path install "Slideshow.app"))
       (regenerate-mac-apps!)
       (check-true (directory-exists? drr))
       (check-false (directory-exists? slide))
       ;; Clearing the flag removes all managed wrappers.
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
       (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket")
       (define mine (app-dir apps "MyOwnEditor"))
       (make-directory* (build-path mine "Contents"))
       (check-equal? (length (managed-app-dirs apps)) 1)
       (remove-mac-apps!)
       (check-false (directory-exists? (app-dir apps "DrRacket"))
                    "managed wrapper removed")
       (check-true (directory-exists? mine)
                   "unmanaged bundle left intact")))))
