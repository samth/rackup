#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/port
         racket/string
         "../libexec/rackup/rktd-io.rkt")

(define tmp-root (string->path "/tmp"))

(define (make-temp-file-in-tmp pattern)
  (make-temporary-file pattern #f tmp-root))

(module+ test
  (check-equal? (read-rktd/port (open-input-string "#hash((a . 1) (b . 2))"))
                '#hash((a . 1) (b . 2)))
  (check-equal? (read-rktd/port (open-input-string "(1 2 3)")) '(1 2 3))

  (for ([payload (in-list (list "#lang racket/base\n1\n" "#reader racket/base 1\n"))])
    (check-exn exn:fail? (lambda () (read-rktd/port (open-input-string payload)))))

  (define compiled-payload
    (with-output-to-string
      (lambda ()
        (write (compile '(+ 1 2))))))
  (check-exn exn:fail? (lambda () (read-rktd/port (open-input-string compiled-payload))))

  (define good-rktd (make-temp-file-in-tmp "rackup-rktd-good-~a"))
  (write-rktd-file good-rktd '#hash((id . "ok")))
  (check-equal? (read-rktd-file good-rktd) '#hash((id . "ok")))
  (delete-file good-rktd)

  (define bad-rktd (make-temp-file-in-tmp "rackup-rktd-bad-~a"))
  (call-with-output-file* bad-rktd
    #:exists 'truncate/replace
    (lambda (out)
      (display "#lang racket/base\n1\n" out)))
  (check-exn
   (regexp (regexp-quote (format "failed to read .rktd file ~a" bad-rktd)))
   (lambda ()
     (read-rktd-file bad-rktd)))
  (delete-file bad-rktd)

  (define text-file (make-temp-file-in-tmp "rackup-string-~a"))
  (write-string-file text-file "hello")
  (check-equal? (file->string text-file) "hello\n")
  (delete-file text-file)

  (define exec-file (make-temp-file-in-tmp "rackup-perms-~a"))
  (call-with-output-file* exec-file
    #:exists 'truncate/replace
    (lambda (out)
      (display "old\n" out)))
  (file-or-directory-permissions exec-file #o751)
  (write-string-file exec-file "new")
  (check-equal? (file->string exec-file) "new\n")
  (check-equal? (file-or-directory-permissions exec-file 'bits) #o751)
  (delete-file exec-file))
