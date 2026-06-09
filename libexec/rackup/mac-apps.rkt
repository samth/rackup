#lang racket/base

;; macOS `.app` wrappers for GUI tools (issue #10).
;;
;; rackup-managed GUI tools (DrRacket and any other GUI apps the macOS
;; installer ships) live deep under `~/.rackup` and are launched from the
;; command line via shims, so they are invisible to Finder, Spotlight, and
;; the Dock.  When the `mac-apps` config flag is set (via `rackup install
;; --mac-apps` / `rackup reshim --mac-apps`), rackup writes small wrapper
;; bundles into `~/Applications` so the GUI tools can be opened like any
;; other macOS app.
;;
;; The set of wrappers is discovered, not hardcoded: at reshim time we scan
;; the default toolchain's install tree for `*.app` bundles (this is where
;; the macOS DMG/tgz distribution drops `DrRacket.app` et al.) and generate a
;; wrapper for each one that has a corresponding `bin/` launcher (shim).  So
;; whatever GUI apps a given Racket distribution ships are handled.
;;
;; Each wrapper is an AppleScript *droplet* built with `osacompile`.  Its
;; `on open` handler turns files dropped on the Dock/Finder icon (or
;; double-clicked) into a command line and runs the matching rackup shim
;; (e.g. `~/.rackup/shims/drracket file.rkt`); `on run` (a plain launch)
;; runs the shim with no file.  Routing through the shim means the app
;; always launches the *default* toolchain's tool, with the toolchain's
;; environment set up, and — crucially — through the shim's `cd -P`
;; bin-symlink resolution (issue #37), which a GUI Racket binary requires on
;; aarch64 macOS to avoid an `invalid memory reference` crash in
;; `cocoa/queue.rkt`.  A wrapper that pointed at a symlinked path directly
;; would reintroduce that crash.
;;
;; For double-click parity with the real DMG install, we mirror the source
;; bundle's `CFBundleDocumentTypes` into the wrapper (copied straight out of
;; the shipped `.app`), so e.g. DrRacket's wrapper registers as the editor
;; for `.rkt`/`.scrbl`/etc. just as the real `DrRacket.app` does.  Apps that
;; declare no document types (Slideshow, PLT Games) keep `osacompile`'s
;; default accept-any-file droplet behavior, so they still work as plain
;; drop targets.
;;
;; Wrappers carry a marker file (`Contents/Resources/.rackup-managed`) so we
;; only ever overwrite or delete bundles we created — a user's own
;; `~/Applications/DrRacket.app` is left untouched.

(require racket/file
         racket/list
         racket/path
         racket/set
         racket/string
         racket/system
         "error.rkt"
         "paths.rkt"
         "process.rkt"
         "rktd-io.rkt"
         "state.rkt"
         "state-lock.rkt"
         "text.rkt")

(provide mac-apps-enabled?
         install-mac-apps!
         remove-mac-apps-flag!
         regenerate-mac-apps!
         remove-mac-apps!)

(module+ for-testing
  (provide (struct-out gui-app)
           current-mac-apps-os?
           current-user-applications-dir
           current-build-bundle!
           find-gui-apps
           resolve-launcher
           managed-app-dirs
           droplet-applescript
           write-mac-app!
           rackup-managed-app?))

