# Linux support

`mcs` runs on macOS and on Linux (glibc). This document records what is verified, what differs
between the two platforms, and why each porting decision was made.

Sections 1–3 and 6 describe the platform. Section 4 is the per-feature compatibility checklist:
a row is filled in only after that feature has been **run** on Linux. Section 5 carries one
ADR-style entry per decision.

## 1. Status and supported configurations

`mcs` is built and tested on **Linux x86_64 with glibc**. Every feature works, and section 4 records
how each one was verified; six features behave differently from macOS, and the matrix says how.

| | |
|---|---|
| Architecture | x86_64. No aarch64 artifact is published yet. |
| libc | glibc. musl is untested; there is no `canImport(Musl)` branch. |
| glibc floor | 2.35 — the published binary is built on Ubuntu 22.04. |
| Tested on | Ubuntu 24.04 (development); the `ubuntu-latest` GitHub runner once this PR's CI has run. |
| Other distributions | Any glibc ≥ 2.35 distribution is expected to work. **Nothing is claimed about Fedora, Alpine or NixOS** — they have not been tested. |

CI is configured to run `swift build`, the full test suite and the release build on Linux for every
pull request, alongside the two macOS jobs; the Linux job lands with this change, so its first run is
this PR's. Lint runs on macOS only: SwiftFormat and SwiftLint give the same verdicts on both, so a
second run would only add version skew.

## 2. Prerequisites

`mcs` shells out to a few tools by absolute path and assumes they exist:

| Path | Used for | Present on |
|---|---|---|
| `/usr/bin/which` | resolving every command name to a path | Ubuntu/Debian (`debianutils`), most distributions |
| `/usr/bin/env` | invoking the `claude` CLI | coreutils |
| `/bin/bash` | running `shell:` components and pack scripts | every mainstream distribution |
| `libstdc++.so.6` | the published binary links against it dynamically | most distributions; minimal containers need `apt-get install -y libstdc++6` |

**If `/usr/bin/which` is missing** (it is absent on NixOS, and Debian has been retiring it),
`ShellRunner.resolvedPath` returns `nil` for *every* command, so `Homebrew.provides`, the Claude Code
prerequisite and every command-based doctor check report "not found". Measured with `which` masked
on a machine where Claude Code is genuinely installed:

| Command | Result |
|---|---|
| `mcs sync` | **exits 1 and does nothing** — "Claude Code CLI not found", then the install instructions |
| `mcs update` | **exits 1 and does nothing** — same message |
| `mcs doctor` | exits 0, reporting everything as missing |

So the two commands that change anything refuse to run and tell the user to install software they
already have. See ADR D9 for why this is documented rather than worked around.

Homebrew is **optional** on Linux. Without it, `brew:` components are verified through `PATH` only
and cannot be installed by mcs — see the `brew:` row in section 4 and ADR D8.

## 3. Install, build and test on Linux

### Install

Download the tarball for the release you want from
<https://github.com/mcs-cli/mcs/releases/latest>, unpack it, and put `mcs` on your `PATH`:

```bash
tar -xzf mcs-<version>-linux-x86_64.tar.gz
install -D -m 0755 mcs ~/.local/bin/mcs
mcs --version
```

There is no Homebrew formula for Linux: the tap publishes the macOS universal binary only.
`mcs check-updates` therefore tells Linux users to download the latest release rather than to run
`brew upgrade`.

### Build from source

```bash
# Install a toolchain, e.g. via swiftly (https://swift.org/install/linux/)
swift build
swift test
swift build -c release --static-swift-stdlib     # what the release workflow ships
```

`swift test` output does not display in some terminals, so redirect it and read the file:

```bash
mkdir -p .test-output && swift test > .test-output/results.txt 2>&1
```

`.test-output/` is gitignored.

**Do not run the suite as root.** `UpdateCheckerTests.registryWriteFailureContract` makes a
directory read-only and asserts that a write into it fails; root ignores directory permissions, so
that one test fails under `sudo` or in a root container. This is why the CI job runs on the
`ubuntu-latest` runner rather than in a `swift:*` container image.

