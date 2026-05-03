# Security Remediation Plan

> **Historical plan** (dated artifact): This file is intentionally retained for historical context. For current canonical architecture/implementation behavior, see [`docs/IMPLEMENTATION.md`](../IMPLEMENTATION.md).


Status: Incomplete draft. This plan is not completed.

Date: 2026-03-13

Scope: Repo-wide security audit findings converted into a remediation plan. This document describes attacker threat models, concrete fixes, and validation work. It does not mean the fixes are implemented yet.

## Attacker Model Categories

1. Local execution-context attacker: can influence environment variables, wrapper scripts, CI job env, editor tasks, or shell startup, but does not already control the rackup code itself.
2. Distribution or supply-chain attacker: can tamper with downloaded artifacts, redirects, Pages content, CDN or origin content, or third-party CI actions.
3. Privileged operator or misconfiguration risk: a legitimate install or uninstall runs with an unsafe prefix or elevated privileges.

## Priority Order

1. Fix local destructive-delete and code-execution bugs first.
2. Fix supply-chain trust gaps in the release and bootstrap paths next.
3. Unify installer verification and path-safety checks so the same bugs do not reappear in parallel codepaths.

## Issues

### 1. Uninstall newline-injection deletion bypass

Priority: P0

Threat model: A local execution-context attacker can influence `RACKUP_HOME` in the environment where the victim runs `rackup uninstall`. This is not a remote attacker. It is a poisoned shell, CI job, editor task, or wrapper context.

Why it matters: `rackup uninstall` validates one path, serializes it through a line-based request file, then the shell wrapper reads only line 1 and deletes that truncated value. A newline in the path can therefore make rackup validate one path but delete another.

Remediation:

1. Stop using newline-delimited serialization for the uninstall target.
2. Have the wrapper create a private request file and use a format with unambiguous boundaries.
3. Reject control characters in `RACKUP_HOME` and uninstall target paths as a second line of defense.

Validation:

1. Add a regression test for `RACKUP_HOME=$'/tmp/x\n/etc'` and assert that uninstall refuses it.
2. Add tests for root, home directory, current directory, and control-character rejection.

Affected code:

1. [libexec/rackup/main.rkt:723](/home/samth/work/rackup/libexec/rackup/main.rkt:723)
2. [libexec/rackup/main.rkt:738](/home/samth/work/rackup/libexec/rackup/main.rkt:738)
3. [bin/rackup:88](/home/samth/work/rackup/bin/rackup:88)

### 2. Shim path traversal through toolchain IDs

Priority: P0

Threat model: A local execution-context attacker can set `RACKUP_TOOLCHAIN`, or can tamper with `~/.rackup/state/default-toolchain`, without modifying rackup code.

Why it matters: The shim treats the toolchain ID as a raw path segment, then sources `env.sh` and executes `bin/<tool>` from that derived path. That allows path traversal outside the rackup home and arbitrary code execution.

Remediation:

1. Define a strict toolchain-ID grammar and reject anything outside it.
2. Resolve the candidate path canonically and require it to stay under `$RACKUP_HOME/toolchains`.
3. Apply the same validation to the default-toolchain state file.
4. Longer term, replace shell `source` of arbitrary `env.sh` with structured env data parsed by rackup.

Validation:

1. Add tests for traversal attempts in both `RACKUP_TOOLCHAIN` and the default-toolchain file.
2. Add positive tests for legitimate toolchain IDs.
3. Add a test that invalid IDs are rejected before any `env.sh` is sourced.
4. Add a GH issue to replace `env.sh` with structured data.

Affected code:

1. [libexec/rackup/shims.rkt:43](/home/samth/work/rackup/libexec/rackup/shims.rkt:43)
2. [libexec/rackup/shims.rkt:57](/home/samth/work/rackup/libexec/rackup/shims.rkt:57)
3. [libexec/rackup/shims.rkt:60](/home/samth/work/rackup/libexec/rackup/shims.rkt:60)
4. [libexec/rackup/shims.rkt:232](/home/samth/work/rackup/libexec/rackup/shims.rkt:232)

### 3. Self-upgrade executes an untrusted installer source

Priority: P0

Threat model: Either a local execution-context attacker can influence `RACKUP_SELF_UPGRADE_INSTALL_SH`, or a distribution attacker can tamper with the downloaded script source or its redirect chain.

Why it matters: `self-upgrade` downloads a script and passes it directly to `sh`.

Remediation:

