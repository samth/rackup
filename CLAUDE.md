# Project Instructions

## Git

- Use `Closes #N` or `Fixes #N` in commit messages to auto-close GitHub issues.

## Testing

### Unit tests

```bash
raco test -y test/all.rkt           # run all unit tests
raco test -y test/<name>.rkt        # run a single test file
```

### Docker E2E tests

These match what CI runs. Each invocation builds a Docker image and runs the full install/smoke test inside it.

```bash
# Bootstrap on Ubuntu (matches "native x64 / ubuntu:24.04" CI job)
scripts/docker-test-fresh-install.sh \
  --mode bootstrap --host-racket absent \
  --base-image ubuntu:24.04 --spec stable --spec 8.18

# Bootstrap on Debian
scripts/docker-test-fresh-install.sh \
  --mode bootstrap --host-racket absent \
  --base-image debian:12 --spec stable --spec 8.18

# Direct mode (with system Racket in the image)
scripts/docker-test-fresh-install.sh \
  --mode direct --spec stable --spec 8.18
```

Run `scripts/docker-test-fresh-install.sh --help` for all options.
