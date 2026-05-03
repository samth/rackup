# Ideas for Speeding Up CI Tests

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


The full CI pipeline has 12 jobs totaling ~14 hours of wall-clock time
(running in parallel, dominated by the 180-minute source-build job).
Most of that time is spent in Docker E2E jobs that rebuild images,
re-download Racket installers, and run sequential install/verify
cycles.

Ideas are grouped by estimated impact and effort.

---

## High Impact, Low Effort

### 1. Cache Docker images across jobs

Every Docker E2E job runs `docker buildx build` from the same
`Dockerfile.e2e`, installing the same `apt-get` packages (bash,
build-essential, curl, git, etc.) from scratch each time. Seven jobs
repeat this work independently.

**Fix:** Use GitHub Actions' Docker layer cache
(`actions/cache` with `type=gha` or a registry cache) so the base
image layer is built once and reused by all Docker jobs in the same
workflow run. This could save 2-5 minutes per job (14-35 minutes
total).

### 2. Increase `--source-build-jobs` from 2 to 4+

The `docker-e2e-source-build-link` job (180-minute timeout) compiles
Racket from source with only `-j2`. GitHub-hosted runners have at
least 4 cores (standard) or more (large runners).

**Fix:** Use `$(nproc)` or at least `-j4` for the source build. This
alone could cut the longest job's time roughly in half.

### 3. Pre-cache Racket installer downloads

Every E2E run downloads Racket installers from
`download.racket-lang.org` (fetching `version.txt`, `table.rktd`, and
the installer itself). The same stable version gets downloaded in
nearly every Docker job.

**Fix:** Download the common installers once in an early job (or use
`actions/cache` keyed on the stable version string), then mount or
copy the cache directory (`~/.rackup/cache/downloads/`) into each
container. The native i386 VM job already does this pattern
successfully.

### 4. Skip redundant pages-site builds in bootstrap-curl

The `docker-e2e-bootstrap-curl` job runs
`scripts/build-pages-site.sh` inside the container, which requires
installing the `plt-web` Racket package and running `racket
pages/site.rkt`. The `pages-build` job already builds this exact
artifact.

**Fix:** Pass the pages-build artifact to the bootstrap-curl job via
`actions/upload-artifact` / `actions/download-artifact` (the
`pages.yml` workflow already does this). Set
`RACKUP_E2E_PREBUILT_PAGES_DIR` to point at the downloaded artifact.

---

## High Impact, Medium Effort

### 5. Run specs in parallel within each E2E job

Inside `e2e-fresh-container.sh`, multiple toolchain specs (e.g.,
stable, 8.18, 7.9) are installed and tested sequentially. Each spec
install downloads an installer, runs it, then runs verification
checks.

**Fix:** Run independent spec installs in parallel using background
processes or GNU parallel. The installs write to separate directories
under `~/.rackup/toolchains/` and shouldn't conflict. Verification
steps that test switching between toolchains would still need to run
after all installs complete.

### 6. Use a pre-built Docker image from a registry

Instead of building the E2E Docker image in each job, push a
pre-built image to GitHub Container Registry (`ghcr.io`) and pull it
in each job. Rebuild the image only when `Dockerfile.e2e` changes
(detectable via `hashFiles`).

**Fix:** Add a conditional job that builds and pushes the image when
the Dockerfile changes, and have all E2E jobs pull from the registry.
Pulling a cached image takes seconds vs. minutes for a fresh build.

### 7. Merge related Docker E2E jobs

Several Docker E2E jobs test a single mode or spec:
- `docker-e2e-legacy-6_0`: one spec (6.0) with `--skip-package-tests`
- `docker-e2e-prerelease`: one spec (pre-release)
- `docker-e2e-bootstrap`: one mode (bootstrap + local-link fake)
- `docker-e2e-bootstrap-no-host-racket`: one mode variation

**Fix:** Combine related jobs into fewer jobs that test multiple
configurations sequentially. The Docker image build overhead (shared
across specs) dominates the per-spec test time. Running two specs in
one container is faster than building two separate containers.

---

## Medium Impact, Low Effort

### 8. Use a smaller base image for E2E tests

`Dockerfile.e2e` defaults to `ubuntu:24.04` and installs
`build-essential` plus many dev libraries. Most E2E tests don't need
a compiler toolchain; only the source-build job does.

**Fix:** Create a lighter Dockerfile variant (or use multi-stage
builds) for non-source-build jobs. Alternatively, use a slimmer base
like `debian:12-slim` and only install the packages each job actually
needs.

### 9. Cache the native i386 VM guest disk more aggressively

The native i386 VM job already caches the guest disk, but the cache
key includes hashes of four files. Any change to any of these
scripts invalidates the entire cache, forcing a full Debian install
(downloading the ISO, running the installer, rebooting).

**Fix:** Separate the OS-install cache key from the test-script cache
key. The base Debian install rarely needs to change; only the
firstboot test logic changes. Use a two-layer cache: one for the base
OS disk (keyed on ISO version and preseed), and a snapshot layer for
test scripts.

### 10. Replace QEMU platform-probe with unit tests

The `docker-e2e-qemu-platform-probe` job (45-minute timeout) boots
four different QEMU-emulated architectures just to verify that
`rackup_normalized_arch()` returns the right string for each. This is
a pure function of `uname -m` output.

**Fix:** Test architecture normalization as a unit test by mocking
`uname -m` output. Keep one or two QEMU-emulated runs as a smoke
test, but the full matrix of four architectures is overkill for what
is essentially a string-mapping function.

---

## Medium Impact, Medium Effort

### 11. Run only changed-path-relevant E2E jobs

Every push and PR runs all 12 CI jobs regardless of what changed. A
documentation-only change triggers 14 hours of E2E testing.

**Fix:** Use `paths` filters or `dorny/paths-filter` in the workflow
to skip E2E jobs when only docs, README, or non-script files changed.
The `pages.yml` workflow already uses path filters; apply the same
pattern to `ci.yml`.

### 12. Use GitHub Actions larger runners for the source-build job

The `docker-e2e-source-build-link` job is CPU-bound (compiling Racket
from source). Standard GitHub-hosted runners have limited cores.

**Fix:** Use `runs-on: ubuntu-latest-8-cores` (or similar larger
runner) for the source-build job specifically. Combined with idea #2
(more `-j` parallelism), this could reduce the 180-minute job to
under an hour.

### 13. Download Racket source tarball instead of cloning

For official release source builds (matching `v?[0-9]...`), the
script already downloads a pre-built source archive from
`download.racket-lang.org`. But for non-release refs, it does a full
`git clone` of the Racket repository.

**Fix:** Use `--depth 1 --single-branch` (already done) but also
consider using the GitHub tarball API
(`https://github.com/racket/racket/archive/refs/tags/v8.18.tar.gz`)
which avoids git overhead entirely and may be faster to download.

### 14. Run the copy-filtered-tree step once and share it

Every E2E container runs `copy-filtered-tree.sh` to prepare a clean
source copy, filtering out `.zo`, `.dep`, and `compiled/` artifacts.
The native i386 VM also runs this. The filtered tree is identical
across all jobs for the same commit.

**Fix:** Run the filter once in an early job, upload the result as an
artifact, and download it in each E2E job. This is a small win per
job (seconds, not minutes) but it eliminates redundant work and
ensures consistency.
