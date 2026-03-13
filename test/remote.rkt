#lang at-exp racket/base

(require rackunit
         racket/format
         racket/file
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         file/sha1
         "../libexec/rackup/install.rkt"
         "../libexec/rackup/legacy-plt-catalog.rkt"
         "../libexec/rackup/remote.rkt"
         "../libexec/rackup/runtime.rkt"
         (submod "../libexec/rackup/remote.rkt" for-testing)
         (rename-in (submod "../libexec/rackup/install.rkt" for-testing)
                    [ensure-installer-cached! install-ensure-installer-cached!])
         (rename-in (submod "../libexec/rackup/runtime.rkt" for-testing)
                    [ensure-installer-cached! runtime-ensure-installer-cached!]))

(module+ test
  (define-runtime-path repo-root "..")
  (define libexec-dir (build-path repo-root "libexec" "rackup"))

  (define rackup-sources
    (sort
     (for/list ([p (in-list (directory-list libexec-dir #:build? #t))]
                #:when (regexp-match? #px"[.]rkt$" (path->string p)))
       p)
     string<?
     #:key path->string))

  (for ([src (in-list rackup-sources)])
    (define content (file->string src))
    (check-false (regexp-match? #px"^#lang +at-exp(?: |$)" content)
                 (format "~a should not use #lang at-exp in client-installed code"
                         (path->string src)))
    (check-false (regexp-match? #px"\\bcurl\\b" (string-downcase content))
                 (format "~a should not shell out to curl" (path->string src)))
    (check-false (regexp-match? #px"\\bwget\\b" (string-downcase content))
                 (format "~a should not shell out to wget" (path->string src))))


  (define tmp-root (string->path "/tmp"))

  (define (sha256-hex-string s)
    (bytes->hex-string (sha256-bytes (open-input-string s))))

  (define (with-temp-rackup-home proc)
    (define tmp-home (make-temporary-file "rackup-remote-home-~a" 'directory tmp-root))
    (define env (environment-variables-copy (current-environment-variables)))
    (environment-variables-set! env #"RACKUP_HOME" (string->bytes/utf-8 (path->string tmp-home)))
    (dynamic-wind
     void
     (lambda ()
       (parameterize ([current-environment-variables env])
         (proc tmp-home)))
     (lambda ()
       (delete-directory/files tmp-home #:must-exist? #f))))

  (define p1 (parse-installer-filename "racket-8.18-x86_64-linux-cs.sh"))
  (check-equal? (hash-ref p1 'distribution) 'full)
  (check-equal? (hash-ref p1 'variant) 'cs)
  (check-equal? (hash-ref p1 'arch) "x86_64")
  (check-equal? (hash-ref p1 'platform) "linux")
  (check-equal? (hash-ref p1 'platform-family) "linux")
  (check-equal? (hash-ref p1 'ext) "sh")

  (define p1b (parse-installer-filename "racket-9.1-x86_64-linux-buster-cs.sh"))
  (check-equal? (hash-ref p1b 'platform) "linux-buster")
  (check-equal? (hash-ref p1b 'platform-family) "linux")

  (define p1c (parse-installer-filename "racket-9.1-arm64-linux-cs.sh"))
  (check-equal? (hash-ref p1c 'arch-token) "arm64")
  (check-equal? (hash-ref p1c 'arch) "aarch64")
  (check-equal? (hash-ref p1c 'platform) "linux")

  (define p1d (parse-installer-filename "racket-9.1-aarch64-macosx-cs.sh"))
  (check-equal? (hash-ref p1d 'arch) "aarch64")
  (check-equal? (hash-ref p1d 'platform) "macosx")
  (check-equal? (hash-ref p1d 'platform-family) "macosx")

  (define p2 (parse-installer-filename "racket-minimal-7.9-x86_64-linux.sh"))
  (check-equal? (hash-ref p2 'distribution) 'minimal)
  (check-equal? (hash-ref p2 'variant) 'bc)
  (check-equal? (hash-ref p2 'version-token) "7.9")

  (define p-legacy
    (parse-legacy-installer-filename "racket-textual-5.2-bin-x86_64-linux-debian-squeeze.sh"))
  (check-equal? (hash-ref p-legacy 'distribution) 'minimal)
  (check-equal? (hash-ref p-legacy 'variant) 'bc)
  (check-equal? (hash-ref p-legacy 'version-token) "5.2")
  (check-equal? (hash-ref p-legacy 'arch) "x86_64")
  (check-equal? (hash-ref p-legacy 'platform-family) "linux")

  (define fake-table
    (hash 'a
          "racket-8.18-x86_64-linux-cs.sh"
          'b
          "racket-minimal-8.18-x86_64-linux-cs.sh"
          'c
          "racket-8.18-x86_64-linux-bc.sh"
          'd
          "racket-current-x86_64-linux-cs.sh"
          'e
          "racket-minimal-current-x86_64-linux-cs.sh"))

  (check-equal? (select-installer-filename fake-table
                                           #:version-token "8.18"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64")
                "racket-8.18-x86_64-linux-cs.sh")

  (define fake-table-precise (hash 'a "racket-9.1.0.7-x86_64-linux-cs.sh"))
  (check-equal? (select-installer-filename fake-table-precise
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64"
                                           #:allow-version-prefix? #t)
                "racket-9.1.0.7-x86_64-linux-cs.sh")

  (define fake-table-linux-flavors
    (hash 'a "racket-9.1-x86_64-linux-buster-cs.sh" 'b "racket-9.1-x86_64-linux-natipkg-cs.sh"))
  (check-equal? (select-installer-filename fake-table-linux-flavors
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64"
                                           #:allow-version-prefix? #t)
                "racket-9.1-x86_64-linux-buster-cs.sh")

  (define fake-table-linux-flavors-2
    (hash 'a
          "racket-9.1-x86_64-linux-cs.sh"
          'b
          "racket-9.1-x86_64-linux-natipkg-cs.sh"
          'c
          "racket-9.1-x86_64-linux-pkg-build-cs.sh"))
  (check-equal? (select-installer-filename fake-table-linux-flavors-2
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64")
                "racket-9.1-x86_64-linux-cs.sh")

  (check-exn exn:fail?
             (lambda ()
               (select-installer-filename (hash 'a "racket-9.1-x86_64-linux-natipkg-cs.sh")
                                          #:version-token "9.1"
                                          #:variant 'cs
                                          #:distribution 'full
                                          #:arch "x86_64")))

  (define fake-table-platforms
    (hash 'a "racket-9.1-x86_64-linux-cs.sh" 'b "racket-9.1-x86_64-win32-cs.sh"))
  (check-equal? (select-installer-filename fake-table-platforms
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64"
                                           #:platform "win32")
                "racket-9.1-x86_64-win32-cs.sh")

  (define fake-table-arm64 (hash 'a "racket-9.1-arm64-linux-cs.sh"))
  (check-equal? (select-installer-filename fake-table-arm64
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "aarch64")
                "racket-9.1-arm64-linux-cs.sh")

  (check-equal? (select-installer-filename fake-table
                                           #:version-token "current"
                                           #:variant 'cs
                                           #:distribution 'minimal
                                           #:arch "x86_64")
                "racket-minimal-current-x86_64-linux-cs.sh")

  (define fake-all-versions-html
    @~a{<html><body>
        <a href="/releases/9.1/">9.1</a>
        <a href="/installers/8.18/">8.18</a>
        <a href="https://download.racket-lang.org/releases/7.9/">7.9</a>
        <a href="/releases/9.1/">9.1</a>
        <a href="/misc/2026/">2026</a>
        </body></html>
        })
  (check-equal? (parse-all-versions-html fake-all-versions-html) '("9.1" "8.18" "7.9"))

  (define fake-all-versions-html-fallback "<a class=\"v\">8.16.0.4</a> <a class=\"v\">8.15</a>")
  (check-equal? (parse-all-versions-html fake-all-versions-html-fallback) '("8.16.0.4" "8.15"))

  (define legacy-index-html
    @~a{<html><body><a href="racket-5.2-bin-x86_64-linux-debian-squeeze.sh">x</a><a
        href="racket-5.2-bin-x86_64-linux-f14.sh">x</a><a href="racket-5.2-src-unix.tgz">src</a><a
        href="racket-5.2-bin-x86_64-linux-debian-squeeze.sh">dup</a></body></html>})
  (check-equal? (parse-legacy-installers-index-html legacy-index-html)
                '("racket-5.2-bin-x86_64-linux-debian-squeeze.sh"
                  "racket-5.2-bin-x86_64-linux-f14.sh"))

  (check-equal?
   (select-legacy-installer-filename (parse-legacy-installers-index-html legacy-index-html)
                                     #:version-token "5.2"
                                     #:distribution 'full
                                     #:arch "x86_64")
   "racket-5.2-bin-x86_64-linux-debian-squeeze.sh")

  (define plt-version-page-html
    @~a{<select><option value="http://download.plt-scheme.org/plt-4-0-bin-x86_64-linux-f7-sh.html">Linux
        x86_64</option><option
        value="http://download.plt-scheme.org/plt-4-0-bin-i386-linux-f9-sh.html">Linux i386</option><option
        value="http://download.plt-scheme.org/plt-4-0-bin-i386-win32-exe.html">Windows</option></select>})
  (check-equal?
   (parse-plt-version-page-html plt-version-page-html)
   '("http://download.plt-scheme.org/plt-4-0-bin-x86_64-linux-f7-sh.html"
     "http://download.plt-scheme.org/plt-4-0-bin-i386-linux-f9-sh.html"
     "http://download.plt-scheme.org/plt-4-0-bin-i386-win32-exe.html"))
  (check-equal?
   (select-plt-generated-page-url (parse-plt-version-page-html plt-version-page-html)
                                  #:version "4.0"
                                  #:arch "x86_64")
   "http://download.plt-scheme.org/plt-4-0-bin-x86_64-linux-f7-sh.html")
  (check-equal?
   (plt-generated-page-url->installer-filename
    "http://download.plt-scheme.org/plt-4-0-bin-x86_64-linux-f7-sh.html"
    "4.0")
   "plt-4.0-bin-x86_64-linux-f7.sh")

  (define plt-version-page-html-352
    @~a{<select><option value="http://download.plt-scheme.org/plt-352-bin-i386-linux-sh.html">Linux
        i386</option><option
        value="http://download.plt-scheme.org/plt-352-bin-i386-linux-ubuntu-sh.html">Linux Ubuntu
        i386</option></select>})
  (check-equal?
   (select-plt-generated-page-url (parse-plt-version-page-html plt-version-page-html-352)
                                  #:version "352"
                                  #:arch "i386")
   "http://download.plt-scheme.org/plt-352-bin-i386-linux-sh.html")
  (check-equal?
   (plt-generated-page-url->installer-filename
    "http://download.plt-scheme.org/plt-352-bin-i386-linux-sh.html"
    "352")
   "plt-352-bin-i386-linux.sh")

  (define plt-version-page-html-209
    "<option value=\"http://download.plt-scheme.org/plt-209-bin-i386-linux-gcc2-sh.html\">Linux i386 old gcc2</option>")
  (check-equal?
   (plt-generated-page-url->installer-filename
    "http://download.plt-scheme.org/plt-209-bin-i386-linux-gcc2-sh.html"
    "209")
   "plt-209-bin-i386-linux-gcc2.sh")

  (define legacy-req-209 (resolve-install-request "209" #:arch "i386" #:platform "linux"))
  (check-equal? (hash-ref legacy-req-209 'installer-url)
                "http://download.plt-scheme.org/bundles/209/plt/plt-209-bin-i386-linux.sh")
  (check-equal? (hash-ref legacy-req-209 'installer-filename)
                "plt-209-bin-i386-linux.sh")
  (check-equal? (hash-ref legacy-req-209 'installer-sha256)
                "f70696da6302a9ca22a3df1fc9c951689f07669643859768489a372c04aef5c9")
  (check-equal? (hash-ref legacy-req-209 'legacy-install-kind) 'shell-basic)

  (define legacy-req-103p1 (resolve-install-request "103p1" #:arch "i386" #:platform "linux"))
  (check-equal? (hash-ref legacy-req-103p1 'installer-url)
                "http://download.plt-scheme.org/bundles/103p1/plt/plt-103p1-bin-i386-linux.tgz")
  (check-equal? (hash-ref legacy-req-103p1 'installer-filename)
                "plt-103p1-bin-i386-linux.tgz")
  (check-equal? (hash-ref legacy-req-103p1 'installer-sha256)
                "7090e2d7df07c17530e50cbc5fde67b51b39f77c162b7f20413242dca923a20a")
  (check-equal? (hash-ref legacy-req-103p1 'legacy-install-kind) 'tgz)

  (define legacy-req-4.2.5 (resolve-install-request "4.2.5" #:arch "x86_64" #:platform "linux"))
  (check-equal? (hash-ref legacy-req-4.2.5 'installer-url)
                "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-x86_64-linux-f7.sh")
  (check-equal? (hash-ref legacy-req-4.2.5 'legacy-install-kind) 'shell-unixstyle)

  ;; macOS DMG installers for legacy PLT Scheme versions
  (define legacy-req-4.2.5-mac (resolve-install-request "4.2.5" #:arch "i386" #:platform "macosx"))
  (check-equal? (hash-ref legacy-req-4.2.5-mac 'installer-url)
                "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-i386-osx-mac.dmg")
  (check-equal? (hash-ref legacy-req-4.2.5-mac 'installer-filename)
                "plt-4.2.5-bin-i386-osx-mac.dmg")
  (check-equal? (hash-ref legacy-req-4.2.5-mac 'legacy-install-kind) 'dmg)
  (check-equal? (hash-ref legacy-req-4.2.5-mac 'platform) "macosx")

  ;; macOS DMGs available for 350+, not for older versions
  (define legacy-req-350-mac (resolve-install-request "350" #:arch "i386" #:platform "macosx"))
  (check-equal? (hash-ref legacy-req-350-mac 'legacy-install-kind) 'dmg)
  (check-exn #px"does not have macOS installers"
             (lambda () (resolve-install-request "209" #:arch "i386" #:platform "macosx")))

  ;; Spot-check a few more macOS entries resolve correctly
  (for ([ver (in-list '("4.0" "4.1" "4.2" "370" "372"))])
    (define req (resolve-install-request ver #:arch "i386" #:platform "macosx"))
    (check-equal? (hash-ref req 'legacy-install-kind) 'dmg
                  (format "~a macOS should use dmg install kind" ver))
    (check-true (regexp-match? #rx"osx-mac\\.dmg$" (hash-ref req 'installer-filename))
                (format "~a macOS filename should end with osx-mac.dmg" ver)))

  (for* ([release-info (in-hash-values legacy-plt-release-info)]
         [artifact (in-list (hash-ref release-info 'artifacts null))]
         #:when (regexp-match? #px"^http://" (hash-ref artifact 'url "")))
    (check-true (string? (hash-ref artifact 'sha256 #f)))
    (check-false (string=? "" (string-trim (hash-ref artifact 'sha256 "")))))

  (let ([in (open-input-string "ignored")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args . _args)
                       (values "NOT HTTP" null in)))])
      (check-exn
       #px"could not parse HTTP status line while fetching http://example.invalid/bad"
       (lambda ()
         (http-get-string "http://example.invalid/bad"))))
    (check-true (port-closed? in)))

  (let ([in (open-input-string "#lang racket/base\n1\n")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args . _args)
                       (values "HTTP/1.1 200 OK" null in)))])
      (check-exn
       #px"failed to read \\.rktd response from http://example.invalid/table.rktd"
       (lambda ()
         (http-get-rktd "http://example.invalid/table.rktd"))))
    (check-true (port-closed? in)))

  (let ([in (open-input-string "payload")]
        [dest-dir (make-temporary-file "rackup-download-dest-~a" 'directory tmp-root)])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args . _args)
                       (values "HTTP/1.1 200 OK" null in)))])
      (check-exn exn:fail?
                 (lambda ()
                   (download-url->file "http://example.invalid/file" dest-dir))))
    (check-true (port-closed? in))
    (delete-directory/files dest-dir))

  (let ([step 0]
        [redirect-in (open-input-string "")]
        [ok-in (open-input-string "redirect-ok")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args host target . _args)
                       (set! step (add1 step))
                       (case step
                         [(1)
                          (check-equal? host "example.invalid")
                          (check-equal? target "/start")
                          (values "HTTP/1.1 302 Found"
                                  (list #"Location: /next")
                                  redirect-in)]
                         [(2)
                          (check-equal? host "example.invalid")
                          (check-equal? target "/next")
                          (values "HTTP/1.1 200 OK" null ok-in)]
                         [else
                          (error 'test "unexpected redirect step ~a" step)])))])
      (check-equal? (http-get-string "https://example.invalid/start") "redirect-ok"))
    (check-true (port-closed? redirect-in))
    (check-true (port-closed? ok-in)))

  (let ([step 0]
        [redirect-in (open-input-string "")]
        [ok-in (open-input-string "legacy-redirect-ok")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args host target . _args)
                       (set! step (add1 step))
                       (case step
                         [(1)
                          (check-equal? host "download.plt-scheme.org")
                          (check-equal? target "/bundles/4.2.5/plt/plt-4.2.5-bin-i386-osx-mac.dmg")
                          (values "HTTP/1.1 302 Found"
                                  (list #"Location: http://www.cs.utah.edu/plt/download/4.2.5/plt-4.2.5-bin-i386-osx-mac.dmg")
                                  redirect-in)]
                         [(2)
                          (check-equal? host "www.cs.utah.edu")
                          (check-equal? target "/plt/download/4.2.5/plt-4.2.5-bin-i386-osx-mac.dmg")
                          (values "HTTP/1.1 200 OK" null ok-in)]
                         [else
                          (error 'test "unexpected legacy redirect step ~a" step)])))])
      (check-equal? (http-get-string
                     "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-i386-osx-mac.dmg")
                    "legacy-redirect-ok"))
    (check-true (port-closed? redirect-in))
    (check-true (port-closed? ok-in)))

  (let ([in (open-input-string "")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args . _args)
                       (values "HTTP/1.1 302 Found"
                               (list #"Location: https://evil.invalid/payload")
                               in)))])
      (check-exn
       #px"refusing cross-origin redirect"
       (lambda ()
         (http-get-string "https://example.invalid/start"))))
    (check-true (port-closed? in)))

  (let ([in (open-input-string "")])
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args . _args)
                       (values "HTTP/1.1 302 Found"
                               (list #"Location: http://example.invalid/downgraded")
                               in)))])
      (check-exn
       #px"refusing cross-origin redirect"
       (lambda ()
         (http-get-string "https://example.invalid/start"))))
    (check-true (port-closed? in)))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn
      #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
      (lambda ()
        (install-ensure-installer-cached! "http://download.plt-scheme.org/example.sh")))))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (check-exn
      #px"refusing to download installer over HTTP without a hardcoded SHA-256 checksum"
      (lambda ()
        (runtime-ensure-installer-cached! "http://download.plt-scheme.org/example.sh")))))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (define payload "verified-installer")
     (define payload-sha256 (sha256-hex-string payload))
     (define download-count 0)
     (define (sendrecv _kws _kw-args . _args)
       (set! download-count (add1 download-count))
       (values "HTTP/1.1 200 OK" null (open-input-string payload)))
     (parameterize ([current-http-sendrecv-proc (make-keyword-procedure sendrecv)])
       (define cache-path
         (install-ensure-installer-cached! "https://example.invalid/toolchain.sh"
                                           #:sha256 payload-sha256))
       (call-with-output-file* cache-path
         #:exists 'truncate/replace
         (lambda (out) (display "tampered" out)))
       (set! download-count 0)
       (define cache-path*
         (install-ensure-installer-cached! "https://example.invalid/toolchain.sh"
                                           #:sha256 payload-sha256))
       (check-equal? cache-path* cache-path)
       (check-equal? download-count 1)
       (check-equal? (file->string cache-path*) payload))))

  (with-temp-rackup-home
   (lambda (_tmp-home)
     (define payload "verified-runtime-installer")
     (define payload-sha256 (sha256-hex-string payload))
     (define download-count 0)
     (define (sendrecv _kws _kw-args . _args)
       (set! download-count (add1 download-count))
       (values "HTTP/1.1 200 OK" null (open-input-string payload)))
     (parameterize ([current-http-sendrecv-proc (make-keyword-procedure sendrecv)])
       (define cache-path
         (runtime-ensure-installer-cached! "https://example.invalid/runtime.sh"
                                           #:sha256 payload-sha256))
       (call-with-output-file* cache-path
         #:exists 'truncate/replace
         (lambda (out) (display "tampered" out)))
       (set! download-count 0)
       (define cache-path*
         (runtime-ensure-installer-cached! "https://example.invalid/runtime.sh"
                                           #:sha256 payload-sha256))
       (check-equal? cache-path* cache-path)
       (check-equal? download-count 1)
       (check-equal? (file->string cache-path*) payload))))

  (check-exn exn:fail?
             (lambda () (resolve-install-request "053" #:arch "i386" #:platform "linux")))
  (check-exn
   #px"PLT Scheme v102|historical release range"
   (lambda () (resolve-install-request "102" #:arch "i386" #:platform "linux")))
  (check-exn exn:fail?
             (lambda () (resolve-install-request "203" #:arch "i386" #:platform "linux")))

  ;; Extension preference: select-installer-filename/by-ext with macOS extensions
  (define fake-table-macos
    (hash 'a "racket-9.1-aarch64-macosx-cs.tgz"
          'b "racket-9.1-aarch64-macosx-cs.dmg"
          'c "racket-minimal-9.1-aarch64-macosx-cs.tgz"
          'd "racket-minimal-9.1-aarch64-macosx-cs.dmg"
          'e "racket-9.1-x86_64-macosx-cs.tgz"
          'f "racket-9.1-x86_64-macosx-cs.dmg"))

  ;; On macOS, tgz is preferred over dmg
  (check-equal? (select-installer-filename fake-table-macos
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "aarch64"
                                           #:platform "macosx"
                                           #:ext "tgz")
                "racket-9.1-aarch64-macosx-cs.tgz")

  ;; dmg fallback works
  (check-equal? (select-installer-filename fake-table-macos
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "aarch64"
                                           #:platform "macosx"
                                           #:ext "dmg")
                "racket-9.1-aarch64-macosx-cs.dmg")

  ;; select-installer-filename/by-ext prefers tgz over dmg for macOS
  (check-equal? (select-installer-filename/by-ext fake-table-macos
                                                   #:version-token "9.1"
                                                   #:variant 'cs
                                                   #:distribution 'full
                                                   #:arch "aarch64"
                                                   #:platform "macosx"
                                                   #:exts '("tgz" "dmg"))
                "racket-9.1-aarch64-macosx-cs.tgz")

  ;; dmg-only table falls back correctly
  (define fake-table-macos-dmg-only
    (hash 'a "racket-9.1-aarch64-macosx-cs.dmg"))
  (check-equal? (select-installer-filename/by-ext fake-table-macos-dmg-only
                                                   #:version-token "9.1"
                                                   #:variant 'cs
                                                   #:distribution 'full
                                                   #:arch "aarch64"
                                                   #:platform "macosx"
                                                   #:exts '("tgz" "dmg"))
                "racket-9.1-aarch64-macosx-cs.dmg")

  ;; macOS platform should not select Linux sh installers
  (define fake-table-cross-platform
    (hash 'a "racket-9.1-x86_64-linux-cs.sh"
          'b "racket-9.1-x86_64-macosx-cs.tgz"))
  (check-exn exn:fail?
             (lambda ()
               (select-installer-filename fake-table-cross-platform
                                          #:version-token "9.1"
                                          #:variant 'cs
                                          #:distribution 'full
                                          #:arch "x86_64"
                                          #:platform "macosx"
                                          #:ext "sh")))

  ;; Linux platform should not select macOS dmg installers
  (check-exn exn:fail?
             (lambda ()
               (select-installer-filename fake-table-cross-platform
                                          #:version-token "9.1"
                                          #:variant 'cs
                                          #:distribution 'full
                                          #:arch "x86_64"
                                          #:platform "linux"
                                          #:ext "dmg")))

  ;; Parsing macOS dmg filenames
  (define p-macos-dmg (parse-installer-filename "racket-9.1-aarch64-macosx-cs.dmg"))
  (check-equal? (hash-ref p-macos-dmg 'arch) "aarch64")
  (check-equal? (hash-ref p-macos-dmg 'platform) "macosx")
  (check-equal? (hash-ref p-macos-dmg 'platform-family) "macosx")
  (check-equal? (hash-ref p-macos-dmg 'variant) 'cs)
  (check-equal? (hash-ref p-macos-dmg 'ext) "dmg")
  (check-equal? (hash-ref p-macos-dmg 'distribution) 'full)

  ;; Distribution fallback: when only minimal installers exist for an arch,
  ;; requesting full should fall back to minimal.
  (define minimal-only-table
    (hash 'a "racket-minimal-9.1-riscv64-linux-cs.sh"
          'b "racket-minimal-9.1-riscv64-linux-cs.tgz"
          'c "racket-9.1-x86_64-linux-cs.sh"
          'd "racket-minimal-9.1-x86_64-linux-cs.sh"
          'e "racket-9.1-aarch64-linux-cs.sh"
          'f "racket-9.1-i386-linux-cs.sh"
          'g "racket-9.1-arm-linux-cs.sh"))

  ;; riscv64 has no full installer -- select-installer-filename should fail
  (check-exn exn:fail?
             (lambda ()
               (select-installer-filename minimal-only-table
                                          #:version-token "9.1"
                                          #:variant 'cs
                                          #:distribution 'full
                                          #:arch "riscv64")))

  ;; But minimal works fine for riscv64
  (check-equal? (select-installer-filename minimal-only-table
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'minimal
                                           #:arch "riscv64")
                "racket-minimal-9.1-riscv64-linux-cs.sh")

  ;; x86_64 has full installer -- should still work
  (check-equal? (select-installer-filename minimal-only-table
                                           #:version-token "9.1"
                                           #:variant 'cs
                                           #:distribution 'full
                                           #:arch "x86_64")
                "racket-9.1-x86_64-linux-cs.sh")

  ;; distribution-fallback? predicate
  (check-true (distribution-fallback? 'minimal 'full))
  (check-false (distribution-fallback? 'full 'full))
  (check-false (distribution-fallback? 'minimal 'minimal))
  (check-false (distribution-fallback? 'full 'minimal))

  (define (with-fake-release-metadata proc)
    (parameterize ([current-http-sendrecv-proc
                    (make-keyword-procedure
                     (lambda (_kws _kw-args host target . _args)
                       (cond
                         [(and (equal? host "download.racket-lang.org")
                               (equal? target "/version.txt"))
                          (values "HTTP/1.1 200 OK"
                                  null
                                  (open-input-string "(stable \"9.1\")\n"))]
                         [(and (equal? host "download.racket-lang.org")
                               (equal? target "/installers/9.1/table.rktd"))
                          (values "HTTP/1.1 200 OK"
                                  null
                                  (open-input-string (format "~s" minimal-only-table)))]
                         [else
                          (error 'test "unexpected remote fetch: host=~a target=~a" host target)])))])
      (proc)))

  (with-fake-release-metadata
   (lambda ()
     ;; End-to-end: riscv64 is minimal-only -- requesting full falls back to minimal.
     (define riscv-req
       (resolve-install-request "9.1" #:distribution 'full #:arch "riscv64" #:platform "linux"))
     (check-equal? (hash-ref riscv-req 'distribution) 'minimal)
     (check-equal? (hash-ref riscv-req 'arch) "riscv64")
     (check-true (regexp-match? #rx"minimal" (hash-ref riscv-req 'installer-filename)))

     ;; Architectures that have full Linux installers in 9.1 should NOT fall back.
     (for ([arch (in-list '("x86_64" "aarch64" "i386" "arm"))])
       (define req
         (resolve-install-request "9.1" #:distribution 'full #:arch arch #:platform "linux"))
       (check-equal? (hash-ref req 'distribution) 'full
                     (format "~a: full installer should be found" arch))
       (check-equal? (hash-ref req 'arch) arch)
       (check-false (regexp-match? #rx"minimal" (hash-ref req 'installer-filename))
                    (format "~a: should not fall back to minimal" arch)))

     ;; Explicitly requesting minimal on riscv64 works directly (no fallback needed).
     (define riscv-minimal-req
       (resolve-install-request "9.1" #:distribution 'minimal #:arch "riscv64" #:platform "linux"))
     (check-equal? (hash-ref riscv-minimal-req 'distribution) 'minimal)
     (check-true (regexp-match? #rx"minimal" (hash-ref riscv-minimal-req 'installer-filename)))

     ;; Stable resolves for riscv64 with full -> minimal fallback.
     (define riscv-stable-req
       (resolve-install-request "stable" #:distribution 'full #:arch "riscv64" #:platform "linux"))
     (check-equal? (hash-ref riscv-stable-req 'distribution) 'minimal)
     (check-equal? (hash-ref riscv-stable-req 'arch) "riscv64"))))
