#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/runtime-path
         racket/system)

(define-runtime-path here ".")

(define root-dir
  (simplify-path (build-path here "..")))

(define copy-script
  (build-path root-dir "scripts" "copy-filtered-tree.sh"))

(define (write-executable path text)
  (make-parent-directory* path)
  (call-with-output-file path
    (lambda (out) (display text out))
    #:exists 'truncate/replace)
  (file-or-directory-permissions path #o755))

(define (with-temp-dirs proc)
  (define src (make-temporary-file "rackup-copy-src~a" 'directory))
  (define dst (make-temporary-file "rackup-copy-dst~a" 'directory))
  (dynamic-wind
   void
   (lambda () (proc src dst))
   (lambda ()
     (delete-directory/files src #:must-exist? #f)
     (delete-directory/files dst #:must-exist? #f))))

(define (run-copy src dst . paths)
  (define rc
    (apply system* copy-script
           (path->string src)
           (path->string dst)
           (map path->string paths)))
  (check-true rc))

(module+ test
  (with-temp-dirs
   (lambda (src dst)
     (write-executable (build-path src "bin" "rackup") "#!/bin/sh\nexit 0\n")
     (write-executable (build-path src "libexec" "rackup-core.rkt") "#lang racket/base\n")
     (write-executable (build-path src "scripts" "helper.sh") "#!/bin/sh\nexit 0\n")
     (call-with-output-file (build-path src "README.md")
       (lambda (out) (display "rackup\n" out)))
     (make-directory* (build-path src "libexec" "compiled"))
     (call-with-output-file (build-path src "libexec" "compiled" "rackup-core_rkt.zo") void)
     (make-directory* (build-path src "test" "compiled"))
     (call-with-output-file (build-path src "test" "compiled" "state-shims_rkt.dep") void)
     (make-directory* (build-path src ".ci-cache" "native-i386-vm"))
     (call-with-output-file (build-path src ".ci-cache" "native-i386-vm" "disk.img")
       (lambda (out) (display "big-cache\n" out)))
     (make-directory* (build-path src ".claude" "worktrees"))
     (call-with-output-file (build-path src ".claude" "settings.local.json")
       (lambda (out) (display "{}\n" out)))
     (make-directory* (build-path src ".tmp-test-clean" "nested"))
     (call-with-output-file (build-path src ".tmp-test-clean" "nested" "copied-again.txt")
       (lambda (out) (display "recursive\n" out)))
     (make-directory* (build-path src "_site"))
     (call-with-output-file (build-path src "_site" "install.sh")
       (lambda (out) (display "#!/bin/sh\n" out)))
     (call-with-output-file (build-path src "bin" "extra.dep") void)
     (call-with-output-file (build-path src "libexec" "leftover.zo") void)
     (call-with-output-file (build-path src "PROBLEMS~") void)
     (call-with-output-file (build-path src ".#IMPL_NOTES.md") void)
     (call-with-output-file (build-path src "#IMPL_NOTES.md#") void)

     (run-copy src dst)

     (check-true (file-exists? (build-path dst "bin" "rackup")))
     (check-true (file-exists? (build-path dst "libexec" "rackup-core.rkt")))
     (check-true (file-exists? (build-path dst "scripts" "helper.sh")))
     (check-true (file-exists? (build-path dst "README.md")))
     (check-false (directory-exists? (build-path dst "libexec" "compiled")))
     (check-false (directory-exists? (build-path dst "test" "compiled")))
     (check-false (directory-exists? (build-path dst ".ci-cache")))
     (check-false (directory-exists? (build-path dst ".claude")))
     (check-false (directory-exists? (build-path dst ".tmp-test-clean")))
     (check-false (directory-exists? (build-path dst "_site")))
     (check-false (file-exists? (build-path dst "bin" "extra.dep")))
     (check-false (file-exists? (build-path dst "libexec" "leftover.zo")))
     (check-false (file-exists? (build-path dst "PROBLEMS~")))
     (check-false (file-exists? (build-path dst ".#IMPL_NOTES.md")))
     (check-false (file-exists? (build-path dst "#IMPL_NOTES.md#")))))

  (with-temp-dirs
   (lambda (src dst)
     (write-executable (build-path src "bin" "rackup") "#!/bin/sh\nexit 0\n")
     (write-executable (build-path src "libexec" "rackup-core.rkt") "#lang racket/base\n")
     (write-executable (build-path src "pages" "site.rkt") "#lang racket/base\n")
     (make-directory* (build-path src "libexec" "compiled"))
     (call-with-output-file (build-path src "libexec" "compiled" "rackup-core_rkt.zo") void)

     (run-copy src dst (string->path "bin") (string->path "libexec"))

     (check-true (file-exists? (build-path dst "bin" "rackup")))
     (check-true (file-exists? (build-path dst "libexec" "rackup-core.rkt")))
     (check-false (file-exists? (build-path dst "pages" "site.rkt")))
     (check-false (directory-exists? (build-path dst "libexec" "compiled"))))))
