# Linux support

`mcs` runs on macOS and on Linux (glibc). This document records what is verified, what differs
between the two platforms, and why each porting decision was made.

Sections 1–3 and 6 describe the platform. Section 4 is the per-feature compatibility checklist:
a row is filled in only after that feature has been **run** on Linux. Section 5 carries one
ADR-style entry per decision.

## 1. Status and supported configurations

`mcs` is built and tested on **Linux with glibc**, on x86_64 and aarch64. Every feature works, and
section 4 records how each one was verified; a handful behave differently from macOS, and the matrix
says how.

| | |
|---|---|
| Architecture | x86_64 and aarch64, one release tarball each. |
| libc | glibc. musl is untested; there is no `canImport(Musl)` branch. |
| glibc floor | 2.35 — both binaries are built on Ubuntu 22.04. |
| Tested on | Ubuntu 24.04 (development); the `ubuntu-22.04` and `ubuntu-22.04-arm` GitHub runners in CI. |
| Other distributions | Any glibc ≥ 2.35 distribution is expected to work. **Nothing is claimed about Fedora, Alpine or NixOS** — they have not been tested. |

CI runs `swift build`, the full test suite and the release build on both Linux architectures for
every pull request, alongside the two macOS jobs. The `Linux Smoke` workflow (manual dispatch) runs
whole command flows against a real pack; it is what the matrix below rests on. Lint runs on macOS only: SwiftFormat and SwiftLint give the same verdicts on both, so a
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
already have. See ADR D8 for why this is documented rather than worked around.

Homebrew is **optional** on Linux. Without it, `brew:` components are verified through `PATH` only
and cannot be installed by mcs — see the `brew:` row in section 4 and ADR D7.

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
| Raw-mode pickers | supported | verified | Driven under a real PTY: `↓` moved the cursor, `Space` toggled, `Enter` applied; in-place redraw and cursor hide/show correct. A hangup mid-prompt answers No and warns rather than spinning. |
| Non-TTY fallback picker | supported | verified | stdin a PTY, stdout a pipe: numeric toggle + `Enter`, colours disabled. |
| `shell:` components | supported | verified | `shell: touch <path>` created the marker. |
| `shellInteractive: true` (PTY/sudo) | supported | verified | `forkpty` path ran the command; marker file created, with stdin from `/dev/null` and under a real controlling terminal. Also asserted by `LifecycleIntegrationTests`. The PTY is allocated with a default 0×0 window size on both platforms. |
| `brew:` components | supported | verified (with a difference) | Same predicate on both platforms. Without Linuxbrew a `brew:` component is satisfied only when the formula name is also the command name — `brew: node` passes with `node` on PATH, `brew: ripgrep` does not because the command is `rg`. Doctor then reports it missing, and `--fix` names the system package manager instead of pointing back at `mcs sync`. Installing a formula still needs Linuxbrew. |
| `mcp:` (`claude mcp add`) | supported | verified | `demo-server` registered via `claude mcp add -s local`; `claude mcp list` shows it; removal deregisters it. |
| `plugin:` | supported | verified | `hookify@claude-code-plugins` installed through `claude plugin install`; `claude plugin list` shows it enabled. |
| `hook:` / `command:` / `skill:` / `agent:` copies | supported | verified | All four installed; hooks namespaced under `<pack-id>/`; interpreter inferred (`bash` for `.sh`, `python3` for `.py`). |
| `settingsFile:` | supported | verified | Deep-merged into `settings.local.json` with `__GREETING__` substituted. |
| `gitignore:` | supported | verified | Entry added to `~/.config/git/ignore`; reference counting kept it when one of two scopes was removed. |
| `mcs update` | supported | verified | `mcs update --project --trust-all` re-fetched the pack and re-applied the scope. |
| `mcs doctor` | supported | verified | 20 checks across every section; `✓`/`⚠` rendering correct. |
| `mcs doctor --fix` | supported | verified | Deleting `.claude` from the global gitignore then `doctor --fix` re-added it (`GitignoreCheck.fix`). |
| `mcs pack add` (git) | supported | verified | `mcs pack add git://…/gitprobe` cloned, prompted for trust, registered. |
| `mcs pack add` (local) | supported | verified | `mcs pack add <dir>` registered in place with `commitSHA: local`. |
| `mcs pack remove` / `list` / `update` / `validate` | supported | verified | `remove` unconfigured every affected scope; `update` reported "already up to date"; `validate` produced the python3 heuristic warning. |
| Pack trust hashing | supported | verified | Trust prompt shown on add for both a local and a git pack; re-validated on `pack update` (SHA-256 now from swift-crypto). |
| `mcs export` (incl. brew formula hints) | supported | verified (with a difference) | Exported `techpack.yaml`, hooks, skill, command, agent, settings and template from a live project. The brew formula hints are empty without Linuxbrew — `detectFormula` reads symlinks under the Linuxbrew prefixes. |
| `mcs cleanup` | supported | verified | Found and deleted a `CLAUDE.local.md.backup.*` file, with and without `--force`. |
| `mcs check-updates` + SessionStart hook | supported | verified (with a difference) | `check-updates`, `--json` and `--hook` all run; `mcs config set update-check true` registered `mcs check-updates --hook` in `~/.claude/settings.json` and the cooldown file was written. The upgrade command differs: `brew upgrade` on macOS, a staged tarball swap on Linux — see ADR D12. |
| `mcs config` | supported | verified | `list` / `get` / `set` against `~/.mcs/config.yaml`. |
| `$HOME` override | supported (behavior change) | verified | `mcs` resolves its home from `$HOME`, falling back to the passwd entry, on both platforms — including a `~` typed in a pack path or a pack's doctor `path:`. Previously `$HOME` was ignored everywhere (ADR D11). |
| File lock (`flock`) | supported | verified | Two concurrent syncs: the second exited 1 with "Another mcs process is running". |
| Terminal colours / width | supported | verified | ANSI colour and the wrapped/re-rendered picker observed under a PTY; colours suppressed when stdout is a pipe. |
| Claude Code prerequisite | supported | verified (with a difference) | With `claude` off PATH, Linux prints the native-installer and npm commands and returns false. macOS still offers the Homebrew install; `claude-code` is a cask and Linuxbrew has no casks. |
| Release artifact | `.tar.gz` (universal) | verified (with a difference) | `swift build -c release --static-swift-stdlib` produces one ~95 MB binary per architecture; each tarball holds exactly one file and `./mcs --version` prints the version. `ldd` still shows `libstdc++.so.6`, `libgcc_s.so.1`, `libm`, `libc` and `ld-linux`. |

