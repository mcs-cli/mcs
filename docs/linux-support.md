# Linux support

`mcs` runs on macOS and on Linux (glibc). This document records what is verified, what differs
between the two platforms, and why each porting decision was made.

Sections 1–3 and 6 describe the platform. Section 4 is the per-feature compatibility checklist:
a row is filled in only after that feature has been **run** on Linux. Section 5 carries one
ADR-style entry per decision.

## 1. Status and supported configurations

*(Phase 10)*

## 2. Prerequisites

*(Phase 10)*

## 3. Install, build and test on Linux

*(Phase 10)*

## 4. Compatibility matrix

Legend: `verified` — run on Linux and observed; `pending` — not yet exercised.

| Feature | macOS | Linux | Notes |
|---|---|---|---|
| `mcs sync` (project) | supported | verified | `mcs sync --pack linux-probe` in a git project: components installed, `settings.local.json` composed, `CLAUDE.local.md` generated, `.mcs-project` written. |
| `mcs sync --global` | supported | verified | `mcs sync --global --pack git-probe`: artifacts under `~/.claude/`, `settings.json` composed, `global-state.json` written. |
| `--customize` raw-mode picker | supported | verified | Driven under a real PTY: `↓` moved the cursor, `Space` toggled, `Enter` applied; in-place redraw and cursor hide/show correct. |
| Non-TTY fallback picker | supported | verified | stdin a PTY, stdout a pipe: numeric toggle + `Enter`, colours disabled. |
| `shell:` components | supported | verified | `shell: touch <path>` created the marker. |
| `shellInteractive: true` (PTY/sudo) | supported | verified | `forkpty` path ran the command; marker file created. Also asserted by `LifecycleIntegrationTests`. |
| `brew:` components | supported | pending | |
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
| `mcs export` (incl. brew formula hints) | supported | verified | Exported `techpack.yaml`, hooks, skill, command, agent, settings and template from a live project. Brew hints empty without Linuxbrew. |
| `mcs cleanup` | supported | verified | Found and deleted a `CLAUDE.local.md.backup.*` file, with and without `--force`. |
| `mcs check-updates` + SessionStart hook | supported | verified | `check-updates`, `--json` and `--hook` all run; `mcs config set update-check-cli true` registered `mcs check-updates --hook` in `~/.claude/settings.json` and the cooldown file was written. |
| `mcs config` | supported | verified | `list` / `get` / `set` against `~/.mcs/config.yaml`. |
| File lock (`flock`) | supported | verified | Two concurrent syncs: the second exited 1 with "Another mcs process is running". |
| Lockfile (`mcs.lock.yaml`) | supported | verified | Written after sync with `generate-lockfile true`; `mcs sync --lock` consumed it. |
| Terminal colours / width | supported | verified | ANSI colour and the wrapped/re-rendered picker observed under a PTY; colours suppressed when stdout is a pipe. |
| Claude Code prerequisite | supported | pending | |
| Telemetry | removed | removed | Deleted outright — see ADR D1. |

## 5. Decisions (ADR entries)

*(Phase 10 — one entry per D1…D10)*

## 6. Known limitations

*(Phase 10)*

## 7. How to add a platform-specific path

*(Phase 10)*
