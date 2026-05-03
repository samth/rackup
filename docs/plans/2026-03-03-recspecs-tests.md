# Plan: Use new recspecs features in rackup tests

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Context

The `recspecs` package has been updated with new features: `capture-output`, `capture-output/split`, `#:match 'contains`/`'regexp` modes, `#:port 'stderr`/`'both`, and `#:status`/`#:env` on `expect/shell`. The rackup test file has many manual output-capture patterns and `string-contains?` checks that can be simplified using these features.

## Changes

### `test/state-shims.rkt`

#### 1. Use `capture-output/split` for `run-main/capture`

```racket
;; Before:
(define (run-main/capture args)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([current-command-line-arguments (list->vector args)]
                 [current-output-port out]
                 [current-error-port err])
    (main))
  (values (get-output-string out) (get-output-string err)))

;; After:
(define (run-main/capture args)
  (capture-output/split
    (lambda ()
      (parameterize ([current-command-line-arguments (list->vector args)])
        (main)))))
```

#### 2. Use `capture-output` for `run-main/stdout`

```racket
;; Before:
(define (run-main/stdout args)
  (define-values (out _err) (run-main/capture args))
  out)

;; After:
(define (run-main/stdout args)
  (capture-output
    (lambda ()
      (parameterize ([current-command-line-arguments (list->vector args)])
        (main)))))
```

#### 3. Replace inline capture patterns with `capture-output`

Six instances of manual `parameterize`/`open-output-string` capture boilerplate for Racket functions and subprocess calls. Each follows one of two patterns:

**Pattern A** (with `system*` check) — lines ~541, ~561, ~567, ~650:
```racket
;; Before:
(define shim-out
  (parameterize ([current-output-port (open-output-string)]
                 [current-error-port (open-output-string)])
    (define out (current-output-port))
    (check-true (system* exe))
    (get-output-string out)))

;; After:
(define shim-out
  (capture-output (lambda () (check-true (system* exe)))))
```

**Pattern B** (Racket function, no return check) — lines ~787, ~795:
```racket
;; Before:
(define runtime-status-out
  (let ([out (open-output-string)])
    (parameterize ([current-output-port out]
                   [current-error-port (open-output-string)])
      (cmd-runtime '("status"))
      (get-output-string out))))

;; After:
(define runtime-status-out
  (capture-output (lambda () (cmd-runtime '("status")))))
```

#### 4. Use `expect/shell` for subprocess exit-code + output checks

Convert `run-program/capture` usages where we check exit status and output into `expect/shell` calls with `#:status`, `#:port`, and `#:match`. The `run-program/capture` helper itself stays (still used by other tests that need all 3 values).

**Example — shim no-toolchain error message** (lines ~100-120):
```racket
;; Before:
(let-values ([(status out err) (run-program/capture shim '())])
  (check-equal? status 2)
  (check-equal? out "")
  (check-true (string-contains? err "rackup: 'racket' is managed by rackup..."))
  (check-true (string-contains? err "Install one with: rackup install stable"))
  ...)

;; After: use expect/shell for the structured check, keep string-contains? for multiple substring checks on the same run
```

For cases with a single output check (e.g., lines ~147-151 — status 23, empty stdout/stderr), `expect/shell` with `#:status` is a clean fit:
```racket
;; Before:
(let-values ([(status out err) (run-program/capture shim '("--version"))])
  (check-equal? status 23)
  (check-equal? out "")
  (check-equal? err ""))

;; After:
(expect/shell (list shim "--version") #:status 23 "")
```

For subprocess tests that check stderr with multiple substrings, keep `run-program/capture` but use `expect` with `#:match 'contains` and `#:port 'stderr` to check fragments:
```racket
;; Before:
(check-true (string-contains? err "rackup: '~a' is managed by rackup..."))

;; After:
(expect (display err) "rackup: 'racket' is managed by rackup" #:match 'contains)
```

### Specific subprocess test conversions

1. **Lines 147-151**: Simple exit-23, empty output → `expect/shell (list shim "--version") #:status 23 ""`
2. **Lines 345-348**: Status 0, check stdout contains PLTHOME → `expect/shell (list shim) #:status 0 #:match 'contains (format "PLTHOME=~a" ...)`
3. **Lines 407-422**: Status 139, check stderr for qemu messages → keep `run-program/capture`, convert `string-contains?` to `expect #:match 'contains`

### Dependency

No version pinning needed — CI already uses `raco pkg install --auto recspecs` which gets the latest. The linked local install is already at the new version.

## Verification

```bash
raco test -y test/state-shims.rkt
raco test -y test/all.rkt
```


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/bd156a2b-a99b-4675-96ce-43c5fc8d56aa.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