## 5. Decisions (ADR entries)

Each entry records the context, the options considered, the decision, and what it costs.

### D1 — swift-crypto supplies SHA-256 on both platforms

**Context.** Three files hash with `SHA256.hash(data:)`. CryptoKit is Apple-only, so Linux needs
another source for the digest.

**Options considered.** (a) An unconditional swift-crypto dependency and `import Crypto` everywhere.
(b) A Linux-only *target* dependency plus a `#if canImport(CryptoKit)` import shim in each file.
(c) Hand-roll SHA-256. (d) Shell out to `sha256sum`.

**Decision: (a).**

```swift
.product(name: "Crypto", package: "swift-crypto")
```

On Apple platforms swift-crypto compiles its API surface down to nothing and re-exports CryptoKit, so
`import Crypto` *is* CryptoKit there: same implementation, bit-identical digests for the hashes
persisted in `.mcs-project`. Its manifest gates `CCryptoBoringSSL` and friends on non-Darwin
platforms, so the 13 MB C library is not compiled on macOS either. What (a) buys over (b) is that
four files lose a conditional-import block and the platform rule loses a clause.

**Why not (c)/(d).** Hand-rolled crypto is a maintenance liability even for a hash; shelling out
costs a process per file and makes `FileHasher` untestable offline.

**Consequences.** `swift package resolve` fetches **two** more repositories on macOS — swift-crypto
and its transitive `swift-asn1`. The CI cache key is `hashFiles('Package.swift')`, so that is paid
once per manifest change. `Package.resolved` is gitignored, so `from: "3.0.0"` floats across 3.x —
the same exposure the two existing dependencies already have. SwiftPM does emit a
`swift-crypto_Crypto.bundle` beside the release binary, holding only `PrivacyInfo.xcprivacy`; the
release tarball still ships the single `mcs` file, and a binary copied away from that bundle runs
`--version`, `pack validate` (which hashes) and `doctor` unchanged — verified before choosing (a).
`FileHasherTests` and `SettingsHasherTests` each pin a known digest, so a divergence between the two
implementations fails the suite instead of silently invalidating state files.

### D2 — `Locked<Value>` replaces `OSAllocatedUnfairLock`

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

