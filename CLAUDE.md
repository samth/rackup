# Project Instructions

## Architecture

See `docs/IMPLEMENTATION.md` for a detailed description of the project's design and internals.

## Git

- Use `Closes #N` or `Fixes #N` in commit messages to auto-close GitHub issues.

## Testing

### Unit tests

```bash
raco test -y test/all.rkt           # run all unit tests
raco test -y test/<name>.rkt        # run a single test file
```

### Shell linting

Run before pushing changes to shell scripts (`*.sh`, `bin/rackup`):

```bash
# ShellCheck (catches bugs and warnings)
find . -name '*.sh' -type f -print0 | xargs -0 shellcheck --severity=warning
shellcheck --severity=warning bin/rackup

# shfmt (formatting)
find . -name '*.sh' -type f -print0 | xargs -0 shfmt -d -i 2 -ci
shfmt -d -i 2 -ci bin/rackup
```

### Docker E2E tests

These match what CI runs. Each invocation builds a Docker image and runs the full install/smoke test inside it.

```bash
# Bootstrap on Ubuntu (matches "native x64 / ubuntu:24.04" CI job)
test/docker-test-fresh-install.sh \
  --mode bootstrap --host-racket absent \
  --base-image ubuntu:24.04 --spec stable --spec 8.18

# Bootstrap on Debian
test/docker-test-fresh-install.sh \
  --mode bootstrap --host-racket absent \
  --base-image debian:12 --spec stable --spec 8.18

# Direct mode (with system Racket in the image)
test/docker-test-fresh-install.sh \
  --mode direct --spec stable --spec 8.18
```

Run `test/docker-test-fresh-install.sh --help` for all options.

## Plans

Archive all plan documents in `docs/plans/` with dated filenames (e.g., `2026-03-13-feature-name.md`). This includes plans created during brainstorming, implementation plans, research documents, and review documents.

## Verification and generation

When adding code that verifies, validates, or consumes a generated
artifact (checksums, sidecar files, metadata files, etc.), always
verify that the artifact is actually produced by the build/deploy
pipeline. Check the Pages build (`pages/build-pages-site.rkt`), CI
workflows (`.github/workflows/`), and install scripts
(`scripts/install.sh`) for the corresponding generation step. If it
doesn't exist, add it in the same commit.

## Code ownership

We own the entire project. There is no public API. Feel free to change any module's exports, signatures, or internal structure as needed — no backwards-compatibility workarounds required.