**Run it with `--no-parallel` on Linux.** CI does, for the reason in the known limitations below;
without it roughly one full run in four fails with a spurious `ETXTBSY`. Serial costs about a
quarter more wall-clock time (42s against 34s here).

## 4. Compatibility matrix

Legend: `verified` — run on Linux and observed; `verified (with a difference)` — works, but not identically to macOS; the Notes column says how.

| Feature | macOS | Linux | Notes |
|---|---|---|---|
| `mcs sync` (project) | supported | verified | `mcs sync --pack linux-probe` in a git project: components installed, `settings.local.json` composed, `CLAUDE.local.md` generated, `.mcs-project` written. |
| `mcs sync --global` | supported | verified | `mcs sync --global --pack git-probe`: artifacts under `~/.claude/`, `settings.json` composed, `global-state.json` written. |
| `--customize` raw-mode picker | supported | verified | Driven under a real PTY: `↓` moved the cursor, `Space` toggled, `Enter` applied; in-place redraw and cursor hide/show correct. |
| Non-TTY fallback picker | supported | verified | stdin a PTY, stdout a pipe: numeric toggle + `Enter`, colours disabled. |
| `shell:` components | supported | verified | `shell: touch <path>` created the marker. |
| `shellInteractive: true` (PTY/sudo) | supported | verified | `forkpty` path ran the command; marker file created, with stdin from `/dev/null` and under a real controlling terminal. Also asserted by `LifecycleIntegrationTests`. The PTY is allocated with a default 0×0 window size on both platforms. |
| `brew:` components | supported | verified (with a difference) | Same predicate on both platforms. Without Linuxbrew a `brew:` component is satisfied only when the formula name is also the command name — `brew: node` passes with `node` on PATH, `brew: ripgrep` does not because the command is `rg`. Doctor then reports it missing and names the system package manager instead of pointing back at `mcs sync`. Installing a formula still needs Linuxbrew. |
| `mcp:` (`claude mcp add`) | supported | verified | `demo-server` registered via `claude mcp add -s local`; `claude mcp list` shows it; removal deregisters it. |
| `plugin:` | supported | verified | `hookify@claude-code-plugins` installed through `claude plugin install`; `claude plugin list` shows it enabled. |
| `hook:` / `command:` / `skill:` / `agent:` copies | supported | verified | All four installed; hooks namespaced under `<pack-id>/`; interpreter inferred (`bash` for `.sh`, `python3` for `.py`). |
| `settingsFile:` | supported | verified | Deep-merged into `settings.local.json` with `__GREETING__` substituted. |
| `gitignore:` | supported | verified | Entry added to `~/.config/git/ignore`; reference counting kept it when one of two scopes was removed. |
| `mcs update` | supported | verified | `mcs update --project` re-applied the pack and refreshed `mcs.lock.yaml`. |
| `mcs doctor` | supported | verified | 20 checks across every section; `✓`/`⚠` rendering correct. |
| `mcs doctor --fix` | supported | verified | Deleting `.claude` from the global gitignore then `doctor --fix` re-added it (`GitignoreCheck.fix`). |
| `mcs pack add` (git) | supported | verified | `mcs pack add git://…/gitprobe` cloned, prompted for trust, registered. |
| `mcs pack add` (local) | supported | verified | `mcs pack add <dir>` registered in place with `commitSHA: local`. |
| `mcs pack remove` / `list` / `update` / `validate` | supported | verified | `remove` unconfigured every affected scope; `update` reported "already up to date"; `validate` produced the python3 heuristic warning. |
| Pack trust hashing | supported | verified | Trust prompt shown on add for both a local and a git pack; re-validated on `pack update` (SHA-256 now from swift-crypto). |
| `mcs export` (incl. brew formula hints) | supported | verified (with a difference) | Exported `techpack.yaml`, hooks, skill, command, agent, settings and template from a live project. The brew formula hints are empty without Linuxbrew — `detectFormula` reads symlinks under the Linuxbrew prefixes. |
| `mcs cleanup` | supported | verified | Found and deleted a `CLAUDE.local.md.backup.*` file, with and without `--force`. |
| `mcs check-updates` + SessionStart hook | supported | verified (with a difference) | `check-updates`, `--json` and `--hook` all run; `mcs config set update-check-cli true` registered `mcs check-updates --hook` in `~/.claude/settings.json` and the cooldown file was written. The upgrade instruction differs: `brew upgrade` on macOS, download the release tarball on Linux. |
| `mcs config` | supported | verified | `list` / `get` / `set` against `~/.mcs/config.yaml`. |
| `$HOME` override | supported | verified (with a difference) | `mcs` resolves its home from `$HOME`, falling back to the passwd entry, so `HOME=… mcs …` behaves the same on both platforms. One gap: a `~` typed in a pack path or a pack's doctor `path:` is still expanded from the passwd entry on Linux — see known limitations. |
| File lock (`flock`) | supported | verified | Two concurrent syncs: the second exited 1 with "Another mcs process is running". |
| Lockfile (`mcs.lock.yaml`) | supported | verified | Written after sync with `generate-lockfile true`; `mcs sync --lock` consumed it. |
| Terminal colours / width | supported | verified | ANSI colour and the wrapped/re-rendered picker observed under a PTY; colours suppressed when stdout is a pipe. |
| Claude Code prerequisite | supported | verified (with a difference) | With `claude` off PATH, Linux prints the native-installer and npm commands and returns false. macOS still offers the Homebrew install; `claude-code` is a cask and Linuxbrew has no casks. |
| Release artifact | `.tar.gz` (universal) | verified (with a difference) | `swift build -c release --static-swift-stdlib` produces one 95 MB binary; the tarball holds exactly one file and `./mcs --version` prints the version. `ldd` still shows `libstdc++.so.6`, `libgcc_s.so.1`, `libm`, `libc` and `ld-linux`. |
| Telemetry | removed | removed | Deleted outright — see ADR D1. |

