# Static Lock Checking via Syntax Parameters

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Context

The state lock protects shared state mutations. Nothing currently prevents calling locked functions outside the lock — the exploration found a bug at `main.rkt:514-516`. The goal is compile-time enforcement via syntax parameters.

## Step 1: Redesign `define-file-lock` in `lock.rkt`

### New signature

```racket
(define-file-lock with-name define/locked-name lock-dir-expr lock-label)
```

### Two lock instances

```racket
;; in state-lock.rkt:
(define-file-lock with-state-lock define/state-locked (rackup-state-lock-dir) "rackup state")

;; in runtime.rkt:
(define-file-lock with-runtime-lock define/runtime-locked (rackup-runtime-lock-dir) "hidden runtime")
```

Each invocation produces its own independent syntax parameter — `define/state-locked` functions require `with-state-lock`, `define/runtime-locked` functions require `with-runtime-lock`. There is no cross-contamination: holding one lock does not satisfy the other's static check.

### What it generates

Given `(define-file-lock with-state-lock define/state-locked (rackup-state-lock-dir) "rackup state")`:

**1. A syntax parameter** (generated name, not exported):
```racket
(define-syntax-parameter state-lock-held? #f)
```

**2. A runtime lock function** (generated name, not exported):
```racket
(define (with-state-lock-impl thunk)
  ;; existing dynamic-wind logic unchanged
  ...)
```

**3. `with-state-lock`** — a macro that sets the parameter and calls the runtime lock:
```racket
(define-syntax-rule (with-state-lock body ...)
  (syntax-parameterize ([state-lock-held? #t])
    (with-state-lock-impl (lambda () body ...))))
```

**4. `define/state-locked`** — a macro for defining lock-requiring functions:
```racket
(define/state-locked (register-toolchain! id meta)
  body ...)
```

Expands to:
```racket
(begin
  (define (register-toolchain!-impl id meta)
    (syntax-parameterize ([state-lock-held? #t])
      body ...))
  (define-syntax (register-toolchain! stx)
    (if (syntax-parameter-value #'state-lock-held?)
        (syntax-case stx ()
          [(_ arg ...)
           #'(register-toolchain!-impl arg ...)])
        (raise-syntax-error #f
          "cannot be used outside of with-state-lock" stx))))
```

The `raise-syntax-error` fires for **any** use of `register-toolchain!` outside a locked context — both applications `(register-toolchain! ...)` and bare references like passing it as a value. The error message names the lock that's required.

The `syntax-parameterize` in the impl body ensures that callees (e.g., `set-default-toolchain!` called from `register-toolchain!`) also see the lock as held.

### Implementation notes for `lock.rkt`

- Requires: `racket/stxparam`, `(for-syntax racket/base racket/stxparam racket/syntax)`
- `define-file-lock` must be `define-syntax` with `syntax-case` (not `define-syntax-rule`) because it needs `generate-temporary` for internal names and `format-id` for the `-impl` suffix
- Nested `...` in the template needs `(... ...)` escaping since it's a macro that generates macros
- The syntax parameter and impl function don't need to be provided — macro hygiene carries the references through templates

### Key property

The checking is purely static. At runtime, `register-toolchain!` is just a normal function call to `register-toolchain!-impl`. The syntax parameter and `syntax-parameterize` disappear after expansion.

## Verification

After implementing just `lock.rkt`:
1. `raco test -y lock.rkt` — sanity check it compiles
2. Write a small test module that exercises the macro: define a lock, define a locked function, verify it compiles inside `with-lock` and fails outside

## Later steps (not yet)

- New `state-lock.rkt` module (so `state.rkt` and `shims.rkt` can import `define/state-locked`)
- Mark state-mutating functions as `define/state-locked`
- Update `commit-state-change!` to a macro (drop lambdas)
- Fix bug at `main.rkt:514-516`: `install-shim-aliases!` and `reshim!` are called outside any lock after `install-toolchain!` returns (the `--short-aliases` flag path in `cmd-install`)
- Update tests to wrap calls in `with-state-lock`


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/d3c26400-3c2a-4f4b-8066-b263a4d8544c.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
