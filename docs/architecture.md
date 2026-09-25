# Architecture

This document describes the internal architecture of `mcs` for contributors and anyone extending the codebase.

## Package Structure

```
Package.swift                    # swift-tools-version: 6.0, macOS 13+
Sources/mcs/
    CLI.swift                    # @main entry, version, subcommand registration
    Core/                        # Shared infrastructure
    Commands/                    # CLI subcommands (sync, bootstrap, doctor, cleanup, pack, export, check-updates, config)
    Sync/                        # Convergence engine, project configuration, installation logic
    Bootstrap/                   # Declarative mcs.yaml loader + shared pack-add pipeline (BootstrapFile, PackAdder)
    Export/                      # Export wizard (ConfigurationDiscovery, ManifestBuilder, PackWriter)
    TechPack/                    # Tech pack protocol, component model, pack registry
    Templates/                   # Template engine and section-based file composition
    Doctor/                      # Diagnostic checks and fix logic
    ExternalPack/                # YAML manifest parsing, Git fetching, adapter, script runner
Tests/MCSTests/                  # Test target
```

## Design Philosophy

`mcs` is a **pure pack management engine** with zero bundled content. It ships no templates, hooks, settings, skills, or slash commands. Everything comes from external tech packs that users add via `mcs pack add` (git URL, GitHub shorthand, or local path).

The primary command is **`mcs sync`**, which handles both global and per-project configuration:
- **`mcs sync [path]`** — per-project setup with multi-pack selection and convergent artifact management
- **`mcs sync --global`** — global-scope component installation (brew packages, MCP servers, plugins)

## Core Infrastructure

### Environment (`Core/Environment.swift`)

Central path resolution for all file locations. Detects architecture (arm64/x86_64), resolves Homebrew path, and locates the user's shell RC file. Key paths:

- `~/.claude/` — Claude Code configuration directory
- `~/.claude/settings.json` — user settings (global)
- `~/.claude.json` — MCP server registrations (global + per-project via `local` scope)
- `~/.mcs/packs/` — external tech pack checkouts
- `~/.mcs/registry.yaml` — registry of installed external packs
- `~/.mcs/global-state.json` — global sync state
- `~/.mcs/lock` — concurrency lock file

Per-project paths (created by `mcs sync`):
- `<project>/.claude/settings.local.json` — per-project settings with hook entries
- `<project>/.claude/skills/` — per-project skills
- `<project>/.claude/hooks/` — per-project hook scripts
- `<project>/.claude/commands/` — per-project slash commands
- `<project>/.claude/agents/` — per-project subagents
- `<project>/.claude/.mcs-project` — per-project state (JSON)
- `<project>/CLAUDE.local.md` — per-project instructions with section markers

### Settings (`Core/Settings.swift`)

`Settings` is a Codable model that mirrors the structure of Claude Code settings files. It supports deep-merge: when merging, hooks are deduplicated by command string, plugins are merged additively, and scalar values from the template take precedence.

