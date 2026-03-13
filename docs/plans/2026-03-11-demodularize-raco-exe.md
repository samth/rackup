# Demodularize before `raco exe` on native platforms

## Goal

Use `raco demod` to flatten rackup's module tree into a single compilation unit before building executables with `raco exe`. This should produce faster-starting executables by eliminating per-module load overhead.

## Background

- Executables are built for 4 native platforms: x64-linux, x64-mac, aarch64-mac, aarch64-linux
- Current pipeline: `raco exe` → `raco distribute` (in `scripts/build-dist.sh`)
- Entry point: `libexec/rackup-core.rkt` (requires `libexec/rackup/main.rkt` which loads ~12 internal modules)
- One `define-runtime-path` in `libexec/rackup/main.rkt:27` — needs to survive demodularization
- The demod branch (`claude/demodularizer-zo-distribution-YsIuT`) used demod for source distribution (shipping .zo files); this plan is for the exe pipeline instead

## Approach: `#lang compiler/demod` wrapper

Use Racket's built-in `#lang compiler/demod` which integrates with `raco make` and `raco exe`. This is cleaner than manually running `raco demod` CLI and placing .zo files.

## Steps

### Step 0: Create feature branch

```sh
git checkout -b demod-exe main
```

All work happens on this branch.

### Step 1: Create demod wrapper file

Create `libexec/rackup-demod.rkt`:

```racket
#lang compiler/demod
"rackup-core.rkt"
#:exe
#:prune-definitions
```

- `#:exe` mode: strips syntax/compile-time info, keeps only `(main)` and `(configure-runtime)` submodules — appropriate since this is an end-user program
- `#:prune-definitions`: removes unused definitions (unsound but effective for dead code elimination)

### Step 2: Test locally that the demod exe works

Before changing CI, verify locally:

```sh
cd /home/samth/work/rackup
RACO=/home/samth/sw/plt/racket/bin/raco
RACKET=/home/samth/sw/plt/racket/bin/racket

# Compile (triggers demodularization)
$RACO make libexec/rackup-demod.rkt

# Build exe
$RACO exe -o /tmp/rackup-demod-test libexec/rackup-demod.rkt

# Test basic functionality
/tmp/rackup-demod-test version
/tmp/rackup-demod-test list
/tmp/rackup-demod-test help
```

**Key thing to verify**: `define-runtime-path` in `main.rkt:27` still works. The `rackup version` command uses `rackup-repo-dir` (a runtime path) to find the git repo for version info. If it fails or shows "unknown version", `define-runtime-path` is broken.

**Fallback if `#:exe` breaks `define-runtime-path`**: Switch to `#:dynamic` mode (which preserves syntax) or add syntax preservation for that specific module.

### Step 3: Benchmark with hyperfine

Build both plain and demod executables and benchmark with `hyperfine` to measure meaningful speedup:

```sh
# Build both variants
$RACO exe -o /tmp/rackup-plain-test libexec/rackup-core.rkt
# (demod exe already built in step 2)

# Compare sizes
ls -la /tmp/rackup-plain-test /tmp/rackup-demod-test

# Benchmark quick commands that users run frequently
hyperfine --warmup 3 \
  '/tmp/rackup-plain-test version' \
  '/tmp/rackup-demod-test version'

hyperfine --warmup 3 \
  '/tmp/rackup-plain-test list' \
  '/tmp/rackup-demod-test list'

hyperfine --warmup 3 \
  '/tmp/rackup-plain-test help' \
  '/tmp/rackup-demod-test help'
```

These commands (`version`, `list`, `help`) are startup-dominated, so they directly measure the benefit of demodularization. If there's no meaningful speedup (e.g. <10%), the change may not be worth the added complexity.

**Gate**: Only proceed if benchmarks show meaningful improvement.

### Step 4: Update `scripts/build-dist.sh`

Change the exe build step to use the demod wrapper:

```diff
-# Step 1: Compile with raco exe
-"$RACO" exe -o "$BUILD_DIR/rackup-core" \
-  "$ROOT_DIR/libexec/rackup-core.rkt"
+# Step 1: Demodularize and compile with raco exe
+"$RACO" make "$ROOT_DIR/libexec/rackup-demod.rkt"
+"$RACO" exe -o "$BUILD_DIR/rackup-core" \
+  "$ROOT_DIR/libexec/rackup-demod.rkt"
```

The `raco make` step triggers demodularization (flattening all modules). The `raco exe` step then embeds the demodularized compiled module.

### Step 5: Run unit tests

```sh
raco test -y test/all.rkt
```

Demodularization shouldn't affect tests (they test source modules, not the exe), but verify nothing broke.

### Step 6: Test with Docker E2E (locally)

```sh
test/docker-test-fresh-install.sh \
  --mode bootstrap --host-racket absent \
  --base-image ubuntu:24.04 --spec stable --spec 8.18
```

This tests the full install + smoke test flow using the demod exe distribution.

### Step 7: Commit and push, verify CI (including E2E)

Commit the new `rackup-demod.rkt` file and the `build-dist.sh` change. Push to the `demod-exe` branch and verify all CI jobs pass:

- **build-exe jobs**: Must successfully build the demod exe on all 4 native platforms
- **E2E test jobs**: The built exe must pass the full E2E test suite (install, `rackup list`, `rackup install stable`, etc.)

The existing CI E2E tests already exercise the exe distribution when available. Verify those jobs consume the demod-built exe and pass.

## Risks

1. **`define-runtime-path` breakage**: `#:exe` mode strips syntax objects. `define-runtime-path` relies on syntax literals to record paths. `raco exe` has special support for extracting runtime paths, but this needs to be verified through demodularization. Mitigation: test in Step 2; fall back to `#:dynamic` mode if broken.

2. **`-g` (prune-definitions) unsoundness**: May incorrectly remove definitions that have needed side effects. Mitigation: thorough testing of all commands in Step 2.

3. **Build time increase**: Demodularization adds a compilation step. For CI this is acceptable. Monitor build times.

4. **Ephemeral files**: `#lang compiler/demod` creates `compiled/ephemeral/demod/` directories for intermediate work. These are automatically excluded from package creation but will appear in the source tree during builds. The `.gitignore` already covers `compiled/`.

## Out of scope

- Demodularization for the source distribution (that's what the existing demod branch covers)
- Lazy loading of `net/http-client` / `net/url` (separate optimization)
- Excluding specific heavy modules from flattening (can be added later with `#:exclude`)


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /home/samth/.claude/projects/-home-samth-work-rackup/50e6ff6a-e4a3-4aee-9b39-d5d7d65c6f24.jsonl

If this plan can be broken down into multiple independent tasks, consider using the TeamCreate tool to create a team and parallelize the work.
