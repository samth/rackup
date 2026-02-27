# `rackup` TODO

Deferred and future work that came up in `PLAN.md`, implementation, or follow-up design discussion.

## Platform Support

- [ ] Add macOS host support.
  - Handle native installer/download formats on macOS.
  - Support both Apple Silicon and Intel macOS.
  - Decide whether macOS installs should prefer `.dmg` or `.tgz`.
  - Add real CI coverage on macOS runners.

- [ ] Add Windows host support.
  - Implement Windows platform detection and installer resolution.
  - Support Racket Windows installer formats and installation flow.
  - Design Windows shim/launcher behavior.
  - Design PowerShell/CMD shell integration.
  - Add real CI coverage on Windows runners.

## Runtime / Bootstrap

- [ ] Reconsider the hidden-runtime design.
  - Evaluate replacing the hidden runtime with a packaged executable built via `raco exe`.
  - Compare startup time, bootstrap size, upgrade story, and portability.
  - Decide whether a hybrid model makes sense: packaged `rackup` binary plus fallback runtime path.

- [ ] Improve hidden-runtime trust and verification.
  - Add checksum and/or signature verification instead of relying only on HTTPS and metadata checks.
  - Decide how to pin trusted metadata for bootstrap.

## Toolchain / Project UX

- [ ] Add project pin files / per-project toolchain selection.
  - This was explicitly left out of v1.
  - Decide file format and precedence relative to shell/global defaults.

- [ ] Consider `raco-cross` workspace import/export.
  - `rackup import-raco-cross-workspace` was identified as optional future work.
  - Decide how much workspace metadata to preserve.

- [ ] Consider richer floating aliases and policy controls.
  - Decide whether to support named aliases beyond `stable`, `pre-release`, and `snapshot`.
  - Decide whether installs should optionally auto-follow moving channels.

## Shell / Desktop Integration

- [ ] Extend shell support beyond bash and zsh.
  - Decide whether to support fish and nushell.
  - Decide whether shell init should also have an XDG-oriented mode.

- [ ] Add shell completion support.
  - Generate and install completions for bash and zsh first.
  - Decide whether fish completion should be included at the same time.
  - Decide whether completion generation should be static or command-driven.

- [ ] Add GUI / desktop integration for tools like `drracket`.
  - V1 only manages PATH shims.
  - Decide whether to create `.desktop` entries, app launchers, or file associations.

- [ ] Revisit interaction with existing `PLTHOME` setups.
  - V1 intentionally ignores existing `PLTHOME`/`racket-dev-goodies` setups.
  - Decide whether to support migration, coexistence warnings, or import helpers.

## Install / Filesystem Policy

- [ ] Decide whether to keep `~/.rackup` forever or add XDG support.
  - V1 intentionally uses `~/.rackup`.
  - Decide whether to support `XDG_DATA_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME`.

- [ ] Support more non-Linux install flows where official installers are not shell installers.
  - The current install path is strongest on Linux shell installers.
  - macOS and Windows support likely require additional extraction / install logic.

## Diagnostics / Recovery

- [ ] Expand `doctor`.
  - Add more fix-it suggestions for broken shims, stale shell config, and damaged runtime state.
  - Consider a `doctor --fix` mode.

- [ ] Improve recovery flows when the hidden runtime is missing or damaged.
  - Current errors are actionable, but recovery is still bootstrap-centric.
  - Decide whether `rackup` should self-heal more aggressively.

## Release / Security / Distribution

- [ ] Decide on a release strategy for `rackup` itself.
  - Tagging/versioning policy.
  - Whether bootstrap should default to `main`, a release tarball, or a versioned channel.

- [ ] Consider distributing prebuilt `rackup` artifacts.
  - This relates to the `raco exe` question.
  - Could reduce bootstrap complexity and startup overhead.

## Other

- Should we install things in user or installation scope?

- Should there be a `migrate` command to move packages between two
  installs?
  
- 
