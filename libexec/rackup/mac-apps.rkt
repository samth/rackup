#lang racket/base

;; macOS `.app` wrappers for GUI tools (issue #10).
;;
;; rackup-managed GUI tools (DrRacket) live deep under `~/.rackup` and are
;; launched from the command line via shims, so they are invisible to Finder,
;; Spotlight, and the Dock.  When the `mac-apps` config flag is set (via
;; `rackup install --mac-apps` / `rackup reshim --mac-apps`), rackup writes
;; small wrapper bundles into `~/Applications` so the GUI tools can be opened
;; like any other macOS app.
;;
;; Each wrapper's `Contents/MacOS/<Name>` is a shell script that execs the
;; corresponding rackup shim (e.g. `~/.rackup/shims/drracket`).  Routing
;; through the shim means the app always launches the *default* toolchain's
;; tool, with the toolchain's environment set up, and — crucially — through
;; the shim's `cd -P` bin-symlink resolution (issue #37), which a GUI Racket
;; binary requires on aarch64 macOS to avoid an `invalid memory reference`
;; crash in `cocoa/queue.rkt`.  A wrapper that pointed at a symlinked path
;; directly would reintroduce that crash.
;;
;; Wrappers carry a marker file (`Contents/Resources/.rackup-managed`) so we
;; only ever overwrite or delete bundles we created — a user's own
;; `~/Applications/DrRacket.app` is left untouched.

(require racket/file
         racket/path
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
  (provide gui-apps
           current-mac-apps-os?
           current-user-applications-dir
           write-mac-app!
           rackup-managed-app?
           info-plist))

;; (launcher-name . display-name): the shim to exec and the `.app` name.
(define gui-apps '(("drracket" . "DrRacket")))

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

;; Best-effort: find a `.icns` icon for `display` inside the default
;; toolchain's install tree.  The macOS DMG layout places `DrRacket.app` at
;; the install root; we also check `lib/`.  Returns a path or #f.
(define (find-app-icon display)
  (define default-id (get-default-toolchain))
  (and default-id
       (let ([install (rackup-toolchain-install-dir default-id)])
         (for/or ([rel (in-list (list (build-path (string-append display ".app")
                                                  "Contents" "Resources")
                                      (build-path "lib" (string-append display ".app")
                                                  "Contents" "Resources")))])
           (define dir (build-path install rel))
           (and (directory-exists? dir)
                (for/or ([p (in-list (directory-list dir #:build? #t))]
                         #:when (equal? (path-get-extension p) #".icns"))
                  p))))))

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

(define (delete-managed-app! app-dir)
  (when (and (directory-exists? app-dir) (rackup-managed-app? app-dir))
    (delete-directory/files app-dir #:must-exist? #f)))

;; (Re)generate the wrapper bundles to match current state: one per GUI tool
;; whose shim exists, when the `mac-apps` flag is set; otherwise remove ours.
;; No-op off macOS.
(define (regenerate-mac-apps!)
  (when (current-mac-apps-os?)
    (cond
      [(mac-apps-enabled?)
       (define apps-dir (current-user-applications-dir))
       (make-directory* apps-dir)
       (define shims-dir (rackup-shims-dir))
       (for ([entry (in-list gui-apps)])
         (define launcher (car entry))
         (define display (cdr entry))
         (define shim (build-path shims-dir launcher))
         (cond
           [(file-exists? shim)
            (write-mac-app! apps-dir display launcher (path->string shim)
                            #:icon-src (find-app-icon display))]
           ;; Shim gone (e.g. minimal distribution): drop our stale wrapper.
           [else (delete-managed-app! (app-bundle-dir apps-dir display))]))]
      [else (remove-mac-apps!)])))

;; Remove every wrapper bundle we manage.  No-op off macOS.
(define (remove-mac-apps!)
  (when (current-mac-apps-os?)
    (define apps-dir (current-user-applications-dir))
    (when (directory-exists? apps-dir)
      (for ([entry (in-list gui-apps)])
        (delete-managed-app! (app-bundle-dir apps-dir (cdr entry)))))))