## 5. Decisions (ADR entries)

Each entry records the context, the options considered, the decision, and what it costs.

### D1 — TelemetryDeck, `MCSAnalytics` and the `telemetry` config key are deleted

**Context.** The TelemetryDeck SDK is Apple-only, and the anonymous user id was derived from IOKit's
`IOPlatformUUID`. Together they were the first hard blocker for a Linux build: 24 call sites across
nine command files, one config key, and one dependency.

**Options considered.** (a) Delete everything. (b) Keep the config key with a no-op implementation.
(c) Keep the key, delete the implementation. (d) `#if canImport(IOKit)`-gate it so macOS keeps
sending signals.

**Decision: (a).** A config key that accepts `true` and does nothing lies to the user in
`mcs config list`, and 24 no-op call sites are exactly the dead narration the repo's comment rule
exists to prevent. (d) would fork behaviour between platforms permanently and keep an Apple-only
package in the dependency graph for one feature.

**Consequences.**
- On disk it is backward compatible: `MCSConfig` is a synthesized `Codable` struct, and synthesized
  decoders ignore unknown keys, so an existing `~/.mcs/config.yaml` containing `telemetry: false`
  still loads. Pinned by a test.
- **The first `mcs config set <anything>` after upgrading re-encodes the struct and silently drops
  the user's `telemetry:` line.** Harmless, but it is a real change to a file the user owns.
- `mcs config set telemetry false` now reports an unknown key. The key was never documented in the
  CLI reference.
- `~/.mcs/.telemetry-noticed` is orphaned. It is left in place: deleting other people's files to
  tidy up is worse than an empty file.
- Every command got faster on macOS too — `trackCommand` ended with a 200 ms `RunLoop` wait.
- Telemetry can be restored from git history in one commit if it is ever wanted back.

### D2 — swift-crypto is a Linux-only target dependency; CryptoKit stays on Darwin