### D3 — Platform imports are an explicit `#if canImport` chain, per file

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
SwiftGlibc — see D4. No `canImport(Musl)` branch is added: nothing here builds for musl, and an
untested branch is worse than no branch.

**Consequence beyond the imports.** Two Foundation methods — `fileExists(atPath:isDirectory:)` and
`createFile(atPath:contents:)` — are `@discardableResult` on Darwin and not on Linux, so their
results had to be used rather than dropped, at four call sites. Three now require the file to exist
before treating it as a directory: identical in practice, and now defined, where Apple documents
`isDirectory` as undefined for a missing path. The fourth is a small
**macOS-visible change**: `GitignoreManager`'s bootstrap used `createFile(atPath:contents:)`, whose
`false` return was ignored, and now writes through `Data` — so a failure to create the global
gitignore throws out of `ensureFileExists()` instead of passing silently and failing later at the
read.

### D4 — `forkpty()` is called from Glibc; no C shim, no `posix_openpt` rewrite

**Context.** `ShellRunner.runInteractive` allocates a real PTY so `sudo` can read a password. The
open question was whether SwiftGlibc exposes `forkpty`.

**Decision: it does.** `pty.h` is in `SwiftGlibc.h.gyb`, the Glibc modulemap declares `link "util"`,
and the call links and runs on glibc 2.39 with no extra linker flag. `cfmakeraw` is exposed too.

**Why not the alternatives.** A C shim or `@_silgen_name` would work around a declaration that is
not missing; reimplementing with `posix_openpt`/`grantpt`/`setsid`/`ioctl(TIOCSCTTY)` duplicates
forty lines of subtle libc behaviour for no benefit.

**Consequences.** One real difference did surface inside the fork child: glibc declares the
`execve` and `chdir` parameters `__nonnull`, so Swift imports them as non-optional and rejects the
`Optional` element of the `argv` array that Darwin's unannotated signatures accept (`strdup` itself
imports as an implicitly unwrapped optional on both). A force-unwrap there would trap through the
Swift runtime after `fork()`, where only async-signal-safe calls are legal, so every C string the
child needs is allocated and checked in the parent. If a future toolchain drops `pty.h` the build fails
immediately and the C shim remains a ~15-line fallback.

### D5 — termios: index `c_cc` through `VMIN`/`VTIME`, widen masks through `tcflag_t`

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

### D6 — `TIOCGWINSZ` widens to `UInt`

`TIOCGWINSZ` imports as `Int32` on Glibc and `UInt` on Darwin, and `ioctl` takes a `UInt` request on
both. `ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)` compiles everywhere and is a no-op conversion on
Darwin, so no `#if` is needed. In the same file `Darwin.read(...)` loses its module qualifier:
unqualified `read` resolves to libc on both platforms, because `CLIOutput` has a `write` member but
no `read` member.

### D7 — Homebrew on Linux

**Context.** mcs resolves a Homebrew prefix, puts its `bin` on the PATH it hands to subprocesses,
and verifies `brew:` components. Linuxbrew installs at `/home/linuxbrew/.linuxbrew`, and most Linux
users have no Homebrew at all.

**Decisions.**

1. **The prefix derivation resolves symlinks, then strips a trailing `Homebrew` component.**
   Homebrew's installer creates `$PREFIX/bin/brew -> ../Homebrew/bin/brew` on Linux *and on Intel
   macOS*; only arm64 macOS has a real file there. Resolving alone therefore yields the repository
   checkout, `$PREFIX/Homebrew`, whose `bin` holds only `brew`, and `pathWithBrew` prepended that
   useless directory. Not resolving at all would instead break a shim — `~/.local/bin/brew` pointing
   at the real install with `$PREFIX/bin` off PATH — by reporting the shim's directory as the prefix.
   Resolve-then-strip handles arm64, Intel, Linuxbrew and shims alike. `brewPrefix` feeds only
   `pathWithBrew`; formula detection walks `Homebrew.allPrefixes`.
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

### D8 — `/usr/bin/which` stays, documented as a prerequisite

**Context.** `ShellRunner.resolvedPath` and `Environment.resolveCommand` shell out to
`/usr/bin/which`. It is present on Ubuntu 24.04, absent on NixOS, and Debian has been retiring it.

**Options considered.** (a) Keep it and document it. (b) Replace it with an in-process PATH scan.
(c) Keep it and add a `mcs doctor` check that fails loudly when it is missing.