1. Gate environment override behind explicit test flag.
2. Add SHA256 checksum in known location for `install.sh` which is
   validated by `self-upgrade`.
3. Add GH issue about changing self-upgrade to avoid needing to run
   the install.sh script.

Validation:

1. Add tests that env override is ignored by default.
2. Add tests that a bad checksum fails closed.
3. Add tests that only trusted upgrade sources are accepted.

Affected code:

1. [libexec/rackup/main.rkt:801](/home/samth/work/rackup/libexec/rackup/main.rkt:801)
2. [libexec/rackup/main.rkt:827](/home/samth/work/rackup/libexec/rackup/main.rkt:827)
3. [libexec/rackup/main.rkt:854](/home/samth/work/rackup/libexec/rackup/main.rkt:854)

### 4. Hidden-runtime bootstrap lacks artifact verification

Priority: P0

Threat model: A distribution or supply-chain attacker can tamper with the upstream runtime installer, CDN, origin content, or cached artifact.

Why it matters: The bootstrap path directly runs `.sh` installers or extracts `.tgz` and `.dmg` content as trusted artifacts.

Remediation:

1. Require a SHA-256 for every hidden-runtime artifact.
2. Verify the artifact before reuse and before install.
3. Prefer release-pinned runtime metadata published with rackup over dynamically trusting upstream latest installers.

Validation:

1. Add tests for tampered cache rejection.
2. Add tests for tampered download rejection.
3. Add tests that missing checksum metadata fails closed.

Affected code:

1. [libexec/rackup-bootstrap.sh:417](/home/samth/work/rackup/libexec/rackup-bootstrap.sh:417)
2. [libexec/rackup-bootstrap.sh:440](/home/samth/work/rackup/libexec/rackup-bootstrap.sh:440)
3. [libexec/rackup-bootstrap.sh:451](/home/samth/work/rackup/libexec/rackup-bootstrap.sh:451)

### 5. GitHub Actions release path is not pinned to immutable SHAs

Priority: P0

Threat model: A supply-chain attacker compromises a third-party action release tag or upstream action repository used by the Pages release flow.

Why it matters: The Pages workflow has publish-capable permissions. A compromised action can turn into a compromised published site or installer.

Remediation:

1. Pin every `uses:` reference to a full commit SHA.
2. Reduce workflow permissions so only the final deploy job gets Pages credentials.
3. Prefer first-party or vendored actions for critical release steps.

Validation:

1. Add a CI lint that rejects non-SHA `uses:` refs.
2. Add a CI lint that rejects over-broad workflow permissions.

Affected code:

1. [.github/workflows/pages.yml:21](/home/samth/work/rackup/.github/workflows/pages.yml:21)
2. [.github/workflows/pages.yml:41](/home/samth/work/rackup/.github/workflows/pages.yml:41)
3. [.github/workflows/pages.yml:144](/home/samth/work/rackup/.github/workflows/pages.yml:144)
4. [.github/workflows/build-exe.yml:44](/home/samth/work/rackup/.github/workflows/build-exe.yml:44)

### 6. Installer downloads are not uniformly authenticated

Priority: P1

Threat model: A distribution or supply-chain attacker can tamper with installer hosting, redirects, or cached artifacts. This applies to normal toolchain installs beyond the hidden-runtime path.

Why it matters: Many release, snapshot, and prerelease installs rely on HTTPS alone, and redirects are followed automatically.

Remediation:

1. Require every downloadable installer record to include a checksum.
2. Refuse installation of any artifact without a checksum.
3. Reject cross-scheme and cross-host redirects unless they are explicitly allowlisted and the artifact is still checksum-verified.

Validation:

1. Add tests that release resolution without a checksum fails.
2. Add tests that hostile redirects fail.
3. Add tests that cache tampering is detected on reuse.

Affected code:

1. [libexec/rackup/remote.rkt:76](/home/samth/work/rackup/libexec/rackup/remote.rkt:76)
2. [libexec/rackup/remote.rkt:301](/home/samth/work/rackup/libexec/rackup/remote.rkt:301)
3. [libexec/rackup/install.rkt:124](/home/samth/work/rackup/libexec/rackup/install.rkt:124)
4. [libexec/rackup/util.rkt:123](/home/samth/work/rackup/libexec/rackup/util.rkt:123)

### 7. Hidden-runtime checksum plumbing is present but unused

Priority: P1

Threat model: Same as issue 4. A supply-chain attacker or cache-tampering attacker benefits because the code accepts a checksum parameter but does not enforce it.