In the per-project model, `Configurator` (with `ProjectSyncStrategy`) composes `settings.local.json` from all selected packs' hook entries. Each pack gets its own `HookGroup` entry pointing to a script in `<project>/.claude/hooks/<pack-id>/`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/core/session-start.sh" }] },
      { "hooks": [{ "type": "command", "command": "node .claude/hooks/ios/session-start.js" }] }
    ]
  }
}
```

The command is `<interpreter> <path>`, composed in one place — `ComponentDefinition.hookCommand(pathPrefix:)`. Only the directory is scope-dependent (`Constants.HookCommand.projectDirectory` / `.globalDirectory`); the interpreter comes from the component, via `HookInterpreter.resolve` (explicit `hookInterpreter` → file extension → `bash`). Global-scope cleanup recognises its own entries by the **path token**, not an interpreter prefix, so a `node` hook is stripped as readily as a bash one.

### Project State (`Core/ProjectState.swift`)

Per-project state stored as JSON at `<project>/.claude/.mcs-project`. Tracks:

- **Configured packs**: which packs are configured for this project
- **Per-pack artifact records** (`PackArtifactRecord`): for each pack, what was installed
  - `mcpServers`: name + scope (for `claude mcp remove`)
  - `files`: project-relative paths (for deletion)
  - `templateSections`: section identifiers (for CLAUDE.local.md removal)
  - `hookCommands`: hook commands (for settings.local.json cleanup)
  - `settingsKeys`: settings keys contributed by this pack
- **mcs version**: the version that last wrote the file
- **Timestamp**: when the file was last updated

Written by `mcs sync` after convergence.

### Global vs. Project State

| | `~/.mcs/global-state.json` | `<project>/.claude/.mcs-project` |
|---|---|---|
| **Scope** | Machine-wide | Single project |
| **Written by** | `mcs sync --global` | `mcs sync` |
| **Format** | JSON | JSON |
| **Tracks** | Globally installed components, pack IDs, file hashes | Per-pack artifact records, configured pack IDs |

### Backup (`Core/Backup.swift`)

Before modifying files with user content (e.g., `CLAUDE.local.md`), a timestamped backup is created (e.g., `CLAUDE.local.md.backup.20260222_143000`). Tool-managed files are not backed up since they can be regenerated. The `mcs cleanup` command discovers and deletes these backups.

### ClaudeIntegration (`Core/ClaudeIntegration.swift`)

Wraps `claude mcp add/remove` and `claude plugin install/remove` CLI commands. MCP server registration supports three scopes:

- **`local`** (default): per-user, per-project — stored in `~/.claude.json` keyed by project path
- **`project`**: team-shared — stored in `.mcp.json` in the project directory
- **`user`**: cross-project — stored in `~/.claude.json` globally

### UpdateChecker (`Core/UpdateChecker.swift`)

Detects upstream pack and CLI updates via `git ls-remote`, with a **noise filter** so non-material upstream commits (README, LICENSE, CI, `.github/`, etc.) don't trigger spurious notifications. When the remote SHA differs from the registry baseline, the checker does a shallow `git fetch` + `git diff --name-only` in the local pack clone and classifies the changed-path list against a built-in deny-list. If every path is infrastructure, the notification is suppressed and the registry `commitSHA` advances so the same commits don't re-trigger. `techpack.yaml` is always treated as material — manifest edits can swap the install surface entirely, and silently suppressing those commits would be a supply-chain attack vector. Filter failures (offline, fetch error) fall through to surfacing the notification unfiltered — the filter can only suppress, never manufacture silence.

Results are cached in `~/.mcs/update-check.json` with a 24-hour cooldown. The SessionStart hook serves cached results on every session start; only `mcs check-updates` (without `--hook`) forces a fresh network check.

## External Pack System

External packs are directories containing a `techpack.yaml` manifest — either Git repositories cloned into `~/.mcs/packs/` or local directories registered in-place. The system has these layers:

1. **PackSourceResolver** — resolves user input into a git URL or local path (URL schemes → filesystem → GitHub shorthand)
2. **PackFetcher** — clones/pulls git pack repos into `~/.mcs/packs/<name>/`
3. **ExternalPackManifest** — Codable model for `techpack.yaml` (components, templates, hooks, doctor checks, prompts, configure scripts). Supports shorthand syntax for concise component definitions
4. **ExternalPackAdapter** — bridges `ExternalPackManifest` to the `TechPack` protocol so external packs participate in all sync/doctor flows
5. **PackRegistryFile** — YAML registry (`~/.mcs/registry.yaml`) tracking which packs are installed
6. **PackUpdater** — shared fetch → validate → trust cycle for updating a single git pack
7. **TechPackRegistry** — unified registry that loads external packs from disk

### Pack Manifest (`techpack.yaml`)

Shorthand syntax (preferred):

```yaml
identifier: my-pack
displayName: My Pack
description: What this pack provides

components:
  - id: my-server
    description: My MCP server
    mcp:
      command: npx
      args: ["-y", "my-server@latest"]

templates:
  - sectionIdentifier: instructions
    contentFile: templates/claude-local.md