**Decision: (a).** (b) widens a portability PR with a behaviour change to a hot path shared by every
command. (c) sounds small but is not: `FileExistsCheck.fix()` returns "Run 'mcs sync' to install",
which is exactly the dead-end message decision D7.4 removes, so it would need a new parameter; the
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

### D9 — No Subprocess 1.0, no tools-version bump, macOS 13 floor stays

swift-tools-version 6.0 already supports `.product(…, condition: .when(platforms:))`, and
swift-crypto is tools-version 5.9 / macOS 10.15, so nothing forces a bump. Adopting Subprocess 1.0
would rewrite `ShellRunner`, `ScriptRunner`, `PackFetcher`, `ClaudeIntegration` and `UpdateChecker`
against an async API, push `async` through `ParsableCommand.run()`, and require re-verifying the PTY
story — a rewrite of the process layer in the middle of a port, for no benefit to this goal. The
platforms list stays `[.macOS(.v13)]`; Linux needs no entry. Raising the floor to macOS 15 would let
`Synchronization.Mutex` replace `Locked` (see D2), but that drops macOS 13 and 14 users, so it is a
separate decision rather than a side effect of this port.

### D10 — One release, three artifacts

The release workflow builds the macOS universal binary and both Linux binaries in parallel and
publishes them from a single `release` job, so one `SHA256SUMS` covers all three and the Homebrew tap
is updated once. The tap formula keeps pointing at the macOS tarball; Linux ships as plain release
assets, because Linuxbrew is not how a Linux user is expected to install mcs.
**Consequence: the release is now all-or-nothing across platforms** — a Linux build or test failure
blocks the macOS tarball, the GitHub release and the tap update, which could not happen before. That
is the intended trade (a half-published release is worse than a late one), and it is why `test-linux`
runs before `build-linux` rather than after the release is cut.

### D11 — The home directory comes from `$HOME`, falling back to the passwd entry

**Context.** Every path mcs owns hangs off one home directory. Foundation's `NSHomeDirectory()`
resolves the passwd entry first on Darwin and corelibs alike, and consults `$HOME` only when there
is no passwd entry (`CFFIXED_USER_HOME`, when set, replaces both). So on *every* platform a
`HOME=… mcs …` invocation — what a container, a CI runner and `sudo -H` all set up — silently wrote
to the real user's `~/.claude`, `~/.mcs` and global gitignore. Verified on macOS with a compiled
probe: `HOME=/tmp/x` still returned the passwd home.

**Options considered.** (a) Leave it and document it. (b) Prefer a non-empty `$HOME`, falling back
to `NSHomeDirectory()`. (c) Also route the two tilde-expansion sites through the same home.

**Decision: (b) and (c).** This is a deliberate behavior change on macOS as much as on Linux: an
invocation whose `$HOME` differs from the passwd home — `sudo` with `env_keep`, a launchd agent, a
sandboxed test — now reads and writes under `$HOME`. `Environment.defaultHomeDirectory(environment:)`
takes the environment as a parameter so it can be tested as a pure function — swift-testing runs in
parallel, so a test that called `setenv` would leak into every other test in flight.
`Homebrew.allPrefixes` uses the same helper, so the single-user Linuxbrew prefix cannot drift from
it. The two places that expand a tilde a *user* typed — a path given to `mcs pack add`, and a pack's
doctor `path:` — go through `Environment.expandingTilde(_:)` rather than Foundation's
`expandingTildeInPath`, so `~/pack` and `~/.mcs` can never name different homes.

**Consequences.** `HOME=<dir> mcs …` is now a working sandbox for the whole binary. A `$HOME` that
points at a missing directory is not validated; `mcs sync --global` creates the tree, `mcs doctor`
reports everything under it as missing with the path shown. `~user/…` is not expanded — neither
site ever accepted it.


### D12 — The Linux upgrade command is a staged, verified tarball swap

**Context.** The SessionStart hook tells Claude what to run if the user agrees to update. On macOS
that is `brew update && brew upgrade mcs-cli/tap/mcs`. Linux installs from a release tarball, so
there is no package manager to delegate to, and a CLI-only update would otherwise render an empty
`On yes, run:`.

**Options considered.** (a) Emit no command and describe the tarball in prose. (b) Emit a command
built from the binary's own path. (c) Suppress CLI update checks on Linux entirely.

