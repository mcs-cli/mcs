# CLI Reference

Complete command reference for `mcs`. For a quick introduction, see the [README](../README.md#-quick-start).

## `mcs sync`

The primary command. Configures a project by selecting packs and installing their artifacts. Running without flags opens interactive multi-select.

```bash
mcs sync [path]                  # Interactive project sync (default command)
mcs sync --pack <name>           # Non-interactive: add/update specific pack(s), keeping the rest (repeatable)
mcs sync --pack <name> --prune   # Make the named pack(s) the exact set — removes the rest after confirmation
mcs sync --all                   # Apply all registered packs without prompts
mcs sync --dry-run               # Preview what would change
mcs sync --global                # Install to global scope (~/.claude/)
```

| Flag | Description |
|------|-------------|
| `[path]` | Project directory (defaults to current directory) |
| `-p, --pack <name>` | Add or update a specific pack non-interactively. Repeatable for multiple packs. Packs already configured in the scope are kept. |
| `-a, --all` | Apply all registered packs without interactive selection. |
| `--prune` | With `--pack`: remove configured packs not named with `--pack`. Prompts before removing unless `--yes` is passed. |
| `-y, --yes` | Skip the removal-confirmation prompt. Only meaningful with `--prune`. |
| `--dry-run` | Preview changes without writing any files. |
| `-g, --global` | Sync global-scope components (brew packages, plugins, MCP servers to `~/.claude/`). |

`mcs sync` is also the default command — running `mcs` alone is equivalent to `mcs sync`.

A selected pack always installs every component it declares. Components that an older release's `--customize` excluded are installed on the next sync, which names them before installing them.

**Pack scopes.** A pack can declare which scopes it supports (`scopes:` in `techpack.yaml`). Naming one with `--pack` for a scope it doesn't support fails before anything changes, and `--dry-run` exits non-zero the same way. `--all` skips such packs with a warning, and the interactive picker lists them as not available. A pack that was already installed there before it declared `scopes:` is kept and re-applied; `mcs doctor` warns about it.

**`--pack` is additive.** Naming a pack adds or updates it and leaves every other configured pack in place; a footer lists the packs that were kept. A configured pack that is missing from the registry stops the run rather than being removed — re-add it with `mcs pack add`, or pass `--prune` to remove it. With `--prune`, the named packs become the exact set, matching `mcs bootstrap --prune`.

## `mcs bootstrap`

Apply a declarative `mcs.yaml` from the current directory. Bootstrap installs any packs the file declares, seeds prompt values, and syncs each pack into the scope it routes to — the current project or `~/.claude/`.

```bash
mcs bootstrap                    # Read ./mcs.yaml, install declared packs, keep any others
mcs bootstrap --prune            # Also remove project packs absent from mcs.yaml
mcs bootstrap --dry-run          # Preview what would change
mcs bootstrap --prune --yes      # Prune without the removal-confirmation prompt (CI)
mcs bootstrap --trust-all        # Trust declared packs without prompting
```

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview without making changes. For un-registered packs, prints `would fetch <source>@<ref>` without cloning. |
| `--prune` | Remove project packs absent from `mcs.yaml`. In a file whose own `scope` is `global`, remove the global packs this file installed and no longer lists — never packs you or another file installed. Prompts once before removing unless `--yes` is passed. |
| `-y, --yes` | Skip the removal-confirmation prompt. Only meaningful with `--prune`. |
| `--trust-all` | Approve each declared pack's executable content without prompting, so the trust prompts need no TTY. Other prompts are unaffected — see `--yes` for removals and `values:` for pack prompts. No-op with `--dry-run`, which returns before any pack is fetched. |

**File format (`./mcs.yaml`)**

```yaml
schemaVersion: 2                     # 1 also works for files without a file-level `scope`
# scope: global                      # optional: default scope for every entry (see below)
packs:
  - source: mcs-cli/dev              # git URL, GitHub shorthand, or local path
    ref: main                        # optional (git only): tag, branch, or full commit SHA
    values:                          # optional: seeds prompt priors
      BRANCH_PREFIX: feature
  - source: mcs-cli/memory
    scope: global                    # optional: install this one into ~/.claude/
```

- `source` is required. `ref`, `values`, and `scope` are optional.
- `values` seeds the `resolvedValues` of the scope the entry routes to, so the keys it covers do not re-prompt. A key counts when a declared pack declares it as a prompt or references it as a `__KEY__` placeholder in a file, template, settings file, or MCP config. A key that matches neither is ignored with a warning (usually a typo). Any key not seeded here falls through to normal resolution.
- `scope` is `project` or `global`, per entry or once for the whole file. A file-level `scope` needs `schemaVersion: 2`, so an older mcs refuses the file instead of ignoring the key and installing everything into the current directory.

**Scope routing**

Each declared pack goes to its entry's `scope`, else the file's `scope`, else `project`. Only the file decides placement — reading `mcs.yaml` tells you everything that touches `~/.claude/`. A pack's own [`scopes:`](techpack-schema.md#the-scopes-field) never moves it; it only says where it is allowed.

- **Routing must match the pack.** Sending a pack to a scope its `scopes:` excludes fails before anything changes in either scope, naming the entry to fix (for a global-only pack: add `scope: global` to it). Bootstrap re-asserts the file on every run, so this holds even for a pack that narrowed its `scopes:` after it was installed — unlike `mcs update`, which keeps re-applying such a pack and leaves the warning to `mcs doctor`.
- **Checked together, applied in order.** Both scopes are checked first — a mismatch, an unanswerable prompt or a duplicate stops the run before either changes — then global converges, then the project. A failure while applying the project can still leave global already updated.
- **Global changes are shown, not gated.** The plan prints a separate *Sync Global* block noting that it affects every project on the machine. Trust approves a pack's *content*, not where it goes: a pack whose content you already trusted is not prompted again because a file now places it globally, and placement comes from the committed `mcs.yaml`. New or changed executable content still hits the trust prompt (or `--trust-all`).
- **A file whose `scope` is `global` is machine-only.** The current directory is not treated as a project: nothing is written under it, it is not added to `~/.mcs/projects.yaml`, and it may be `$HOME`. A `scope: project` entry in such a file is an error. Use this for an org config repo applied on every machine.
- **No duplicates.** A pack routed to global that this project already configures is an error; with `--prune` it is moved (removed from the project, installed globally). A pack routed to the project that is already installed globally is skipped with a warning, since the global copy already applies.

**Semantics**

- Like `mcs sync`, bootstrap refreshes the shared user-level update-check hook in `~/.claude/settings.json` on non-dry-run runs — that hook is per-user, not per-project.
- **Additive by default.** Packs listed in `mcs.yaml` are installed / updated; any pack configured in a scope but not listed is preserved. After sync, a note lists the project extras, and the global packs this file installed but no longer lists, so the divergence stays visible.
- **`--prune` opts into authoritative mode.** With `--prune`, `mcs.yaml` becomes the exact desired set for the project — extras are unconfigured. In global scope a file only owns what it installed: bootstrap records each global pack's owners (the user, and every `mcs.yaml` that declared it, identified by its repo remote and path, or its absolute path outside a repo). A `--prune` from a file whose own `scope` is `global` drops that file's claim on packs it no longer lists, and removes a pack only when no owner is left — so your own global packs and packs another file installed are never removed. A file that is not `scope: global` never removes a global pack: once it stops listing one, it drops its claim on every run (even after it lists no global entries at all), and a pack it was the only owner of becomes yours — it stays installed, and no file will prune it. One confirmation lists what will be removed in every scope (skip with `--yes`).
- **Renaming or moving a config repo stops its cleanup.** A file's identity is its repo's remote URL plus the path of `mcs.yaml` inside it — compared exactly apart from the host's letter case, so `Org/Config` and `org/config` are different owners. Rename or move the repo, change its remote, or move the file, and the new identity is a different owner: the packs the old one installed keep the old claim, so a later `--prune` never removes them — even ones the new file still lists and later retires. Nothing is deleted by mistake, but retired packs quietly stay on engineers' machines. When you rename the config repo, plan a manual cleanup: on each machine remove packs the file no longer lists with `mcs pack remove <pack>`, or deselect them in `mcs sync --global`.
- **One status line per pack.** After reconciling the registry, bootstrap prints `<source>: added`, `moved to <ref>`, `updated`, `unchanged`, or `failed` — one line per entry that ran, keyed by the entry's `source`, including the one that failed.
- **Idempotent.** Re-running converges — no work if nothing changed, and an unchanged `CLAUDE.md` / `CLAUDE.local.md` is neither rewritten nor backed up, so a scheduled run does not pile up backups.
- **Missing checkouts are restored.** A git pack still in the registry whose `~/.mcs/packs/` checkout was deleted is re-cloned at its recorded `ref` (or the declared one, when `mcs.yaml` changes it), with the usual trust check.
- **Fail fast.** A fetch, validate, trust, or sync error stops bootstrap immediately with the failing pack and reason. When bootstrap aborts partway through, an epilogue lists which packs already registered — re-run after fixing the failing entry to continue.
- **Trust prompts need a TTY unless `--trust-all` is passed.** Both trust surfaces bootstrap can reach — adding a pack it has never seen, and advancing a pack's `ref:` to a revision with changed scripts — end at an interactive confirmation. Without a terminal that confirmation reads as "no" and bootstrap aborts, so any unattended run against a fresh pack needs `--trust-all`.
- **`--trust-all` grants code execution without review.** It approves everything the declared packs can execute: install shell commands, MCP servers, hook files and the interpreters they run under, command files, configure and prompt scripts, and doctor check/fix commands. All run with your privileges; hooks and MCP servers run on every Claude Code session. Brew packages and plugins are outside the trust surface entirely, with or without this flag — see [Architecture](architecture.md) for that boundary. Each auto-trusted pack logs a warning naming what it was granted, and the approval persists: `~/.mcs/registry.yaml` records the hashes, so later interactive runs treat that content as reviewed. Point `mcs.yaml` at sources you control or have already reviewed, and pin `ref:` so the content a run trusts is not a moving target: a full commit SHA cannot move, a tag can be re-pointed, a branch moves on every push.

**Scheduled runs**

A file with `scope: global` in an org config repo, pulled and re-applied by a scheduled job (launchd, cron), keeps every machine on the same reviewed pack revision:

- **Pin `ref` to a full commit SHA.** Tags and branches can be moved by anyone who can push to the pack repo; a SHA cannot. Fetching by SHA needs the git server to allow it (GitHub and GitLab do; a self-hosted server needs protocol v2 or `uploadpack.allowReachableSHA1InWant`); if it refuses, the error says so — pin a tag instead. Abbreviated SHAs are not supported.
- **`--trust-all` in a scheduled job lets whoever can merge to the config repo run code on every machine that pulls it.** Protect that repo's default branch accordingly.
- **Give the job a `PATH` that includes Homebrew** (`/opt/homebrew/bin` on Apple silicon, `/usr/local/bin` on Intel). launchd starts with a minimal `PATH`, and bootstrap runs `git`, `claude`, and `brew`.
- **Exit status 75 means "try again later".** `mcs sync`, `bootstrap`, `update`, `doctor --fix`, `cleanup`, and `pack add` / `remove` / `update` take a machine-wide lock; `--dry-run` runs and every other command skip it. When another `mcs` process holds it, a locking command exits 75 (`EX_TEMPFAIL`) and prints a line starting with `mcs: lock held:` on stderr. Any other non-zero status is a real failure.
- **A repeated run is a no-op.** Nothing is rewritten and no backups are created when nothing changed.
- **`--prune` retires only what the file installed.** A scheduled `mcs bootstrap --prune --yes` removes a global pack once the file stops listing it and no other owner remains; packs engineers installed themselves are never touched. Renaming or moving the config repo resets that ownership — see `--prune` above for the manual cleanup it needs.

**Duplicate identifier handling**

| Existing entry | New entry | Behaviour |
|---|---|---|
| Same `sourceURL` + same `ref` | matches file | silent no-op |
| Same `sourceURL` + different `ref` | matches file | `PackUpdater` moves the checkout |
| Different `sourceURL` | matches file | auto-replace with warning naming both URLs |

**Dry-run limitation**

`--dry-run` cannot fully preview a sync for a pack that has not yet been fetched — v1 prints the intended add operation without cloning. Fetch-and-preview is planned for a future release.

## `mcs update`

Refresh already-configured packs across every scope they're installed in. Fetches the latest pack contents (with trust verification) and re-applies the existing pack set in both the global scope and the current project's scope. A git pack whose local checkout was deleted is re-cloned at its recorded `ref`.

```bash
mcs update                       # Refresh all configured packs in every scope (global + current project)
mcs update --global              # Only refresh the global scope
mcs update --project             # Only refresh the current project's scope
mcs update --all-projects        # Refresh global + every project in the index (machine-wide)
mcs update --dry-run             # Preview without making changes
mcs update --trust-all           # Trust changed executable content without prompting (no TTY required)
```

| Flag | Description |
|------|-------------|
| `[path]` | Project directory (defaults to current directory) |
| `-g, --global` | Only refresh the global scope. Mutually exclusive with `--project` and `--all-projects`. |
| `-p, --project` | Only refresh the current project's scope. Mutually exclusive with `--global` and `--all-projects`. |
| `-a, --all-projects` | Refresh the global scope plus every project tracked in `~/.mcs/projects.yaml`. Asks for confirmation in interactive mode and lists the affected projects first. Mutually exclusive with `--global` and `--project`. |
| `--dry-run` | Preview changes without writing any files. |
| `--trust-all` | Approve each updated pack's new or changed executable content without prompting, so the trust prompt needs no TTY. Other prompts are unaffected. No-op with `--dry-run`, which returns before any pack is fetched. Grants code execution without review, and the approval persists — see the [`--trust-all` caveat](#mcs-bootstrap) under `mcs bootstrap`. |

`mcs update` always refreshes the full configured set of every selected scope. To advance a single pack's registry pointer without applying anywhere, use [`mcs pack update <name>`](#mcs-pack-update-name).

**About `--all-projects`:** this fans out machine-wide, running each pack's `configureProject` hook with the corresponding project as cwd. Uncommitted changes in those projects to managed files (settings, hooks, skills) may be overwritten. Always interactive-confirm in a terminal; pair with `--dry-run` first if unsure.

**Differences from `mcs sync`:**

- **Refresh-only** — does not add or remove packs. Use `mcs sync` to change the configured set.
- **Multi-scope by default** — when configured packs exist in both global and project scopes, both are refreshed in one command (this was the original pain point that motivated the verb).

**Trust prompts:** when a pack's executable content has changed, `mcs update` prompts for trust. Denying the prompt skips the pack for this run (the registry stays at the old SHA, and the pack is excluded from re-apply so untrusted scripts don't auto-install). The prompt re-fires on the next `mcs update` run. Without a terminal the prompt reads as "no", so an unattended run needs `--trust-all` to take updates that change a pack's executable content. An unattended run that tracks a branch trusts whatever that branch next contains; pin packs to a tag (`mcs pack add <url> --ref <tag>`) where that matters.