```

Verbose form is also supported — see [Tech Pack Schema](techpack-schema.md).

## Sync Flow

### Project Sync (`mcs sync [path]`)

`Configurator` (with `ProjectSyncStrategy`) is the per-project convergence engine:

1. **Select packs** (`SyncCommand`): multi-select pre-checks previously configured packs; `--pack`/`--all` skip it
2. **Compute diff**: `removals = previous - selected`, `additions = selected - previous`
3. **Non-interactive preflight** (stdin not a TTY only): resolve every prompt from seeded/stored values and declared defaults, and throw `PromptResolutionError` before anything is removed or installed if any key stays unresolved
4. **Confirm and unconfigure removed packs**: show the removal summary and ask (unless `confirmRemovals` is off), then remove each pack's MCP servers, files, brew packages, plugins and gitignore entries using its stored `PackArtifactRecord`
5. **Remove newly excluded components' artifacts** (`--customize`)
6. **Auto-install global deps**: brew packages and plugins for all selected packs, before any other component
7. **Resolve template values** (single pass):
   - Built-in values (`__REPO_NAME__`, `__PROJECT_DIR_NAME__`), then stored values from earlier syncs that are still valid (a `select` answer must still be an option), reused unless `--customize` is set or the user declines the reuse prompt
   - Shared prompts (same key from 2+ packs, `input`/`select` only) once via `CrossPackPromptResolver`
   - Each pack's remaining prompts, skipping keys an earlier pack produced
   - Undeclared `__KEY__` placeholders in copyPackFile sources, settings files, MCP configs and templates are prompted inline, defaulting to the stored value
8. **Install per-project artifacts**: per pack in selection order, install components in declaration order (skills/hooks/commands to `<project>/.claude/`, MCP servers with `local` scope, placeholders substituted), then remove artifacts the pack no longer declares
9. **Compose `settings.local.json`**: build from all selected packs' hook entries and settings files (with placeholder substitution)
10. **Compose `CLAUDE.local.md`**: gather template sections from all selected packs, dropping templates whose `dependencies:` name an excluded component
11. **Run pack configure hooks**: pack-specific setup (e.g., generate config files)
12. **Ensure gitignore entries**: add `.claude/` entries to global gitignore
13. **Save state**: write `.mcs-project` with artifact records for each pack and update `~/.mcs/projects.yaml`

The `--pack` flag bypasses multi-select for CI use: `mcs sync --pack ios --pack web`. It is additive: `ConfiguratorSupport.additivePackSet` (shared with `mcs bootstrap`) unions the named packs with the scope's configured set, because `configure` removes anything missing from its list. `--prune` makes the named packs the exact set and routes removals through the `confirmRemovals` prompt (`--yes` skips it).

### Global Sync (`mcs sync --global`)

`Configurator` (with `GlobalSyncStrategy`) handles global-scope installation:

It runs the same `Configurator.configure` pipeline with these differences:

- Brew packages and plugins install inline with the other components, in declaration order, instead of in an up-front pass (step 6)
- MCP servers are registered with `user` scope
- Settings compose into `~/.claude/settings.json` (preserving keys mcs does not own) and templates into `~/.claude/CLAUDE.md`; templates are not scanned for undeclared placeholders
- Pack configure hooks do not run
- State is recorded in `~/.mcs/global-state.json`

### Bootstrap (`mcs bootstrap`)

`BootstrapCommand` reads a declarative `./mcs.yaml` at the command's cwd and composes existing primitives — it never re-implements install or sync logic:

1. **Load & validate** (`Bootstrap/BootstrapFile.swift`): schema version, non-empty `packs`, unique `source`, reserved `scope`.
2. **Reconcile the registry**: for each `source`, check `PackRegistryFile`. Not registered → `PackAdder.add` (shared with `mcs pack add`). Same source + same ref → silent no-op. Same source + different ref → `PackUpdater.updateGitPack`. Different source → `PackAdder.add` with `duplicatePolicy: .autoAccept` and a warning.
3. **Seed prompt priors**: merge each pack's `values` into `ProjectState.resolvedValues`. The sync engine's existing prior-reuse path (`Configurator.resolveAllValues`) picks them up silently, both for declared prompt keys and for `__KEY__` placeholders no prompt declares. A seeded key matching neither produces a warning before sync.
4. **Compose the effective pack set**: default is *additive* — `effectiveIDs = declared ∪ previouslyConfigured`, so packs configured outside `mcs.yaml` are preserved. `--prune` collapses to *authoritative* — `effectiveIDs = declared`, and packs configured but absent from the file get unconfigured by `Configurator.configure`.
5. **Sync**: filter globally-blocked packs via `ConfiguratorSupport.filterGloballyBlocked`, then call `Configurator.configure(packs: effective, confirmRemovals: !yes, excludedComponents: ...)` with `ProjectSyncStrategy`. Under `--prune`, the removal-confirmation gate inside `Configurator.configure` is bootstrap's `--yes` switch.
6. **Divergence footer**: after an additive sync, if any packs were preserved (present in project but not in the file), print an informational list pointing at `--prune` as the remedy. Non-blocking — keeps the divergence visible without a wall-style prompt.

The shared `PackAdder` helper (in `Sources/mcs/Bootstrap/`) is what keeps `mcs pack add` and `mcs bootstrap` on one code path — a `DuplicatePolicy` enum swaps the interactive `askYesNo` for auto-accept when bootstrap needs it. The additive-default + explicit-`--prune` shape matches the convention Homebrew Bundle, Kubernetes (`kubectl apply --prune`), and npm (`install` vs `prune`) settled on for declarative-file + external-state workflows.

## Component Model

Each installable unit is a `ComponentDefinition` with:

- **id**: unique identifier (e.g., `ios.xcodebuildmcp`)
- **type**: `mcpServer`, `plugin`, `skill`, `hookFile`, `command`, `agent`, `brewPackage`, `configuration`
- **packIdentifier**: pack ID for the owning pack
- **dependencies**: IDs of components this depends on
- **isRequired**: if true, always installed with its pack
- **installAction**: how to install (see below)
- **supplementaryChecks**: doctor checks that can't be auto-derived

### Install Actions

```swift
enum ComponentInstallAction {
    case mcpServer(MCPServerConfig)     // Register via `claude mcp add -s <scope>`
    case plugin(name: String)            // Install via `claude plugin install`
    case brewInstall(package: String)    // Install via Homebrew
    case shellCommand(command: String, interactive: Bool = false)  // Run shell command (interactive: PTY for sudo)
    case settingsMerge                   // Deep-merge settings (project-level)
    case gitignoreEntries(entries)       // Add to global gitignore
    case copyPackFile(source, dest, type) // Copy from pack checkout to project .claude/
}
```

`copyPackFile` destinations are installed flat by default (e.g., `.claude/commands/pr.md`). When two or more packs define the same `(destination, fileType)`, the `DestinationCollisionResolver` auto-namespaces them: subdirectory prefix (`<pack-id>/`) for hooks, commands, agents, and generic files, or directory name suffix (`-<pack-id>`) for skills (which require flat one-level directories for Claude Code discovery).

### MCP Server Scopes

`MCPServerConfig` includes a `scope` field:
- `nil` / `"local"` (default) — per-user, per-project isolation
- `"project"` — team-shared (`.mcp.json`)
- `"user"` — cross-project global

## Tech Pack Protocol

```swift
protocol TechPack: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var description: String { get }
    var components: [ComponentDefinition] { get }
    var templates: [TemplateContribution] { get }
    var supplementaryDoctorChecks: [any DoctorCheck] { get }
    func templateValues(context: ProjectConfigContext) -> [String: String]
    func declaredPrompts(context: ProjectConfigContext) -> [PromptDefinition]
    func configureProject(at path: URL, context: ProjectConfigContext) throws
}
```

Packs provide:
- **Components**: installable units (MCP servers, skills, etc.)
- **Templates**: sections to inject into `CLAUDE.local.md`
- **Supplementary doctor checks**: pack-level diagnostics not derivable from components
- **Template values**: resolved via prompts or scripts during sync
- **Declared prompts**: prompt definitions for cross-pack deduplication (without executing them)
- **Project configuration**: pack-specific setup (e.g., generate config files)

## Doctor System

`DoctorRunner` orchestrates checks across five layers:

1. **Derived checks**: auto-generated from each component's `installAction` via `deriveDoctorCheck()`
2. **Supplementary component checks**: additional checks declared on components
3. **Supplementary pack checks**: pack-level concerns not tied to a specific component
4. **Standalone checks**: cross-component concerns (hook event registration, settings validation, gitignore)
5. **Project checks**: CLAUDE.local.md freshness, project state file

### fix() Responsibility Boundary

`doctor --fix` routes each failed check one of three ways, all behind one confirmation prompt:
- **Own fix**: the check has a `fixCommandPreview` — pack `fixCommand`/`fixScript`, gitignore additions, stale project-index entries, a missing `.mcs-project` inferred from section markers, and scope-duplication removal
- **Scope re-sync**: derived checks and artifact-record checks (except `HookInterpreterCheck`) verify what sync installs, so `DoctorRunner` re-syncs their scope through `ScopeReapplier` with the scope's full configured set, then re-runs them
- **Hint only**: pack-authored and standalone checks without a fix print their `fix()` message

`doctor --fix` never re-implements an install step — additive work always goes through the sync engine.

### Check Scope Resolution

Individual checks resolve component presence through three tiers:

1. **Project path**: when packs are resolved from project scope, checks look in `<project>/.claude/` first (e.g., `<project>/.claude/skills/my-skill.md`)
2. **Global fallback**: if not found at project scope, checks fall back to `~/.claude/` (covers globally-installed components)
3. **Exclusion suppression**: components excluded via `--customize` show as dimmed `○ excluded via --customize` instead of failing

MCP server checks follow the same pattern: project-scoped entries (`projects[path].mcpServers` in `~/.claude.json`) are checked before global entries (`mcpServers`).

Settings-reading checks do too. `PluginCheck` and the pack-declared `hookEventExists` / `settingsKeyEquals` checks read `<project>/.claude/settings.local.json` before `~/.claude/settings.json`, which mirrors Claude Code's own precedence — so they report on the configuration actually in effect rather than on one file in isolation. Doctor output names the file that answered, and a settings file that exists but cannot be parsed is always surfaced rather than skipped silently.

### Hook Registration Verification

A hook whose matcher names a tool Claude Code never emits installs cleanly, registers in settings, and fires for nothing. The symptom is an *empty* log, which reads as "no problems found" rather than "never ran" — so `HookSettingsCheck` verifies not just that each pack-contributed hook command is present, but that it is registered the way the declaring component said it should be.

The check joins the commands recorded in `PackArtifactRecord.hookCommands` back to the components that declared them, keyed on the command string that `ComponentDefinition.hookCommand(pathPrefix:)` builds for both sides. Where a component supplied a `HookRegistration`, its `event` and `matcher` are compared against what is installed:

- **Command absent** — `✗ fail`. The hook is not registered at all.
- **Registered under a different event, or with a different matcher** — `⚠ warn`. `Settings.addHookEntry` rewrites a differing matcher on the next sync, so `mcs sync` is a remedy that actually works, and a user who narrowed a matcher deliberately is not blocked by a red doctor.
- **No declaration to compare against** — presence-only, as before. This means the recorded command no longer maps to any component in the pack: it was removed, or its destination renamed, since the last sync.

Extra registrations under events the pack never declared are not policed, and an empty matcher string is treated as an absent one. `timeout`, `async`, and `statusMessage` stay unverified — a wrong value there is cosmetic, whereas `event` and `matcher` are the two whose wrong value silently disables the hook.

The interpreter is verified from the other direction. It is part of the join key itself, so a divergence between what sync wrote and what doctor rebuilds makes the hook read as missing rather than misconfigured. What can still go wrong is the binary: `HookInterpreterCheck` verifies it resolves, once per distinct binary per pack, and warns when it resolves only through a version manager — a path that works in the user's terminal and often not in the environment Claude Code hands its hooks.

**This proves the declared matcher reached settings, not that it matches any tool Claude Code actually emits.** Only a real session transcript proves that. Tool names are harness implementation details that can change between Claude Code releases, so any matcher naming a specific tool is worth re-checking after an upgrade.

### Pack Resolution

When determining which packs to check, doctor uses a priority chain:
1. Explicit `--pack` flag
2. Project `.mcs-project` state file
3. Inferred from `CLAUDE.local.md` section markers
4. Global manifest

## Template System

### TemplateEngine

`__PLACEHOLDER__` substitution across multiple artifact types. Values are passed as `[String: String]` dictionaries. Packs can resolve values via prompts (interactive) or scripts (automated) during sync.

Substitution applies to:
- **Templates**: CLAUDE.local.md sections (Phase 7)
- **copyPackFile artifacts**: hooks, commands, skills, generic files (Phase 5)
- **Settings files**: `.settingsMerge` JSON — text-level substitution before JSON parsing via `Settings.load(from:substituting:)`
- **MCP server configs**: `env` values, `command`, and `args` via `MCPServerConfig.substituting(_:)` (name is preserved as artifact tracking key)

### TemplateComposer

Manages section markers in `CLAUDE.local.md`:

```html
<!-- mcs:begin core -->
... managed content ...
<!-- mcs:end core -->