**Context.** Three files hash with `SHA256.hash(data:)` from CryptoKit. Foundation has no SHA-256 on
Linux, so a dependency is unavoidable.

**Options considered.** (a) An unconditional swift-crypto dependency and `import Crypto` everywhere.
(b) A conditional *target* dependency plus a `#if canImport(CryptoKit)` import shim. (c) Hand-roll
SHA-256. (d) Shell out to `sha256sum`.

**Decision: (b).**

```swift
.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
```

**Why not (a).** On Darwin the `Crypto` target declares `resources: [.copy("PrivacyInfo.xcprivacy")]`,
so putting it in the macOS graph makes SwiftPM emit a `swift-crypto_Crypto.bundle` next to the
release binary — and the release workflow tars a single file. (b) keeps the tarball one file.
Separately, macOS digests stay on the system CryptoKit, which is the "bit-identical to today"
guarantee for the hashes persisted in `.mcs-project` state and used for drift detection.
(It is *not* true that swift-crypto compiles BoringSSL on macOS: its manifest gates
`CCryptoBoringSSL` on `[.linux, .android, .windows, .wasi]`.)

**Why not (c)/(d).** Hand-rolled crypto is a maintenance liability even for a hash; shelling out
costs a process per file and makes `FileHasher` untestable offline.

**Consequences.** `swift package resolve` fetches **two** more repositories on macOS — swift-crypto
and its transitive `swift-asn1`. The CI cache key is `hashFiles('Package.swift')`, so that is paid
once per manifest change. `Package.resolved` is gitignored, so `from: "3.0.0"` floats across 3.x —
the same exposure the two existing dependencies already have. `FileHasherTests` and
`SettingsHasherTests` each pin a known digest, so a divergence between the two implementations fails
the suite instead of silently invalidating state files.

### D3 — `Locked<Value>` replaces `OSAllocatedUnfairLock`

**Context.** `import os` is Darwin-only. Two sites used `OSAllocatedUnfairLock`: the warning counter
behind `CLIOutput` and a one-shot timeout flag in `ScriptRunner`.

**Options considered.** (a) `NSLock` inline at both sites. (b) One small `Locked<Value>`.
(c) `Synchronization.Mutex`. (d) A serial `DispatchQueue`. (e) An actor.

**Decision: (b).** One named type reads better than two bespoke lock/unlock pairs, and it is twenty
lines. **Why not (c):** `Mutex` is macOS 15+, and this package's floor is macOS 13 — raising it would
drop macOS 13 and 14 users for a lock. **Why not (e):** `ScriptRunner` reads its flag synchronously
after `waitUntilExit()`; an actor forces `await` into a synchronous path.

**Consequences.** `NSLock` is marginally slower than an unfair lock. Both sites are cold. The
`@unchecked Sendable` on `Locked` is the type's purpose rather than a way to quiet the checker: the
invariant — every access happens under the lock — is real and cannot be expressed to the compiler,
and the doc comment says so at the one site that owns it.

### D4 — Platform imports are an explicit `#if canImport` chain, per file

**Context.** Five files call libc directly. On macOS they got those symbols from Foundation's Darwin
re-export or an outright `import Darwin`.

**Options considered.** (a) A chain in each file. (b) A `Platform.swift` with `@_exported import`.
(c) A C shim target.

**Decision: (a)**, verbatim in each of the five files:

```swift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
```

**Why not (b).** `@_exported` is an underscored attribute, and it hides from every reader of
`ShellRunner.swift` that the file depends on libc. **Why not (c).** Nothing is missing from
SwiftGlibc — see D5. No `canImport(Musl)` branch is added: nothing here builds for musl, and an
untested branch is worse than no branch.

**Consequence beyond the imports.** Four Foundation methods are `@discardableResult` on Darwin and
not on Linux, so their results had to be used rather than dropped. Three sites now require the file
to exist before treating it as a directory, which is behaviour-identical. The fourth is a small
**macOS-visible change**: `GitignoreManager`'s bootstrap used `createFile(atPath:contents:)`, whose
`false` return was ignored, and now writes through `Data` — so a failure to create the global
gitignore throws out of `ensureFileExists()` instead of passing silently and failing later at the
read.

