#lang racket/base

;; Guards the "rackup for agents" guide (libexec/rackup/agents-guide.rkt)
;; against drift: every command the guide teaches must still be a real
;; subcommand, and must actually appear in the guide text.

(require rackunit
         racket/list
         racket/string
         "../libexec/rackup/agents-guide.rkt"
         "../libexec/rackup/commands-data.rkt")

(define (contains? haystack needle)
  (regexp-match? (regexp-quote needle) haystack))

(define (in-list? x xs)
  (and (member x xs) #t))

(module+ test
  (define command-names (map car rackup-commands))

  ;; The guide and snippet are non-empty strings.
  (check-true (string? agent-guide-text))
  (check-true (> (string-length agent-guide-text) 0))
  (check-true (string? agent-snippet-text))
  (check-true (> (string-length agent-snippet-text) 0))

  ;; The `agents` command itself is registered (so `rackup agents` and
  ;; `rackup help agents` dispatch).
  (check-true (in-list? "agents" command-names) "commands-data.rkt is missing the `agents` subcommand")

  ;; Drift guard: every referenced command is a real subcommand and is
  ;; actually mentioned in the guide as `rackup <cmd>`.
  (check-true (pair? agent-guide-referenced-commands))
  (for ([cmd (in-list agent-guide-referenced-commands)])
    (check-true (in-list? cmd command-names) (format "guide references unknown command: ~a" cmd))
    (check-true (contains? agent-guide-text (string-append "rackup " cmd))
                (format "guide does not mention `rackup ~a`" cmd)))

  ;; No duplicate entries in the referenced-commands list.
  (check-equal? (length agent-guide-referenced-commands)
                (length (remove-duplicates agent-guide-referenced-commands))
                "duplicate entries in agent-guide-referenced-commands")

  ;; The core guidance is present: prefer `rackup run`, avoid `rackup switch`
  ;; in scripts.
  (check-true (contains? agent-guide-text "rackup run") "guide should recommend `rackup run`")
  (check-true (contains? agent-guide-text "rackup switch") "guide should warn about `rackup switch`")

  ;; The snippet points back at the full guide.
  (check-true (contains? agent-snippet-text "rackup help agents")
              "snippet should point at `rackup help agents`"))
