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
;; Each wrapper's `Contents/MacOS/<Name>` is a shell script that execs the
;; matching rackup shim (e.g. `~/.rackup/shims/drracket`).  Routing through
;; the shim means the app always launches the *default* toolchain's tool,
;; with the toolchain's environment set up, and — crucially — through the
;; shim's `cd -P` bin-symlink resolution (issue #37), which a GUI Racket
;; binary requires on aarch64 macOS to avoid an `invalid memory reference`
;; crash in `cocoa/queue.rkt`.  A wrapper that pointed at a symlinked path
;; directly would reintroduce that crash.
;;
;; Wrappers carry a marker file (`Contents/Resources/.rackup-managed`) so we
;; only ever overwrite or delete bundles we created — a user's own
;; `~/Applications/DrRacket.app` is left untouched.

(require racket/file
         racket/list
         racket/path
         racket/set
         racket/string
         "error.rkt"
         "paths.rkt"
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
           find-gui-apps
           resolve-launcher
           managed-app-dirs
           write-mac-app!
           rackup-managed-app?
           info-plist))

(struct gui-app (display launcher icon) #:transparent)

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

(define (find-icns app-path)
  (define res (build-path app-path "Contents" "Resources"))
  (and (directory-exists? res)
       (for/or ([p (in-list (directory-list res #:build? #t))]
                #:when (equal? (path-get-extension p) #".icns"))
         p)))

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
                 (cons (gui-app display launcher (find-icns app)) acc)))])))

;; ---- bundle writing -------------------------------------------------

(define (app-bundle-dir apps-dir display)
  (build-path apps-dir (string-append display ".app")))

(define (rackup-managed-app? app-dir)
  (file-exists? (build-path app-dir "Contents" "Resources" managed-marker)))

(define (xml-escape s)
  (regexp-replace* #rx"<" (regexp-replace* #rx"&" s "\\&amp;") "\\&lt;"))

(define (plist-string key value)
  (format "  <key>~a</key>\n  <string>~a</string>\n"
          (xml-escape key) (xml-escape value)))

(define (info-plist display launcher icon?)
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
   "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\""
   " \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
   "<plist version=\"1.0\">\n<dict>\n"
   (plist-string "CFBundleName" display)
   (plist-string "CFBundleDisplayName" display)
   (plist-string "CFBundleExecutable" display)
   (plist-string "CFBundleIdentifier" (string-append "org.racket-lang.rackup." launcher))
   (plist-string "CFBundlePackageType" "APPL")
   (plist-string "CFBundleInfoDictionaryVersion" "6.0")
   (plist-string "CFBundleShortVersionString" "1.0")
   (plist-string "CFBundleVersion" "1.0")
   (if icon? (plist-string "CFBundleIconFile" display) "")
   "  <key>NSHighResolutionCapable</key>\n  <true/>\n"
   "</dict>\n</plist>\n"))

(define (launcher-script shim-path)
  (string-append "#!/bin/sh\n"
                 "exec " (sh-single-quote shim-path) " \"$@\"\n"))

;; Write (or refresh) a wrapper bundle at <apps-dir>/<display>.app that execs
;; `shim-path`.  Refuses to touch a bundle that is not rackup-managed.
;; Returns the bundle path on success, #f if skipped.
(define (write-mac-app! apps-dir display launcher shim-path #:icon-src [icon-src #f])
  (define app-dir (app-bundle-dir apps-dir display))
  (cond
    [(and (path-exists? app-dir) (not (rackup-managed-app? app-dir)))
     (eprintf "rackup: ~a exists and is not managed by rackup; leaving it alone\n"
              (path->string app-dir))
     #f]
    [else
     (define contents (build-path app-dir "Contents"))
     (define macos (build-path contents "MacOS"))
     (define resources (build-path contents "Resources"))
     (make-directory* macos)
     (make-directory* resources)
     (define icon?
       (and icon-src (file-exists? icon-src)
            (begin (copy-file icon-src
                              (build-path resources (string-append display ".icns"))
                              #t)
                   #t)))
     (write-string-file (build-path contents "Info.plist")
                        (info-plist display launcher icon?))
     (write-string-file (build-path contents "PkgInfo") "APPL????")
     (define exe (build-path macos display))
     (write-string-file exe (launcher-script shim-path))
     (file-or-directory-permissions exe #o755)
     (write-string-file (build-path resources managed-marker)
                        (string-append "rackup-managed:" launcher))
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
                         #:icon-src (gui-app-icon a)))
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