### D5 — `forkpty()` is called from Glibc; no C shim, no `posix_openpt` rewrite

**Context.** `ShellRunner.runInteractive` allocates a real PTY so `sudo` can read a password. The
open question was whether SwiftGlibc exposes `forkpty`.

**Decision: it does.** `pty.h` is in `SwiftGlibc.h.gyb`, the Glibc modulemap declares `link "util"`,
and the call links and runs on glibc 2.39 with no extra linker flag. `cfmakeraw` is exposed too.

**Why not the alternatives.** A C shim or `@_silgen_name` would work around a declaration that is
not missing; reimplementing with `posix_openpt`/`grantpt`/`setsid`/`ioctl(TIOCSCTTY)` duplicates
forty lines of subtle libc behaviour for no benefit.

**Consequences.** One real difference did surface inside the fork child: Glibc types `strdup` as
returning an optional where Darwin implicitly unwraps it, so the child was left dereferencing
optionals for the command path and the working directory. A force-unwrap there would trap through
the Swift runtime after `fork()`, where only async-signal-safe calls are legal, so both strings are
now allocated and checked in the parent. If a future toolchain drops `pty.h` the build fails
immediately and the C shim remains a ~15-line fallback.

### D6 — termios: index `c_cc` through `VMIN`/`VTIME`, widen masks through `tcflag_t`

**Context.** The raw-mode picker set `raw.c_cc.16` and `raw.c_cc.17` with `// VMIN` / `// VTIME`
comments, and masked with `~UInt(ICANON | ECHO)`. Both are Darwin facts: `tcflag_t` is `UInt` there
and `UInt32` on Glibc, and `c_cc` is a tuple whose length and order differ (`NCCS` is 20 against 32,
`VMIN` is index 16 against 6).

**Options considered.** (a) `#if canImport(Darwin) raw.c_cc.16 = 1 #else raw.c_cc.6 = 1 #endif`.
(b) A small `TerminalAttributes` type that binds `c_cc` as `cc_t` memory and subscripts it with the
platform's own constant.

**Decision: (b).** (a) is a `#if` hiding a real difference behind two magic numbers; indexing by
`VMIN` has no second place to get wrong. `withUnsafeMutableBytes` + `bindMemory(to: cc_t.self)` is
sound — `c_cc` is already a tuple of `cc_t` — and nothing in Foundation or the stdlib does it for
you. `TerminalAttributesTests` asserts the same things on both platforms without needing a TTY,
which is why the read accessor exists; its doc comment says so, so it is not deleted as dead code.

### D7 — `TIOCGWINSZ` widens to `UInt`

`TIOCGWINSZ` imports as `Int32` on Glibc and `UInt` on Darwin, and `ioctl` takes a `UInt` request on
both. `ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)` compiles everywhere and is a no-op conversion on
Darwin, so no `#if` is needed. In the same file `Darwin.read(...)` loses its module qualifier:
unqualified `read` resolves to libc on both platforms, because `CLIOutput` has a `write` member but
no `read` member.

### D8 — Homebrew on Linux

**Context.** mcs resolves a Homebrew prefix, puts its `bin` on the PATH it hands to subprocesses,
and verifies `brew:` components. Linuxbrew installs at `/home/linuxbrew/.linuxbrew`, and most Linux
users have no Homebrew at all.

**Decisions.**

1. **The prefix derivation no longer resolves symlinks.** It takes two components up from
   `$PREFIX/bin/brew`. Homebrew's installer creates `$PREFIX/bin/brew -> ../Homebrew/bin/brew` on
   Linux *and on Intel macOS*; only arm64 macOS has a real file there. Resolving first yielded
   `$PREFIX/Homebrew`, whose `bin` holds only `brew`, so `pathWithBrew` prepended an empty directory
   and hid `$PREFIX/bin`, where every formula's symlink lives — breaking the PATH-first probe that
   `brew:` components rest on. This is also a latent fix for Intel macOS.
