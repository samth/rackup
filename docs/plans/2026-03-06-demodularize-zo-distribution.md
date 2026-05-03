# Plan: Demodularized Machine-Independent .zo Distribution

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


## Context

Currently, every `rackup` install compiles all `.rkt` source files from scratch on the client machine via `precompile-rackup-sources!`. This is slow and wasteful since the source code is identical across all installs. By shipping a demodularized machine-independent `.zo` in the tarball and recompiling it to machine-dependent form on install, we eliminate redundant source compilation and speed up the install/upgrade path.

## Changes

### 1. New file: `scripts/build-demod.sh`

Shell script that produces the demodularized machine-independent `.zo`:

```sh
#!/bin/sh
set -eu
LIBEXEC_DIR="$1"  # path to libexec/ in staging tree

# Step 1: Compile all sources to machine-independent .zo
racket -M -l- compiler/cm -e \
  '(managed-compile-zo (path->complete-path (string->path (vector-ref (current-command-line-arguments) 0))))' \
  "$LIBEXEC_DIR/rackup-core.rkt"

# Step 2: Demodularize into a single merged machine-independent .zo
raco demod -M "$LIBEXEC_DIR/rackup-core.rkt"

# Step 3: Verify output exists
test -f "$LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo"
```

### 2. Modify `scripts/build-pages-site.rkt`

After `copy-filtered-tree.sh` copies source into the staging dir (line 40-45) and **before** the `tar` call (line 46), run the demod build targeting the staged `libexec/`:

```racket
;; After copy-filtered-tree, before tar:
(run (build-path root-dir "scripts" "build-demod.sh")
     (build-path src-stage "libexec"))
```

This places `compiled/rackup-core_rkt_merged.zo` (machine-independent) inside the staging tree so it's included in the tarball.

### 3. Modify `scripts/install.sh` — `copy_filtered_tree` (lines 199-211)

Stop filtering out `compiled/` dirs and `.zo` files. The tarball is built from controlled CI, so any `.zo` present is intentional.

Change the `find` from:
```sh
find "$@" \
  \( -type d \( -name .git -o -name compiled \) -prune \) -o \
  \( -type f \( -name '*.zo' -o -name '*.dep' \) -prune \) -o \
  \( -type f -o -type l \) -print0
```
To:
```sh
find "$@" \
  \( -type d -name .git -prune \) -o \
  \( -type f -name '*.dep' -prune \) -o \
  \( -type f -o -type l \) -print0
```

### 4. Modify `libexec/rackup/runtime.rkt` — `precompile-rackup-sources!` (lines 255-275)

Add a check for the demodularized `.zo` before falling back to per-source compilation:

```racket
(define (precompile-rackup-sources!)
  (define racket-exe (hidden-runtime-racket-path))
  (when racket-exe
    (define merged-zo
      (build-path (rackup-libexec-dir) "compiled" "rackup-core_rkt_merged.zo"))
    (if (file-exists? merged-zo)
        ;; Recompile demod machine-independent .zo → machine-dependent
        (let-values ([(ok? details)
                      (run-hidden-runtime/quiet
                       racket-exe
                       "-l" "raco" "demod" "-r"
                       (path->string* merged-zo))])
          (unless ok?
            (eprintf "rackup: warning: failed to recompile demodularized .zo\n")
            (unless (string-blank? details) (eprintf "~a\n" details))))
        ;; Fallback: compile from source (existing logic)
        (let ([sources (rackup-source-paths)])
          (when (pair? sources)
            ;; ... existing managed-compile-zo logic ...
            )))))
```

Key functions reused:
- `run-hidden-runtime/quiet` (`runtime.rkt:29`) — runs command via hidden runtime Racket
- `hidden-runtime-racket-path` (`runtime.rkt:33`) — gets path to installed Racket
- `rackup-libexec-dir` (`paths.rkt:48`) — `~/.rackup/libexec`
- `rackup-source-paths` (`runtime.rkt:233`) — finds all `.rkt` source files

### 5. Modify `bin/rackup` — prefer merged `.zo` when loading

After `CORE` is set (line 6), add:
```sh
DEMOD_ZO="$LIBEXEC_DIR/compiled/rackup-core_rkt_merged.zo"
if [ -f "$DEMOD_ZO" ]; then
  CORE="$DEMOD_ZO"
fi
```

In `rackup_run_core` (lines 62-68) and the final `exec` (lines 109-113): when loading a `.zo` directly, the `-y` flag is not needed (it's for source scripts). So the demod path always uses the non-`-y` invocation regardless of `USE_Y`.

### 6. Modify `.github/workflows/ci.yml` — tarball verification (lines 45-48)

Replace the blanket "no compiled artifacts" check with a targeted check:

```yaml
# Verify only expected machine-independent .zo is present, no .dep files
if tar -tzf /tmp/rackup-pages-site/rackup-src.tar.gz | grep -E '\.(dep)$'; then
  echo "rackup-src.tar.gz contains unexpected .dep files" >&2
  exit 1
fi
# Verify the demod .zo is present
if ! tar -tzf /tmp/rackup-pages-site/rackup-src.tar.gz | grep -q 'rackup-core_rkt_merged\.zo$'; then
  echo "rackup-src.tar.gz missing demodularized .zo" >&2
  exit 1
fi
```

### 7. Modify `scripts/e2e-fresh-container.sh` — `assert_rackup_self_compiled` (lines 187-192)

Accept either the demod merged `.zo` or per-module `.zo` files:

```sh
assert_rackup_self_compiled() {
  local merged_zo="$RACKUP_HOME/libexec/compiled/rackup-core_rkt_merged.zo"
  local core_zo="$RACKUP_HOME/libexec/compiled/rackup-core_rkt.zo"
  local main_zo="$RACKUP_HOME/libexec/rackup/compiled/main_rkt.zo"
  if [[ -f "$merged_zo" ]]; then
    return 0
  fi
  [[ -f "$core_zo" ]] || fail "expected rackup bytecode at $core_zo or $merged_zo"
  [[ -f "$main_zo" ]] || fail "expected rackup main bytecode at $main_zo"
}
```

## Verification

1. **Local build**: Run `scripts/build-demod.sh libexec` and verify `libexec/compiled/rackup-core_rkt_merged.zo` is created
2. **Local pages build**: Run `racket -y scripts/build-pages-site.rkt /tmp/test-site` and verify the tarball contains the merged `.zo`
3. **Install from tarball**: Extract the tarball, run `scripts/install.sh`, verify the merged `.zo` is copied to `~/.rackup/libexec/compiled/`
4. **Recompilation**: Run `rackup runtime install` and verify the merged `.zo` is recompiled (file modified time changes)
5. **Execution**: Run `rackup help` and verify it works using the demod `.zo`
6. **CI**: The existing cross-architecture E2E tests (`docker-e2e-bootstrap-curl`) will exercise the full flow on all 6 architectures