**Prompt value reuse:** unlike `mcs sync`, `mcs update` does not show the interactive *"Reuse these values? [Y/n]"* gate when a pack's prompts already have stored answers. Refresh implies "keep what I have," so existing values are reused silently. **New** prompts introduced by a pack update still execute normally. To revisit stored values, use `mcs sync` (answer "No" at the gate to re-enter values one by one, with the existing answer as the default).

**Exit status:** a hard failure (failed fetch, unreadable checkout, invalid fetched manifest) exits non-zero when running non-interactively (CI), or when *every* attempted pack failed — so a transient outage in CI is a detectable failure, not a silent zero exit. In an interactive terminal a partial failure exits zero (the per-pack warnings are visible); the packs that updated cleanly are still re-applied first. A declined trust prompt is **not** a failure and always exits zero (it re-prompts next run).

## `mcs pack`

Manage registered tech packs.

### `mcs pack add <source>`

Add a tech pack from a git URL, GitHub shorthand, or local path.

```bash
mcs pack add <source>            # Git URL, GitHub shorthand, or local path
mcs pack add user/repo           # GitHub shorthand → https://github.com/user/repo.git
mcs pack add /path/to/pack       # Local pack (read in-place, no clone)
mcs pack add <url> --ref <tag>   # Pin to a tag, branch, or full commit SHA
mcs pack add <url> --preview     # Preview pack contents without installing
```