2. **The fallback prefix and `allPrefixes` are platform-aware.** Linux gets
   `/home/linuxbrew/.linuxbrew` and `~/.linuxbrew`. No `brew --prefix` subprocess is spawned.
3. **`Homebrew.provides` does not change.** It probes PATH under the name with any tap qualifier
   stripped, then asks `brew list`. **The consequence, stated plainly: on Linux without Linuxbrew a
   `brew:` component is satisfied only when the formula name is also the command name.** `brew: node`
   passes when `node` is on PATH; `brew: ripgrep` does not, because the command is `rg`. There is no
   alias table, because no function can map formula names to command names in general; adding
   heuristics would trade a clear rule for a list that is always incomplete.
4. **The messages say what actually works.** When Homebrew is absent, telling the user to run
   `mcs sync` is a loop with no exit: sync prints "Homebrew not found" and sends them back to doctor.
   `ComponentExecutor` (install and uninstall) and `BrewPackageCheck.fix()` now name the package and
   the system package manager. The command-exists check drops its `mcs sync` hint entirely, because
   nothing there knows which component — if any — would install that command.
5. **`ensureClaudeCLI` never offers Homebrew on Linux.** `claude-code` is a Homebrew *cask*, and
   Linuxbrew has no casks, so the offer would have failed on exactly the machines that have brew.
   Linux prints the native-installer and npm commands and returns `false`.

