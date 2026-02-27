#lang at-exp racket/base

(require rackunit
         racket/format
         racket/file
         racket/path
         racket/runtime-path
         racket/string
         "../libexec/rackup/remote.rkt")

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

  (define resolve-install-request/runtime
    (dynamic-require '(file "../libexec/rackup/remote.rkt") 'resolve-install-request))

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

  (define legacy-req-209 (resolve-install-request/runtime "209" #:arch "i386"))
  (check-equal? (hash-ref legacy-req-209 'installer-url)
                "http://download.plt-scheme.org/bundles/209/plt/plt-209-bin-i386-linux.sh")
  (check-equal? (hash-ref legacy-req-209 'installer-filename)
                "plt-209-bin-i386-linux.sh")
  (check-equal? (hash-ref legacy-req-209 'installer-sha256)
                "f70696da6302a9ca22a3df1fc9c951689f07669643859768489a372c04aef5c9")
  (check-equal? (hash-ref legacy-req-209 'legacy-install-kind) 'shell-basic)

  (define legacy-req-103p1 (resolve-install-request/runtime "103p1" #:arch "i386"))
  (check-equal? (hash-ref legacy-req-103p1 'installer-url)
                "http://download.plt-scheme.org/bundles/103p1/plt/plt-103p1-bin-i386-linux.tgz")
  (check-equal? (hash-ref legacy-req-103p1 'installer-filename)
                "plt-103p1-bin-i386-linux.tgz")
  (check-equal? (hash-ref legacy-req-103p1 'installer-sha256)
                "7090e2d7df07c17530e50cbc5fde67b51b39f77c162b7f20413242dca923a20a")
  (check-equal? (hash-ref legacy-req-103p1 'legacy-install-kind) 'tgz)

  (define legacy-req-4.2.5 (resolve-install-request/runtime "4.2.5" #:arch "x86_64"))
  (check-equal? (hash-ref legacy-req-4.2.5 'installer-url)
                "http://download.plt-scheme.org/bundles/4.2.5/plt/plt-4.2.5-bin-x86_64-linux-f7.sh")
  (check-equal? (hash-ref legacy-req-4.2.5 'legacy-install-kind) 'shell-unixstyle)

  (check-exn exn:fail?
             (lambda () (resolve-install-request/runtime "053" #:arch "i386")))
  (check-exn exn:fail?
             (lambda () (resolve-install-request/runtime "203" #:arch "i386"))))