| Flag | Description |
|------|-------------|
| `-r, --ref <tag>` | Pin to a git tag, branch, or full 40-character commit SHA (git packs only). A SHA is the only ref that cannot move, so prefer it for unattended runs. Abbreviated SHAs are not supported. |
| `-p, --preview` | Preview the pack's contents without installing. |

Source resolution order: URL schemes → filesystem paths → GitHub shorthand.

### `mcs pack remove <name>`

Remove a registered pack.

```bash
mcs pack remove <name>           # Remove with confirmation
mcs pack remove <name> --force   # Remove without confirmation
```

| Flag | Description |
|------|-------------|
| `-f, --force` | Skip the confirmation prompt. |

Removal is federated: `mcs` discovers all projects using the pack (via the project index) and runs convergence cleanup for each scope.

### `mcs pack list`

```bash
mcs pack list                    # List registered packs with status
mcs pack list --json             # Machine-readable JSON output
```

| Flag | Description |
|------|-------------|
| `--json` | Print the registered packs as a JSON array instead of human-readable text. |

With `--json`, each array element has these fields:

| Field | Type | Description |
|-------|------|-------------|
| `identifier` | string | Pack identifier. |
| `source` | string | Git clone URL, or the original path for a local pack. |
| `ref` | string or `null` | Tag, branch, or commit SHA as declared with `--ref`; `null` when none was given (always for local packs). |
| `commitSHA` | string | Checked-out commit, or `"local"` for a local pack. |
| `isLocal` | boolean | Whether the pack is read in-place from a local path. |
| `status` | string | `"ok"`, `"missing"` (checkout or local directory not on disk), or `"invalid"` (path escapes the packs directory, or a git checkout has no `techpack.yaml`; local packs are not checked for a manifest). |
| `scopes` | array of strings | Where the pack is configured: `"global"` first if synced globally, then project paths from `~/.mcs/projects.yaml`, sorted. Projects whose directory no longer exists are left out. |