<!-- mcs:begin ios -->
... managed content ...
<!-- mcs:end ios -->

(user content preserved outside markers)
```

Key operations:
- `compose()`: create a new file from contributions
- `replaceSection()`: update a section in an existing file
- `extractUserContent()`: preserve content outside markers during updates
- `parseSections()`: extract section identifiers

## Export System

`mcs export` is the inverse of `mcs sync`: it reads installed artifacts and generates a `techpack.yaml` manifest. The export flow uses three dedicated types:

1. **ConfigurationDiscovery** (`Export/ConfigurationDiscovery.swift`) — reads live config files (`~/.claude.json`, `settings.json`, `.claude/` directories, `CLAUDE.md`, global gitignore) and produces a `DiscoveredConfiguration` model
2. **ManifestBuilder** (`Export/ManifestBuilder.swift`) — converts selected artifacts into a YAML string using shorthand syntax. Handles sensitive env var replacement (`__PLACEHOLDER__` tokens + `prompts:` entries), brew dependency hints, and section comments
3. **PackWriter** (`Export/PackWriter.swift`) — writes the output directory (`techpack.yaml` + copied files + config/settings.json + templates/)

The command (`Commands/ExportCommand.swift`) is a read-only `ParsableCommand` (no lock needed). It supports `--global` for global scope, `--dry-run` for preview, and `--non-interactive` for CI use.

## Safety & Trust

`mcs` is designed to be safe to run repeatedly, non-destructive by default, and transparent about what it changes.

| Guarantee | How it works |
|-----------|-------------|
| **Backups** | Timestamped backup before modifying files with user content (e.g., `CLAUDE.local.md`). Tool-managed files are not backed up since they can be regenerated. Clean up with `mcs cleanup`. |
| **Dry Run** | `mcs sync --dry-run` previews all changes without writing any files, so you can inspect exactly what will happen before committing. |
| **Selective Install** | `mcs sync --customize` lets you deselect individual components. `--all` applies everything without prompts. Both are safe — the engine tracks what was selected. |
| **Idempotent** | Every `mcs sync` run converges to the same desired state. Safe to run any number of times — re-copies files, re-composes settings, re-registers MCP servers. |
| **Non-Destructive** | User content in `CLAUDE.local.md` is preserved via `<!-- mcs:begin/end -->` section markers. Content outside markers is never touched. |
| **Convergent** | Deselected packs are fully cleaned up — MCP servers removed, project files deleted, template sections stripped, settings keys cleaned. No orphaned artifacts. |
| **Trust Verification** | Pack scripts are SHA-256 hashed at `mcs pack add` time and verified at load time. Modified scripts are detected and the user is prompted to re-trust before proceeding. Local packs skip verification since scripts change during development. |
| **Trust Boundary** | `brew:` and `plugin:` install actions are outside trust review — they contribute no hashed item, so a pack declaring only those installs without a prompt, and changing one does not ask for renewed trust on `mcs pack update`. A tap-qualified `brew:` package is the case to watch: Homebrew taps a third-party repository and evaluates its formula without confirmation. |

## Concurrency Model

The codebase uses Swift 6's strict concurrency. All core types conform to `Sendable`. `TechPack` is a `Sendable` protocol. No mutable global state exists outside the installer's in-progress mutation context.

---

**Next**: Having issues? See [Troubleshooting](troubleshooting.md).

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
