# Architecture

This document describes the internal architecture of `mcs` for contributors and anyone extending the codebase.

## Package Structure

```
Package.swift                    # swift-tools-version: 6.0, macOS 13+
Sources/mcs/
    CLI.swift                    # @main entry, version, subcommand registration
    Core/                        # Shared infrastructure
    Commands/                    # CLI subcommands (sync, doctor, cleanup, pack, export)
    Install/                     # Installation logic, project configuration, convergence engine
    Export/                      # Export wizard (ConfigurationDiscovery, ManifestBuilder, PackWriter)
    TechPack/                    # Tech pack protocol, component model, dependency resolver
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
- `<project>/mcs.lock.yaml` — lockfile pinning pack commits

### Settings (`Core/Settings.swift`)

`Settings` is a Codable model that mirrors the structure of Claude Code settings files. It supports deep-merge: when merging, hooks are deduplicated by command string, plugins are merged additively, and scalar values from the template take precedence.

In the per-project model, `Configurator` (with `ProjectSyncStrategy`) composes `settings.local.json` from all selected packs' hook entries. Each pack gets its own `HookGroup` entry pointing to a script in `<project>/.claude/hooks/`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/core-session-start.sh" }] },
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/ios-session-start.sh" }] }
    ]
  }
}
```

### Manifest (`Core/Manifest.swift`)

Tracks what mcs has installed globally using three data structures:

1. **File hashes**: SHA-256 hashes of copied resources at install time
2. **Installed component IDs**: set of component identifiers (e.g., `ios.xcodebuildmcp`)
3. **Installed pack IDs**: set of pack identifiers (e.g., `ios`)

The manifest covers global-scope installations. Per-project state is tracked separately by `ProjectState`.

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

Every file write goes through the backup system. Before overwriting a file, a timestamped copy is created (e.g., `settings.json.backup.20260222_143000`). The `mcs cleanup` command discovers and deletes these backups.

### Lockfile (`Core/Lockfile.swift`)

`mcs.lock.yaml` pins pack commits for reproducible builds. Created/updated by `mcs sync` after successful project sync. Used with `--lock` to checkout pinned commits or `--update` to fetch latest and refresh the lockfile.

### ClaudeIntegration (`Core/ClaudeIntegration.swift`)

Wraps `claude mcp add/remove` and `claude plugin install/remove` CLI commands. MCP server registration supports three scopes:

- **`local`** (default): per-user, per-project — stored in `~/.claude.json` keyed by project path
- **`project`**: team-shared — stored in `.mcp.json` in the project directory
- **`user`**: cross-project — stored in `~/.claude.json` globally

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

1. **Multi-select**: shows all registered packs, pre-selects previously configured packs
2. **Compute diff**: `removals = previous - selected`, `additions = selected - previous`
3. **Resolve template values** (multi-step):
   - **3a.** Resolve built-in values (`__REPO_NAME__`, `__PROJECT_DIR_NAME__`)
   - **3b–3c.** Collect all prompt definitions from packs via `declaredPrompts()`, group shared keys (same key from 2+ packs, `input`/`select` types only)
   - **3d.** Execute shared prompts once via `CrossPackPromptResolver` with combined display
   - **3e.** Execute remaining per-pack prompts (skip already-resolved keys)
4. **Scan for undeclared placeholders**: warn about `__KEY__` tokens in copyPackFile sources, settings files, and MCP configs that have no matching prompt
5. **Unconfigure removed packs**: remove MCP servers (via CLI), delete project files, using stored `PackArtifactRecord`
6. **Auto-install global deps**: brew packages and plugins for all selected packs
7. **Install per-project artifacts**: copy skills/hooks/commands to `<project>/.claude/`, register MCP servers with `local` scope (with placeholder substitution in env/command/args)
8. **Compose `settings.local.json`**: build from all selected packs' hook entries and settings files (with placeholder substitution)
9. **Compose `CLAUDE.local.md`**: gather template sections from all selected packs
10. **Run pack configure hooks**: pack-specific setup (e.g., generate config files)
11. **Ensure gitignore entries**: add `.claude/` entries to global gitignore
12. **Save project state**: write `.mcs-project` with artifact records for each pack
13. **Write lockfile**: save `mcs.lock.yaml` with current pack state

The `--pack` flag bypasses multi-select for CI use: `mcs sync --pack ios --pack web`.

### Global Sync (`mcs sync --global`)

`Configurator` (with `GlobalSyncStrategy`) handles global-scope installation:

1. **Selection**: interactive multi-select, `--pack <name>`, or `--all`
2. **Component install**: brew packages, MCP servers (user scope), plugins
3. **Record state**: update `~/.mcs/global-state.json`

## Dependency Resolution

`DependencyResolver` performs a topological sort of selected components plus their transitive dependencies. It detects cycles and auto-adds dependencies that weren't explicitly selected (marking them as "(auto-resolved)" in the summary).

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
    case shellCommand(command: String)   // Run arbitrary shell command
    case settingsMerge                   // Deep-merge settings (project-level)
    case gitignoreEntries(entries)       // Add to global gitignore
    case copyPackFile(source, dest, type) // Copy from pack checkout to project .claude/
}
```

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

`doctor --fix` only handles:
- **Cleanup**: removing deprecated components
- **Trivial repairs**: permission fixes, gitignore additions, symlink creation
- **Project state**: creating missing `.mcs-project` by inferring from section markers

`doctor --fix` does NOT handle additive operations (installing packages, registering servers, copying files). These are handled by `mcs sync`.

### Check Scope Resolution

Individual checks resolve component presence through three tiers:

1. **Project path**: when packs are resolved from project scope, checks look in `<project>/.claude/` first (e.g., `<project>/.claude/skills/my-skill.md`)
2. **Global fallback**: if not found at project scope, checks fall back to `~/.claude/` (covers globally-installed components)
3. **Exclusion suppression**: components excluded via `--customize` show as dimmed `○ excluded via --customize` instead of failing

MCP server checks follow the same pattern: project-scoped entries (`projects[path].mcpServers` in `~/.claude.json`) are checked before global entries (`mcpServers`).

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
| **Trust Verification** | Pack scripts are SHA-256 hashed at `mcs pack add` time and verified at load time. If a hash doesn't match, the pack is rejected. Local packs skip verification since scripts change during development. |
| **Lockfile** | `mcs.lock.yaml` pins pack commits for reproducible environments. Use `--lock` to check out pinned versions or `--update` to fetch latest and refresh the lockfile. |

## Concurrency Model

The codebase uses Swift 6's strict concurrency. All core types conform to `Sendable`. `TechPack` is a `Sendable` protocol. No mutable global state exists outside the installer's in-progress mutation context.

---

**Next**: Having issues? See [Troubleshooting](troubleshooting.md).

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