(struct gui-app (display launcher icon src) #:transparent)

(define mac-apps-flag "mac-apps")
(define managed-marker ".rackup-managed")

;; Seams so tests can exercise generation/removal on non-macOS hosts and
;; without writing to the real ~/Applications.
(define current-mac-apps-os?
  (make-parameter (eq? (system-type 'os) 'macosx)))
(define current-user-applications-dir
  (make-parameter (build-path (find-system-path 'home-dir) "Applications")))

(define (path-exists? p)
  (or (file-exists? p) (directory-exists? p) (link-exists? p)))

(define (mac-apps-enabled?)
  (and (config-flag-set? mac-apps-flag) #t))

(define/state-locked (install-mac-apps!)
  (set-config-flag! mac-apps-flag))

(define/state-locked (remove-mac-apps-flag!)
  (clear-config-flag! mac-apps-flag))

;; ---- discovery ------------------------------------------------------

(define (app-bundle? p)
  (and (directory-exists? p)
       (equal? (path-get-extension p) #".app")))

(define (app-display-name app-path)
  (regexp-replace #rx"[.]app$" (path-basename-string app-path) ""))

;; `*.app` bundles directly under `dir` (not recursive).
(define (app-bundles-in dir)
  (if (directory-exists? dir)
      (filter app-bundle? (directory-list dir #:build? #t))
      '()))

;; Map a bundle display name to a `bin/` launcher that has a shim.  The
;; macOS launcher for an app is the lowercased app name (DrRacket ->
;; drracket, GRacket -> gracket); also try space->`-` and space-stripped
;; forms for multi-word names.  Returns the launcher string or #f.
(define (resolve-launcher display shims-dir)
  (define lower (string-downcase display))
  (for/or ([cand (in-list (remove-duplicates
                           (list lower
                                 (regexp-replace* #px"\\s+" lower "-")
                                 (regexp-replace* #px"\\s+" lower ""))))])
    (and (not (string=? cand ""))
         (file-exists? (build-path shims-dir cand))
         cand)))

;; The app's icon, from its `Contents/Resources`.  Prefer `<display>.icns`
;; (the app icon by Racket/macOS convention, e.g. DrRacket.icns); fall back
;; to the first `.icns` so we still pick *some* icon — a bundle may also ship
;; document-type icons, but a matching name is the app icon.
(define (find-icns app-path display)
  (define res (build-path app-path "Contents" "Resources"))
  (and (directory-exists? res)
       (let ([named (build-path res (string-append display ".icns"))])
         (if (file-exists? named)
             named
             (for/or ([p (in-list (sort (directory-list res #:build? #t)
                                        string<? #:key path->string))]
                      #:when (equal? (path-get-extension p) #".icns"))
               p)))))

;; All GUI apps to wrap for a toolchain: each `*.app` under `install-dir`
;; (and its `lib/`) whose launcher has a shim, de-duplicated by name.
(define (find-gui-apps install-dir shims-dir)
  (define roots (list install-dir (build-path install-dir "lib")))
  (let loop ([apps (append-map app-bundles-in roots)] [seen (set)] [acc '()])
    (cond
      [(null? apps) (reverse acc)]
      [else
       (define app (car apps))
       (define display (app-display-name app))
       (define launcher (resolve-launcher display shims-dir))
       (if (or (set-member? seen display) (not launcher))
           (loop (cdr apps) seen acc)
           (loop (cdr apps) (set-add seen display)
                 (cons (gui-app display launcher (find-icns app display) app) acc)))])))

;; ---- droplet AppleScript --------------------------------------------

(define (applescript-escape s)
  (apply string-append
         (for/list ([c (in-string s)])
           (cond
             [(char=? c #\\) "\\\\"]
             [(char=? c #\") "\\\""]
             [else (string c)]))))

;; AppleScript source for a droplet that forwards dropped/opened files to
;; `shim-path`.  `on open` fires for documents dropped on the icon or
;; double-clicked; `on run` is a plain launch.  Each file becomes a
;; shell-quoted argument, so DrRacket et al. open them just as on the
;; command line.  The shell command is backgrounded and detached so the
;; applet returns immediately while the GUI tool keeps running.
(define (droplet-applescript shim-path)
  (define lit (applescript-escape shim-path))
  (string-append
   "on run\n"
   "\tmy launchItems({})\n"
   "end run\n"
   "\n"
   "on open theItems\n"
   "\tmy launchItems(theItems)\n"
   "end open\n"
   "\n"
   "on launchItems(theItems)\n"
   "\tset shimCmd to quoted form of \"" lit "\"\n"
   "\trepeat with anItem in theItems\n"
   "\t\tset shimCmd to shimCmd & \" \" & quoted form of POSIX path of anItem\n"
   "\tend repeat\n"
   "\tdo shell script shimCmd & \" > /dev/null 2>&1 &\"\n"
   "end launchItems\n"))

;; ---- bundle writing -------------------------------------------------

(define (app-bundle-dir apps-dir display)
  (build-path apps-dir (string-append display ".app")))

(define (rackup-managed-app? app-dir)
  (file-exists? (build-path app-dir "Contents" "Resources" managed-marker)))

;; Generation-time macOS tools.  Only invoked through `real-build-bundle!`,
;; which the OS gate keeps off non-macOS hosts (and tests stub out).
(define (osacompile-path) (find-executable-path/default "osacompile" "/usr/bin/osacompile"))
(define (plutil-path) (find-executable-path/default "plutil" "/usr/bin/plutil"))
(define (codesign-path) (find-executable-path/default "codesign" "/usr/bin/codesign"))
(define plistbuddy-path (string->path "/usr/libexec/PlistBuddy"))

;; osacompile ad-hoc signs the droplet stub; editing the Info.plist and
;; resources afterward breaks that seal, which aarch64 macOS rejects at
;; launch.  Re-sign ad-hoc as the final step.  Best-effort: a signing
;; failure must not abort reshim.
(define (codesign-adhoc! app-dir)
  (system* (codesign-path) "--force" "--sign" "-" (path->string app-dir)))

(define (plist-file app-dir) (build-path app-dir "Contents" "Info.plist"))

;; Set a string key, creating it if `osacompile`'s default plist lacks it.
(define (plist-set-string! plist key value)
  (define p (path->string plist))
  (or (system* plistbuddy-path "-c" (format "Set :~a ~a" key value) p)
      (system* plistbuddy-path "-c" (format "Add :~a string ~a" key value) p)))

(define (compile-droplet! app-dir shim-path)
  (define tmp (make-temporary-file "rackup-droplet-~a.applescript"))
  (dynamic-wind
   void
   (lambda ()
     (write-string-file tmp (droplet-applescript shim-path))
     (system*/check "osacompile"
                    (osacompile-path) "-o" (path->string app-dir) (path->string tmp)))
   (lambda () (delete-file tmp))))

;; Copy every `.icns` from `src-res` into `dst-res` (document-type icons the
;; mirrored `CFBundleDocumentTypes` reference, e.g. DrRacket's doc/pltdoc).
(define (copy-icns! src-res dst-res)
  (when (directory-exists? src-res)
    (make-directory* dst-res)
    (for ([p (in-list (directory-list src-res #:build? #t))]
          #:when (equal? (path-get-extension p) #".icns"))
      (copy-file p (build-path dst-res (file-name-from-path p)) #t))))

;; Mirror the source bundle's `CFBundleDocumentTypes` into the wrapper so it
;; registers for exactly the file types the real app does (double-click
;; parity).  Replaces `osacompile`'s accept-all droplet types.  A bundle
;; that declares none keeps the accept-all default, so it still takes drops.
(define (mirror-document-types! app-dir src-app)
  (define src-plist (build-path src-app "Contents" "Info.plist"))
  (define wrap-plist (path->string (plist-file app-dir)))
  (when (file-exists? src-plist)
    (define tmp (make-temporary-file "rackup-doctypes-~a.plist"))
    (dynamic-wind
     void
     (lambda ()
       (when (and (system* (plutil-path) "-extract" "CFBundleDocumentTypes" "xml1"
                           "-o" (path->string tmp) (path->string src-plist))
                  (file-exists? tmp)
                  (> (file-size tmp) 0))
         ;; Drop osacompile's accept-all entry, then graft the source's.
         (system* plistbuddy-path "-c" "Delete :CFBundleDocumentTypes" wrap-plist)
         (system*/check "PlistBuddy add CFBundleDocumentTypes"
                        plistbuddy-path "-c" "Add :CFBundleDocumentTypes array" wrap-plist)
         (system*/check "PlistBuddy merge CFBundleDocumentTypes"
                        plistbuddy-path
                        "-c" (format "Merge ~a :CFBundleDocumentTypes" (path->string tmp))
                        wrap-plist)
         (copy-icns! (build-path src-app "Contents" "Resources")
                     (build-path app-dir "Contents" "Resources"))))
     (lambda () (delete-file tmp)))))

;; Write the rackup-managed marker into a bundle's Resources.  This is what
;; `rackup-managed-app?` keys on, so it must land before the bundle is
;; sealed (any later change would invalidate the signature).
(define (write-managed-marker! app-dir launcher)
  (define resources (build-path app-dir "Contents" "Resources"))
  (make-directory* resources)
  (write-string-file (build-path resources managed-marker)
                     (string-append "rackup-managed:" launcher)))

;; The real (macOS) bundle builder: compile the droplet, patch its
;; identity/icon, mirror document types, drop the marker, and re-sign.
;; Tests swap this out.
(define (real-build-bundle! app-dir display launcher shim-path icon-src src-app)
  (compile-droplet! app-dir shim-path)
  (define plist (plist-file app-dir))
  (plist-set-string! plist "CFBundleName" display)
  (plist-set-string! plist "CFBundleDisplayName" display)
  (plist-set-string! plist "CFBundleIdentifier"
                     (string-append "org.racket-lang.rackup." launcher))
  (when (and icon-src (file-exists? icon-src))
    (define res (build-path app-dir "Contents" "Resources"))
    (make-directory* res)
    (copy-file icon-src (build-path res (string-append display ".icns")) #t)
    (plist-set-string! plist "CFBundleIconFile" display))
  (when src-app (mirror-document-types! app-dir src-app))
  (write-managed-marker! app-dir launcher)
  (codesign-adhoc! app-dir))

;; Seam: the procedure that materializes a bundle at `app-dir`.  Default
;; runs osacompile + plist tools (macOS only); tests parameterize it.
(define current-build-bundle! (make-parameter real-build-bundle!))

;; Write (or refresh) a wrapper bundle at <apps-dir>/<display>.app that execs
;; `shim-path`.  Refuses to touch a bundle that is not rackup-managed.
;; Returns the bundle path on success, #f if skipped.
(define (write-mac-app! apps-dir display launcher shim-path
                        #:icon-src [icon-src #f] #:src-app [src-app #f])
  (define app-dir (app-bundle-dir apps-dir display))
  (cond
    [(and (path-exists? app-dir) (not (rackup-managed-app? app-dir)))
     (eprintf "rackup: ~a exists and is not managed by rackup; leaving it alone\n"
              (path->string app-dir))
     #f]
    [else
     ;; Build fresh so osacompile never merges into a stale bundle.  The
     ;; builder writes the managed marker (so it is sealed into the signed
     ;; bundle) and re-signs.
     (delete-directory/files app-dir #:must-exist? #f)
     ((current-build-bundle!) app-dir display launcher shim-path icon-src src-app)
     app-dir]))

;; ---- regenerate / remove --------------------------------------------

;; `*.app` bundles under `apps-dir` that carry our marker.
(define (managed-app-dirs apps-dir)
  (if (directory-exists? apps-dir)
      (filter (lambda (p) (and (app-bundle? p) (rackup-managed-app? p)))
              (directory-list apps-dir #:build? #t))
      '()))

;; (Re)generate wrapper bundles to match current state: one per GUI app the
;; default toolchain ships (whose launcher has a shim), when the `mac-apps`
;; flag is set; otherwise remove ours.  Stale managed wrappers (apps no
;; longer shipped, or after the flag/default changes) are pruned.  No-op off
;; macOS.
(define (regenerate-mac-apps!)
  (when (current-mac-apps-os?)
    (define apps-dir (current-user-applications-dir))
    (define default-id (get-default-toolchain))
    (cond
      [(and (mac-apps-enabled?) default-id)
       (make-directory* apps-dir)
       (define shims-dir (rackup-shims-dir))
       (define apps (find-gui-apps (rackup-toolchain-install-dir default-id) shims-dir))
       (for ([a (in-list apps)])
         (write-mac-app! apps-dir (gui-app-display a) (gui-app-launcher a)
                         (path->string (build-path shims-dir (gui-app-launcher a)))
                         #:icon-src (gui-app-icon a)
                         #:src-app (gui-app-src a)))
       (define desired
         (list->set (for/list ([a (in-list apps)])
                      (string-append (gui-app-display a) ".app"))))
       (for ([p (in-list (managed-app-dirs apps-dir))]
             #:unless (set-member? desired (path-basename-string p)))
         (delete-directory/files p #:must-exist? #f))]
      [else (remove-mac-apps!)])))

;; Remove every wrapper bundle we manage.  No-op off macOS.
(define (remove-mac-apps!)
  (when (current-mac-apps-os?)
    (for ([p (in-list (managed-app-dirs (current-user-applications-dir)))])
      (delete-directory/files p #:must-exist? #f))))