**Decision: (b).** `UpdateChecker.cliUpgradeCommands(toVersion:)` reads `/proc/self/exe` — the
kernel's answer, not `argv[0]`, which a caller controls — and builds one command that downloads the
tagged asset for `releaseArch`, writes the tarball member to a *sibling* temp file, runs `--version`
on it, and only then `mv`s it over the target. The rename is same-directory, so it is atomic and
legal while the old binary is still mapped. `sudo sh -c` wraps it only when the directory is not
writable, which keeps the binary's ownership in the common case.

**Why not (a).** Claude is the one running these commands; handing it prose where every other update
is a command makes the CLI update the odd one out and easy to skip.

**Why not (c).** A Linux user would never learn a new version exists.

**Consequences.** When the path cannot be resolved the function returns `[]`, and the hook then names
the releases page and asks no question at all — the ask is gated on having something to run. A
truncated download fails `--version` before anything is replaced. The command is only as correct as
the asset naming in `release.yml`, so `build-linux` fails the job if the runner's `uname -m` and the
asset's architecture disagree.
## 6. Known limitations

- **glibc ≥ 2.35**, because both release binaries are built on Ubuntu 22.04. musl is untested, and
  there is no `canImport(Musl)` branch.
- **The binary is ~95 MB and needs `libstdc++6`.** `--static-swift-stdlib` links the *Swift* runtime
  statically only; `ldd` still shows `libstdc++.so.6`, `libgcc_s.so.1`, `libm`, `libc` and
  `ld-linux`. A minimal container needs `apt-get install -y libstdc++6`. A fully static binary would
  need the Static Linux SDK (musl), which would require a `canImport(Musl)` branch in every import
  chain and a musl verification pass.
- **`/usr/bin/which` is required**, with the "everything reports not found" symptom described in
  section 2.
- **No Linuxbrew auto-install**, and **no Claude Code auto-install** on Linux.
- **`brew:` components are name-sensitive** without Linuxbrew — see D7 decision 3.
- **A `.zsh` hook's missing interpreter is not reported on Linux.** `HookInterpreter` treats `zsh`
  as always present, which is true on macOS and false on Debian, Ubuntu and Fedora by default. Packs
  that ship zsh hooks should say so; a per-platform set was not worth a sixth home for platform
  knowledge.
- **`mcs export`'s brew formula hints are empty** without Linuxbrew: `detectFormula` reads symlinks
  under the Homebrew prefixes.
- **The PTY is allocated with a 0×0 window size** — the same on macOS, so full-screen TUIs run inside
  a `shellInteractive` component see no size. Line-oriented programs like `sudo` are unaffected.
- **`techpack.yaml` cannot mark a component macOS-only.** A pack declaring `brew: mas` will run on
  Linux and fail that component with a clear message. See D7's rejected options.
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

1. **Platform-dependent values and control flow live in six places only** —
   `Core/TerminalAttributes.swift`, `Core/Environment.swift`, `Core/Homebrew.swift`,
   `Core/Constants.swift`, `Core/ClaudePrerequisite.swift` and `Core/UpdateChecker.swift`.
   Everything else calls into them. If a seventh file needs a `#if` around a *value or a branch*,
   that is a sign it belongs in one of these. `TerminalAttributes` is on the list without holding a
   single `#if`: it owns the termios layout, which differs through `VMIN`/`VTIME`/`tcflag_t` rather
   than through a branch. `ClaudePrerequisite` and `UpdateChecker` are on it because what differs
   there is *control flow*, not a value: macOS can offer a Homebrew install of Claude Code and a
   `brew upgrade` of mcs itself, Linux can do neither, so there is no constant to move.
   The import chain above is the one `#if` this rule does not cover: a file that calls libc
   directly (`ShellRunner`, `PTYBridge`, `CLIOutput`, `FileLock`, `GlobMatcher`, and
   `FileLockTests`) carries it at the top, per D3. It selects the same API from a different module
   and encodes no platform behaviour. SHA-256 needs no `#if` at all — swift-crypto's `Crypto` serves
   both platforms, per D1.
2. **A `#if` is for a value or API that genuinely differs**, never for making a diagnostic go away.
   The same applies to `_ =`, `try?`, `@unchecked` and `nonisolated(unsafe)`: fix the cause. When a
   Foundation method is `@discardableResult` on Darwin and not on Linux, use the result — it always
   means something.
3. **Write the assertion for both platforms.** A test that is `#if`-gated out on one platform is a
   coverage regression; give the `#else` branch the equivalent assertion, as
   `TerminalAttributesTests` and `EnvironmentTests` do.