An empty registry prints `[]` and exits 0. If `~/.mcs/registry.yaml` or `~/.mcs/projects.yaml` can't be read, the error goes to stderr, nothing is printed to stdout, and the command exits 1. The command never modifies either file.

### `mcs pack update [name]`

```bash
mcs pack update [name]           # Update pack(s) to latest version (registry only, no re-apply)
mcs pack update --trust-all      # Trust changed executable content without prompting (no TTY required)
```

Fetches the latest commits from the remote and updates the local checkout. Local packs are skipped (they are read in-place and pick up changes automatically). A checkout that was deleted is re-cloned at the pack's recorded `ref`.

This is a low-level fetch — useful for pack authors testing upstream changes without applying them, or in CI workflows that handle the apply step separately. For most users, [`mcs update`](#mcs-update) is the right command: it does the same fetch *and* re-applies across every configured scope.

Exits non-zero on a hard failure when running non-interactively (CI) or when every attempted pack failed, matching [`mcs update`](#mcs-update). A declined trust prompt is not a failure. Pass `--trust-all` to approve changed executable content when no terminal can answer the prompt; it grants code execution without review, and the approval persists — see the [`--trust-all` caveat](#mcs-bootstrap) under `mcs bootstrap`.

### `mcs pack validate [source]`

Validate a tech pack for structural correctness and best practices. Designed for pack authors to catch issues locally before submitting to the registry.

```bash
mcs pack validate                # Validate pack in current directory
mcs pack validate /path/to/pack  # Validate pack at a specific path
mcs pack validate ios            # Validate an installed pack by identifier
```

| Argument | Description |
|----------|-------------|
| `[source]` | Directory path or installed pack identifier. Defaults to current directory. |

**Two-stage validation pipeline:**

1. **Structural validation** — manifest existence, YAML parsing, schema validation, `minMCSVersion` check, referenced file existence
2. **Heuristic checks** — best-practice analysis with severity levels

**Severity levels:**

| Severity | Exit code | Examples |
|----------|-----------|---------|
| Error | 1 | Empty pack (no components/templates/configure), `source: "."` copying entire pack root, missing settings file sources |
| Warning | 0 | Unreferenced files in subdirectories, unreferenced root-level content files, MCP server using python/node without brew component, missing python module directory, `brew:` package installed from a third-party tap |

Structural errors always cause exit code 1 and stop further analysis. Heuristic errors also cause exit code 1. Warnings are advisory and do not affect the exit code.

When unreferenced-file warnings appear, the command also emits a remediation hint pointing authors at the manifest's `ignore:` field (see [Schema Reference](techpack-schema.md#the-ignore-field)) — adding intentional non-material paths there silences both the validation warnings and downstream `mcs check-updates` notifications for commits limited to those paths.

## `mcs doctor`

Diagnose installation health with multi-layer checks.

```bash
mcs doctor                       # Diagnose all packs (project + global)
mcs doctor --fix                 # Diagnose, then repair what it can after one confirmation
mcs doctor --pack <name>         # Check a specific pack only
mcs doctor --global              # Check globally-configured packs only
```

| Flag | Description |
|------|-------------|
| `-f, --fix` | Repair failed checks after one confirmation: run the check's own fix (pack `fixCommand`, gitignore entries, stale index entries, missing state file, duplicate scope), or re-sync the scope a failed install check belongs to. |
| `-y, --yes` | Skip confirmation prompt before applying fixes (use with `--fix`). |
| `-p, --pack <name>` | Only check a specific pack. |
| `-g, --global` | Only check globally-configured packs. |

A pack installed in a scope its `scopes:` no longer allows is reported as a warning, not fixed: deselect it with `mcs sync` (or `mcs sync --global`), or run `mcs pack remove <pack>`.

Doctor resolves packs from: explicit `--pack` flag → project `.mcs-project` state → `CLAUDE.local.md` section markers → global manifest.

**How `--fix` repairs.** When an install check fails (a missing MCP server, brew package, plugin, file, hook entry, settings key or gitignore entry), `--fix` re-syncs that scope onto the packs already configured there — the same re-apply `mcs update` runs, so no pack is ever added or removed. The prompt lists each scope to re-sync; re-syncing resets managed files you edited in that scope. Afterwards the failed checks run again and are reported as fixed or still failing. Checks a pack author wrote, and a missing hook interpreter, are never repaired by a re-sync — doctor prints their hint instead. Drift warnings (edited files or settings) are left alone. Without `--fix`, doctor ends with a line saying how many issues `--fix` could repair.

**Exit status:** doctor exits 1 when a check is still failing — with `--fix`, a failure counts unless its fix was reported as applied, so a declined prompt or a hint-only failure still exits 1 — or when a pack named in `--pack` is not registered or failed to load. Warnings and checks skipped during diagnosis never change the exit status. A brew package a pack declares is expected to be installed, so a missing one is a failure.

## `mcs cleanup`

Find and delete timestamped backup files created during sync.

```bash
mcs cleanup                      # List backups and confirm before deleting
mcs cleanup --force              # Delete backups without confirmation
mcs cleanup --all-projects       # Also scan every project tracked in the index
```

| Flag | Description |
|------|-------------|
| `-f, --force` | Delete without confirmation. |
| `-a, --all-projects` | Also scan every project tracked in `~/.mcs/projects.yaml`. |

Without `--all-projects`, cleanup scans `~/.claude/` and the current directory. With it,
each tracked project is scanned at its root (top level only) plus `<project>/.claude/` in
full — the two places sync writes backups. Index entries whose directory no longer exists
are skipped.

## `mcs export`

Export your current Claude Code configuration as a reusable tech pack.

```bash
mcs export <dir>                 # Export current config as a tech pack
mcs export <dir> --global        # Export global scope (~/.claude/)
mcs export <dir> --identifier id # Set pack identifier (prompted if omitted)
mcs export <dir> --non-interactive  # Include everything without prompts
mcs export <dir> --dry-run       # Preview what would be exported
```

| Flag | Description |
|------|-------------|
| `<dir>` | Output directory for the generated pack. |
| `-g, --global` | Export global scope (`~/.claude/`) instead of the current project. |
| `-i, --identifier id` | Set the pack identifier (prompted interactively if omitted). |
| `-y, --non-interactive` | Include all discovered artifacts without prompting for selection. |
| `--dry-run` | Preview what would be exported without writing files. |

The export wizard discovers MCP servers, hooks, skills, commands, agents, plugins, `CLAUDE.md` sections, gitignore entries (global only), and settings. Sensitive env vars are replaced with `__PLACEHOLDER__` tokens and corresponding `prompts:` entries are generated.

## `mcs check-updates`

Check for available tech pack and CLI updates. Designed to be lightweight and non-intrusive.

```bash
mcs check-updates                # Check for updates (always fetches from remote)
mcs check-updates --hook         # Run as SessionStart hook (respects 24-hour cooldown and config)
mcs check-updates --json         # Machine-readable JSON output
mcs check-updates --snooze       # Silence the SessionStart update notice until tomorrow (local time)
```

| Flag | Description |
|------|-------------|
| `--hook` | Run as a Claude Code SessionStart hook. Respects the 24-hour cooldown and config keys. Without this flag, always fetches from remote. |
| `-j, --json` | Output results as JSON instead of human-readable text. |

**How it works:**
- **Pack checks**: Runs `git ls-remote` per pack to compare the remote HEAD against the local commit SHA. Local packs are skipped.
- **Noise filter**: When the remote SHA differs, runs a shallow `git fetch` + `git diff --name-only` in the local pack clone and classifies the changed-path list. If every path is deny-listed infrastructure (README, LICENSE, CHANGELOG, `.github/`, `node_modules/`, `.build/`, `Makefile`, `.gitignore`, etc.), the notification is suppressed and `~/.mcs/registry.yaml`'s `commitSHA` advances to the new remote SHA — the same infrastructure-only commits won't re-trigger on future cooldown windows. Any non-deny-listed path makes the update material and surfaces the notification.
- **`techpack.yaml` always surfaces**: manifest edits can change the install surface entirely (new hook scripts, swapped MCP server commands, different component actions), so the filter never suppresses a commit that touches the manifest — supply-chain safety takes precedence over noise reduction.
- **Never-hide on filter failure**: if `git fetch` or `git diff` errors (offline, access revoked, repo corrupt), the notification surfaces unfiltered. The filter can only suppress; it can't manufacture silence on error.
- **CLI version check**: Queries `git ls-remote --tags` on the mcs repository and compares the latest CalVer tag against the installed version.
- **Cache**: Results are cached in `~/.mcs/update-check.json` (timestamp + results). Cached results are served if less than 24 hours old (no network request). When the cache is stale, a fresh network check runs and the results are cached. `mcs check-updates` (without `--hook`) always forces a fresh check; `mcs sync` and `mcs doctor` respect the cache.
- **Cache invalidation**: `mcs pack update` deletes the cache so the next hook re-checks. CLI version cache self-invalidates when the user upgrades mcs.
- **Scope**: Checks global packs plus packs configured in the current project (detected via project root). Packs not relevant to the current context are skipped.
- **Offline resilience**: Network failures are silently ignored — the command never errors on connectivity issues.

**Note:** `mcs sync` and `mcs doctor` check for updates at the end of execution, respecting the 24-hour cache. The config keys below only control the **automatic** `SessionStart` hook that runs when you start a Claude Code session.

## `mcs config`

Manage mcs user preferences stored at `~/.mcs/config.yaml`.

```bash
mcs config list                  # Show all settings with current values
mcs config get <key>             # Get a specific value
mcs config set <key> <value>     # Set a value (true/false)
```

### Available Keys

| Key | Description | Default |
|-----|-------------|---------|
| `update-check` | Show tech-pack and mcs CLI update notifications on session start (opt-out) | `true` |

These keys control a `SessionStart` hook in `~/.claude/settings.json` that runs `mcs check-updates` when you start a Claude Code session. The hook's output is injected into Claude's context so Claude can inform you about available updates.

- **Enabled (either key `true`)**: A synchronous `SessionStart` hook is registered. It respects the 24-hour cooldown.
- **Disabled (both keys `false`)**: No hook is registered. You can still check manually with `mcs check-updates` or rely on `mcs sync` / `mcs doctor` which check using the 24-hour cache.

When either key changes, `mcs config set` immediately adds or removes the hook from `~/.claude/settings.json` — no re-sync needed. The same hook is also converged during `mcs sync`.

On first interactive sync, `mcs` prompts whether to enable automatic update notifications (sets both keys at once). Fine-tune later with `mcs config set`.

When updates are pending, Claude tells you before it starts on your request and asks once, through a question prompt, whether to apply them; for pack updates that question also warns that `--trust-all` approves the packs' changed executable content without review (see the [`--trust-all` caveat](#mcs-bootstrap)). The question offers three answers: **Update now**, **Not now** (asked again next session) and **Remind me tomorrow**, which runs `mcs check-updates --snooze` so no session asks again until the local date changes. Claude runs no update command without **Update now**, and continues with your request once every question is answered. The commands run in this order: `brew update` and `brew upgrade mcs-cli/tap/mcs` for a CLI update, then `mcs update -a --trust-all` for pack updates. After a pack update Claude runs `mcs doctor` (global scope and current project only). If every check passes it asks, separately, whether to delete all mcs backups across tracked projects with `mcs cleanup -af`; if a check fails it keeps the backups and asks, separately, whether to run `mcs doctor --fix --yes`. If you answer **Not now** to a pack update, run `mcs update --all-projects` in your own terminal to review each trust prompt. To turn the notice off entirely, run `mcs config set update-check false`.

---

**Next**: Learn to build packs from scratch in [Creating Tech Packs](creating-tech-packs.md).

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