Why it matters: The API suggests verification exists, which makes the trust model easy to misread and easier to regress further.

Remediation:

1. Route hidden-runtime downloads through the same verified cache path as normal installers, or share one implementation.
2. Verify existing cache entries before reuse and delete or redownload on mismatch.

Validation:

1. Add a test that a bad cached runtime installer is rejected even when the file already exists.

Affected code:

1. [libexec/rackup/runtime.rkt:67](/home/samth/work/rackup/libexec/rackup/runtime.rkt:67)
2. [libexec/rackup/runtime.rkt:330](/home/samth/work/rackup/libexec/rackup/runtime.rkt:330)

### 8. Installer cleanup under PREFIX is too dangerous

Priority: P1

Threat model: A local execution-context attacker or bad automation can influence `RACKUP_HOME` or `--prefix`, or an operator can run install with elevated privileges against an unsafe prefix.

Why it matters: Cleanup uses recursive deletes under that prefix and assumes the prefix is safe.

Remediation:

1. Add prefix safety checks similar to uninstall.
2. Refuse `/`, the user home directory, and other obviously dangerous roots unless an explicit unsafe flag is set.
3. Narrow cleanup to owned paths rather than broad directories where possible.

Validation:

1. Add tests for rejecting `/`.
2. Add tests that a normal custom prefix such as `/opt/rackup` still works.
3. Add tests that cleanup does not remove unrelated sibling content.

Affected code:

1. [scripts/install.sh:4](/home/samth/work/rackup/scripts/install.sh:4)
2. [scripts/install.sh:475](/home/samth/work/rackup/scripts/install.sh:475)
3. [scripts/install.sh:516](/home/samth/work/rackup/scripts/install.sh:516)

### 9. The checked-in install script is unsafe in source mode

Priority: P2

Threat model: A developer, tester, or CI job runs the repo copy of `scripts/install.sh` directly instead of the built and published one, while a distribution attacker can tamper with the source archive being fetched.

Why it matters: The in-repo template leaves the source checksum token unsubstituted, so source installs proceed without integrity verification.

Remediation:

1. Make the checked-in file fail closed when the token is unsubstituted.
2. Generate a release artifact for the published installer and treat the repo file as a template, not as a distribution path.

Validation:

1. Add a test that direct execution of the repo copy with `--source` fails with a clear message unless an explicit unsafe-dev flag is set.

Affected code:

1. [scripts/install.sh:14](/home/samth/work/rackup/scripts/install.sh:14)
2. [scripts/install.sh:432](/home/samth/work/rackup/scripts/install.sh:432)
3. [scripts/install.sh:497](/home/samth/work/rackup/scripts/install.sh:497)

### 10. RACKUP_UNINSTALL_REQUEST_FILE is an arbitrary file-write sink

Priority: P2

Threat model: A local execution-context attacker can influence the environment when the victim runs uninstall.

Why it matters: Uninstall will overwrite an attacker-chosen writable path with structured data.

Remediation:

1. Stop honoring that env var in production.
2. Have the wrapper create the temp file itself in a private temp directory and pass only that path forward.
3. If tests need override behavior, gate it behind a test-only flag.

Validation:

1. Add tests that uninstall only writes to wrapper-created temp files.
2. Add tests that arbitrary env override is ignored in normal builds.

Affected code:

1. [libexec/rackup/main.rkt:717](/home/samth/work/rackup/libexec/rackup/main.rkt:717)
2. [libexec/rackup/main.rkt:787](/home/samth/work/rackup/libexec/rackup/main.rkt:787)

## Cross-Cutting Hardening

1. Create one trusted-path utility for toolchain IDs, rackup home, prefixes, and temp-file handoff.
2. Create one trusted-download utility for checksum enforcement, redirect policy, and cache verification.
3. Separate production overrides from test-only overrides. Environment variables that bypass trust decisions should not exist in release builds.
4. Add a dedicated security regression suite covering env poisoning, path traversal, newline and control characters, redirect policy, and cache tampering.

## Recommended Execution Sequence

1. Patch the P0 local code-execution and destructive-delete issues first: uninstall, shim traversal, self-upgrade.
2. Patch the P0 supply-chain issues next: hidden-runtime verification and pinned GitHub Actions.
3. Unify installer verification paths so hidden runtime and normal installs share the same checksum-enforcing implementation.
4. Harden prefix handling and remove test or debug env overrides from production code paths.
5. Add CI policy checks so these regressions stay blocked.
