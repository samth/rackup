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

  ;; A stand-in for the macOS bundle builder (osacompile + plist tools) so
  ;; the discover/generate/prune/remove orchestration is exercisable on any
  ;; host.  It records what `write-mac-app!` forwarded — the droplet script
  ;; (with the embedded shim path), the copied icon, and the source bundle —
  ;; so tests can assert the wiring.  The real builder is covered by the
  ;; macOS CI job.
  (define (stub-build-bundle! app-dir display launcher shim-path icon-src src-app)
    (define contents (build-path app-dir "Contents"))
    (define macos (build-path contents "MacOS"))
    (define res (build-path contents "Resources"))
    (make-directory* macos)
    (make-directory* res)
    (touch (build-path macos "applet") (droplet-applescript shim-path))
    (when (and icon-src (file-exists? icon-src))
      (copy-file icon-src (build-path res (string-append display ".icns")) #t))
    (when src-app
      (touch (build-path res ".src-app") (path->string src-app)))
    (touch (build-path res ".rackup-managed") (string-append "rackup-managed:" launcher)))

  (define-syntax-rule (with-stub-builder body ...)
    (parameterize ([current-build-bundle! stub-build-bundle!]) body ...))

  ;; ---- droplet-applescript -------------------------------------------

  (let ([s (droplet-applescript "/home/u/.rackup/shims/drracket")])
    ;; Both entry points: plain launch and file open.
    (check-true (string-contains? s "on run"))
    (check-true (string-contains? s "on open theItems"))
    ;; The shim path is embedded as the command, dropped files appended.
    (check-true (string-contains? s "quoted form of \"/home/u/.rackup/shims/drracket\""))
    (check-true (string-contains? s "quoted form of POSIX path of anItem"))
    ;; Backgrounded so the applet returns while the GUI tool keeps running.
    (check-true (string-contains? s "do shell script shimCmd & \" > /dev/null 2>&1 &\"")))

  ;; Paths with shell/AppleScript metacharacters are escaped for the
  ;; AppleScript string literal (quotes/backslashes), spaces left as-is
  ;; (`quoted form of` shell-quotes at runtime).
  (let ([s (droplet-applescript "/home/od d/\"x\"\\y/shims/drracket")])
    (check-true (string-contains? s "/home/od d/\\\"x\\\"\\\\y/shims/drracket")))

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
     ;; The source bundle path is carried so generation can mirror its
     ;; document types and icons.
     (check-equal? (gui-app-src (hash-ref by-name "DrRacket"))
                   (build-path install "DrRacket.app"))
     ;; Icon selection: the app-named `.icns` wins over document icons even
     ;; when it is not alphabetically first.
     (check-equal? (icns-basename (gui-app-icon (hash-ref by-name "DrRacket")))
                   "DrRacket.icns")
     ;; No name-matching icon -> fall back to the bundle's only `.icns`.
     (check-equal? (icns-basename (gui-app-icon (hash-ref by-name "GRacket")))
                   "misc-doc.icns")
     ;; No icon shipped -> none selected.
     (check-false (gui-app-icon (hash-ref by-name "Slideshow")))))

  ;; ---- write-mac-app! orchestration -----------------------------------

  (with-temp-dir
   (lambda (apps)
     (define shim "/home/u/.rackup/shims/drracket")
     (define result (with-stub-builder
                     (write-mac-app! apps "DrRacket" "drracket" shim)))
     (define dir (app-dir apps "DrRacket"))
     (check-equal? result dir)
     ;; The droplet was built and carries the embedded shim path.
     (define applet (build-path dir "Contents" "MacOS" "applet"))
     (check-true (file-exists? applet))
     (check-true (string-contains? (read-file applet)
                                   "quoted form of \"/home/u/.rackup/shims/drracket\""))
     ;; The builder seals the ownership marker into the bundle.
     (check-true (rackup-managed-app? dir))
     (check-true (string-contains?
                  (read-file (build-path dir "Contents" "Resources" ".rackup-managed"))
                  "drracket"))))

  ;; ---- non-clobber: leave a user-owned bundle alone -------------------

  (with-temp-dir
   (lambda (apps)
     (define dir (app-dir apps "DrRacket"))
     (define exe (build-path dir "Contents" "MacOS" "DrRacket"))
     (touch exe "user's own app")
     (check-false (rackup-managed-app? dir))
     (define result
       (parameterize ([current-error-port (open-output-string)])
         (with-stub-builder
          (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket"))))
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
                    [current-user-applications-dir apps]
                    [current-build-bundle! stub-build-bundle!])
       ;; Flag off -> nothing generated.
       (regenerate-mac-apps!)
       (check-false (directory-exists? drr))
       ;; Flag on -> a wrapper per discovered GUI app, with marker.
       (set-config-flag! "mac-apps")
       (regenerate-mac-apps!)
       (check-true (directory-exists? drr))
       (check-true (directory-exists? slide))
       (check-true (rackup-managed-app? drr))
       ;; DrRacket ships an icon and a source bundle, so the builder gets
       ;; both: the icon is copied in and the source bundle recorded for
       ;; document-type mirroring.  Slideshow ships no icon.
       (check-true (file-exists? (build-path drr "Contents" "Resources" "DrRacket.icns")))
       (check-equal? (read-file (build-path drr "Contents" "Resources" ".src-app"))
                     (path->string (build-path install "DrRacket.app")))
       (check-false (file-exists? (build-path slide "Contents" "Resources" "Slideshow.icns")))
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
                    [current-user-applications-dir apps]
                    [current-build-bundle! stub-build-bundle!])
       (write-mac-app! apps "DrRacket" "drracket" "/x/shims/drracket")
       (define mine (app-dir apps "MyOwnEditor"))
       (make-directory* (build-path mine "Contents"))
       (check-equal? (length (managed-app-dirs apps)) 1)
       (remove-mac-apps!)
       (check-false (directory-exists? (app-dir apps "DrRacket"))
                    "managed wrapper removed")
       (check-true (directory-exists? mine)
                   "unmanaged bundle left intact")))))