**Rejected.** Auto-installing Linuxbrew (a package manager installing a package manager, unprompted)
and auto-installing Claude Code via `curl | bash` or npm (a trust decision mcs cannot make for the
user; npm's global prefix may be root-owned). Also rejected, for now: a `platforms:` key in
`techpack.yaml` so a pack could mark a component macOS-only. It is the right long-term answer, but it
is a manifest schema change with ecosystem impact and is not needed to make mcs work on Linux.

### D9 — `/usr/bin/which` stays, documented as a prerequisite

**Context.** `ShellRunner.resolvedPath` and `Environment.resolveCommand` shell out to
`/usr/bin/which`. It is present on Ubuntu 24.04, absent on NixOS, and Debian has been retiring it.

**Options considered.** (a) Keep it and document it. (b) Replace it with an in-process PATH scan.
(c) Keep it and add a `mcs doctor` check that fails loudly when it is missing.

**Decision: (a).** (b) widens a portability PR with a behaviour change to a hot path shared by every
command. (c) sounds small but is not: `FileExistsCheck.fix()` returns "Run 'mcs sync' to install",
which is exactly the dead-end message decision D8.4 removes, so it would need a new parameter; the
check would then print a permanently-passing line in every `mcs doctor` run on *both* platforms; and
touching doctor mandates an integration test. Three files and a test, for a condition that does not
occur on the platforms mcs ships for.

**Consequences.** The failure mode is documented in section 2 rather than detected, and it is worse
than "reports an empty machine": `mcs sync` and `mcs update` refuse to run and blame a missing Claude
Code CLI that is in fact installed. That is a bad failure, and it is why the decision is documented
prominently rather than left implicit — but it does not change the arithmetic, because the doctor
check considered in (c) would not have helped either. `mcs doctor` is the one command that still
completes, so a user who runs it sees a `✗ which` line; a user who runs `sync` gets the misleading
error and never reaches doctor. Detecting it where it actually bites means a check in `sync`'s
prerequisite path, which is a different change from the one (c) proposed.

### D10 — No Subprocess 1.0, no tools-version bump, macOS 13 floor stays

swift-tools-version 6.0 already supports `.product(…, condition: .when(platforms:))`, and
swift-crypto is tools-version 5.9 / macOS 10.15, so nothing forces a bump. Adopting Subprocess 1.0
would rewrite `ShellRunner`, `ScriptRunner`, `PackFetcher`, `ClaudeIntegration` and `UpdateChecker`
against an async API, push `async` through `ParsableCommand.run()`, and require re-verifying the PTY
story — a rewrite of the process layer in the middle of a port, for no benefit to this goal. The
platforms list stays `[.macOS(.v13)]`; Linux needs no entry.

### D11 — One release, two artifacts

The release workflow builds the macOS universal binary and the Linux x86_64 binary in parallel and
publishes both from a single job, so one `SHA256SUMS` covers them and the Homebrew tap is updated
once. **Consequence: the release is now all-or-nothing across platforms** — a Linux build or test
failure blocks the macOS tarball, the GitHub release and the tap update, which could not happen
before. That is the intended trade (a half-published release is worse than a late one), but it is a
new way for a Linux problem to hold up macOS users, and it is why `test-linux` runs before
`build-linux` rather than after the release is cut.

### D12 — The home directory comes from `$HOME`, falling back to the passwd entry

**Context.** Every path mcs owns hangs off one home directory. corelibs Foundation's
`NSHomeDirectory()` reads the passwd entry and ignores `$HOME`; Darwin's honours it. So on Linux a
`HOME=… mcs …` invocation — what a container, a CI runner and `sudo -H` all set up — silently wrote
to the real user's `~/.claude`, `~/.mcs` and global gitignore.

**Options considered.** (a) Leave it and document the divergence. (b) Prefer a non-empty `$HOME`,
falling back to `NSHomeDirectory()`. (c) Route the two tilde-expansion sites through the same helper
as well.

**Decision: (b).** It is a no-op on macOS, where `NSHomeDirectory()` already prefers `$HOME`, and it
makes the two platforms agree. `Environment.defaultHomeDirectory(environment:)` takes the
environment as a parameter so it can be tested as a pure function — swift-testing runs in parallel,
so a test that called `setenv` would leak into every other test in flight. `Homebrew.allPrefixes`
uses the same helper, so the single-user Linuxbrew prefix cannot drift from it.

**Why not (c).** The two places that expand a tilde a *user* typed — a path given to `mcs pack add`
and a pack's doctor `path:` — go through Foundation's `expandingTildeInPath`, which has the same
divergence. Routing them through the helper means parsing `~`, `~/…` and `~user/…` at both sites,
i.e. a third shared helper and its own tests, for a case that only appears when `$HOME` disagrees
with the passwd home. The gap is listed under known limitations instead.

**Consequences.** One footnote on Darwin: `NSHomeDirectory()` consults `CFFIXED_USER_HOME` before
`$HOME`, while this helper checks `$HOME` first — they disagree only when both are set and differ,
which in practice means CoreFoundation's own test harnesses.

## 6. Known limitations

- **x86_64 only, by decision rather than by obstacle.** GitHub does offer `ubuntu-24.04-arm` and
  `ubuntu-22.04-arm` runners, so an aarch64 tarball is buildable today; it is deliberately left as a
  follow-up so this port does not widen into a second artifact, its own naming and its own smoke
  test.
- **glibc ≥ 2.35**, because the release binary is built on Ubuntu 22.04. musl is untested.
- **The binary is ~95 MB and needs `libstdc++6`.** `--static-swift-stdlib` links the *Swift* runtime
  statically only; `ldd` still shows `libstdc++.so.6`, `libgcc_s.so.1`, `libm`, `libc` and
  `ld-linux`. A minimal container needs `apt-get install -y libstdc++6`. A fully static binary would
  need the Static Linux SDK (musl), which would require a `canImport(Musl)` branch in every import
  chain and a musl verification pass.
- **`/usr/bin/which` is required**, with the "everything reports not found" symptom described in
  section 2.
- **No Linuxbrew auto-install**, and **no Claude Code auto-install** on Linux.
- **`brew:` components are name-sensitive** without Linuxbrew — see D8 decision 3.
- **`mcs export`'s brew formula hints are empty** without Linuxbrew: `detectFormula` reads symlinks
  under the Homebrew prefixes.
- **The PTY is allocated with a 0×0 window size** — the same on macOS, so full-screen TUIs run inside
  a `shellInteractive` component see no size. Line-oriented programs like `sudo` are unaffected.
- **Telemetry is removed on both platforms.** `mcs config set telemetry` now reports an unknown key,
  the first `config set` rewrites `config.yaml` without the stale line, and `~/.mcs/.telemetry-noticed`
  is left in place.
- **`techpack.yaml` cannot mark a component macOS-only.** A pack declaring `brew: mas` will run on
  Linux and fail that component with a clear message. See D8's rejected options.
- **A literal `~` in a user-supplied path ignores `$HOME` on Linux.** `mcs` resolves its own home
  through `Environment.defaultHomeDirectory()`, which prefers `$HOME`, but the two places that
  expand a tilde typed by a user — a path passed to `mcs pack add`, and a pack's doctor `path:` —
  go through Foundation's `expandingTildeInPath`, which reads the passwd entry on corelibs and the
  `$HOME` value on Darwin. This only shows up when `$HOME` differs from the passwd home, e.g. under
  `sudo -H` or in a container. Pass an absolute path there if you override `$HOME`.
- **The test suite runs serially on Linux (`swift test --no-parallel`).** corelibs Foundation opens
  files for writing without `O_CLOEXEC` — measured with `strace` on both its atomic path
  (`openat(…, ".dat.nosyncXXXX", O_RDWR|O_CREAT|O_EXCL, 0666)`) and its non-atomic one
  (`openat(…, "b.sh", O_WRONLY|O_CREAT|O_TRUNC, 0666)`) — so when one test forks a subprocess while
  another is mid-write, the child inherits that write descriptor and a later `exec` of the same file
  fails with `ETXTBSY`, surfacing as `NSCocoaErrorDomain 256`. Measured at about one failure in four
  full parallel runs. **mcs itself is unaffected**: it never executes a file it has just written.
  Since the leak is in Foundation rather than in mcs, there is no `open`-side fix available the way
  there was for the process lock, and the interfering forks come from unrelated suites, so marking
  one suite `.serialized` would not close it. The macOS jobs stay parallel.
- **Nothing is claimed about Fedora, Alpine or NixOS** — they are untested.

## 7. How to add a platform-specific path

The canonical shape, which the repo's `.swiftformat` (`--ifdef noindent`) leaves alone:

```swift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
```

Three rules keep this from spreading:

1. **Platform-dependent values and control flow live in five places only** —
   `Core/TerminalAttributes.swift`, `Core/Environment.swift`, `Core/Homebrew.swift`,
   `Core/Constants.swift` and `Core/ClaudePrerequisite.swift`. Everything else calls into them. If
   a sixth file needs a `#if` around a *value or a branch*, that is a sign it belongs in one of
   these. `ClaudePrerequisite` is on the list because what differs there is *control flow*, not a
   value: macOS offers a Homebrew install of Claude Code and Linux has no cask to offer, so there
   is no constant to move into `Constants`.
   The import chain above is the one `#if` this rule does not cover: a file that calls libc
   directly (`ShellRunner`, `CLIOutput`, `FileLock`, `GlobMatcher`, and `FileLockTests`) or picks
   the SHA-256 module (`FileHasher`, `SettingsHasher`, `SectionValidator`) carries it at the top,
   per D4. It selects the same API from a different module and encodes no platform behaviour.
2. **A `#if` is for a value or API that genuinely differs**, never for making a diagnostic go away.
   The same applies to `_ =`, `try?`, `@unchecked` and `nonisolated(unsafe)`: fix the cause. When a
   Foundation method is `@discardableResult` on Darwin and not on Linux, use the result — it always
   means something.
3. **Write the assertion for both platforms.** A test that is `#if`-gated out on one platform is a
   coverage regression; give the `#else` branch the equivalent assertion, as
   `TerminalAttributesTests` and `EnvironmentTests` do.
