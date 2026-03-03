# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift CLI tool (`mcs`) that configures Claude Code with MCP servers, plugins, skills, hooks, and settings. Pure pack management engine with zero bundled content — all features come from external tech packs. Distributed via Homebrew.

## Commands

```bash
# Development
swift build                      # Build the CLI
swift test                       # Run tests
swift build -c release --arch arm64 --arch x86_64  # Universal binary

# CLI usage (after install)
mcs sync [path]                  # Sync project: multi-select packs, compose artifacts (default command)
mcs sync --pack ios              # Non-interactive: apply specific packs (repeatable)
mcs sync --all                   # Apply all registered packs without prompts
mcs sync --dry-run               # Preview what would change
mcs sync --customize             # Per-pack component selection
mcs sync --global                # Sync global scope (MCP servers, brew, plugins to ~/.claude/)
mcs sync --lock                  # Checkout locked versions from mcs.lock.yaml
mcs sync --update                # Fetch latest versions and update mcs.lock.yaml
mcs doctor                       # Diagnose installation health
mcs doctor --fix                 # Diagnose and auto-fix issues
mcs doctor --pack ios            # Only check a specific pack
mcs doctor --global              # Check globally-configured packs only
mcs pack add <source>            # Add a tech pack (git URL, GitHub shorthand, or local path)
mcs pack add user/repo           # GitHub shorthand → https://github.com/user/repo.git
mcs pack add /path/to/pack       # Add a local pack (read in-place, no clone)
mcs pack add <url> --ref <tag>   # Add at a specific tag, branch, or commit (git only)
mcs pack add <url> --preview     # Preview pack contents without installing
mcs pack remove <name>           # Remove an external tech pack
mcs pack remove <name> --force   # Remove without confirmation
mcs pack list                    # List registered external packs
mcs pack update [name]           # Update pack(s) to latest version (skips local packs)
mcs cleanup                      # Find and delete backup files
mcs cleanup --force              # Delete backups without confirmation
mcs export <dir>                 # Export current config as a tech pack
mcs export <dir> --global        # Export global scope (~/.claude/)
mcs export <dir> --identifier id # Set pack identifier (prompted if omitted)
mcs export <dir> --non-interactive  # Include everything without prompts
mcs export <dir> --dry-run       # Preview what would be exported
```

## Architecture

### Swift Package Structure
- **Package.swift** — swift-tools-version: 6.0, macOS 13+, deps: swift-argument-parser, Yams
- **Sources/mcs/** — main executable target
- **Tests/MCSTests/** — test target

### Entry Point
- `CLI.swift` — `@main` struct, `MCSVersion.current`, subcommand registration (`SyncCommand` is the default subcommand)

### Core (`Sources/mcs/Core/`)
- `Constants.swift` — centralized string constants (file names, CLI paths, JSON keys, external packs, plugins)
- `Environment.swift` — paths, arch detection, brew path
- `CLIOutput.swift` — ANSI colors, logging, prompts, multi-select, doctor summary
- `ShellRunner.swift` — Process execution wrapper
- `Settings.swift` — Codable model for `settings.json` and `settings.local.json`, deep-merge
- `Backup.swift` — timestamped backups for mixed-ownership files (CLAUDE.local.md), backup discovery and deletion
- `GitignoreManager.swift` — global gitignore management, core entry list
- `ClaudeIntegration.swift` — `claude mcp add/remove` (with scope support), `claude plugin install/remove`
- `Homebrew.swift` — brew detection, package install/uninstall
- `Lockfile.swift` — `mcs.lock.yaml` model for pinning pack commits
- `ProjectDetector.swift` — walk-up project root detection (`.git/` or `CLAUDE.local.md`)
- `ProjectState.swift` — per-project `.claude/.mcs-project` JSON state (configured packs, per-pack `PackArtifactRecord` with ownership tracking, version)
- `ProjectIndex.swift` — cross-project index (`~/.mcs/projects.yaml`) mapping project paths to pack IDs for reference counting
- `MCSError.swift` — error types for the CLI

### TechPack System (`Sources/mcs/TechPack/`)
- `TechPack.swift` — protocol for tech packs (components, templates, hooks, doctor checks, project configuration)
- `Component.swift` — ComponentDefinition with install actions, ComponentType enum, MCPServerConfig (with scope), CopyFileType (with project-scoped directories)
- `TechPackRegistry.swift` — registry of available packs (external only), filtering by installed state
- `DependencyResolver.swift` — topological sort of component dependencies with cycle detection

### External Pack System (`Sources/mcs/ExternalPack/`)
- `ExternalPackManifest.swift` — YAML `techpack.yaml` schema (Codable models for components, templates, hooks, doctor checks, prompts, configure scripts). Supports **shorthand syntax** (`brew:`, `mcp:`, `plugin:`, `hook:`, `command:`, `skill:`, `agent:`, `settingsFile:`, `gitignore:`, `shell:`) that infers `type` + `installAction` from a single key
- `ExternalPackAdapter.swift` — bridges `ExternalPackManifest` to the `TechPack` protocol
- `ExternalPackLoader.swift` — discovers and loads packs from `~/.mcs/packs/` (git) or absolute paths (local)
- `PackFetcher.swift` — Git clone/pull for pack repositories
- `PackSourceResolver.swift` — resolves user input into git URL or local path (URL schemes, filesystem, GitHub shorthand)
- `PackRegistryFile.swift` — YAML registry of installed external packs (`~/.mcs/registry.yaml`)
- `PackTrustManager.swift` — pack trust verification
- `PromptExecutor.swift` — executes pack prompts (interactive value resolution during sync)
- `ScriptRunner.swift` — sandboxed script execution for pack scripts
- `ExternalDoctorCheck.swift` — factory for converting YAML doctor check definitions to `DoctorCheck` instances

### Doctor (`Sources/mcs/Doctor/`)
- `DoctorRunner.swift` — 5-layer check orchestration with project-aware pack resolution
- `CoreDoctorChecks.swift` — check structs (CommandCheck, MCPServerCheck, PluginCheck, HookCheck, GitignoreCheck, CommandFileCheck, FileExistsCheck, ProjectIndexCheck)
- `DerivedDoctorChecks.swift` — `deriveDoctorCheck()` extension on ComponentDefinition
- `ProjectDoctorChecks.swift` — project-scoped checks (CLAUDE.local.md freshness, state file)
- `SectionValidator.swift` — validation of CLAUDE.local.md section markers

### Commands (`Sources/mcs/Commands/`)
- `SyncCommand.swift` — primary command (`mcs sync`), handles both project-scoped and global-scoped sync with `--pack`, `--all`, `--dry-run`, `--customize`, `--global`, `--lock`, `--update` flags
- `DoctorCommand.swift` — health checks with optional --fix and --pack filter
- `CleanupCommand.swift` — backup file management with --force flag
- `PackCommand.swift` — `mcs pack add/remove/list/update` subcommands; uses `PackSourceResolver` for 3-tier input detection (URL schemes → filesystem paths → GitHub shorthand)
- `ExportCommand.swift` — export wizard: reads live configuration and generates a reusable tech pack directory; supports `--global`, `--identifier`, `--non-interactive`, `--dry-run`

### Export (`Sources/mcs/Export/`)
- `ConfigurationDiscovery.swift` — reads live config sources (settings, MCP servers, hooks, skills, CLAUDE.md, gitignore), produces `DiscoveredConfiguration` model
- `ManifestBuilder.swift` — converts selected artifacts into YAML using custom renderer (ordered metadata, section comments, proper quoting)
- `PackWriter.swift` — writes output directory with symlink resolution for copied files

### Install (`Sources/mcs/Install/`)
- `Configurator.swift` — unified multi-pack convergence engine parameterized by `SyncStrategy` (artifact tracking, settings composition, CLAUDE file writing, gitignore). `unconfigurePack()` handles removal for both `mcs sync` (deselection) and `mcs pack remove` (federated across all affected scopes)
- `SyncScope.swift` — pure data struct capturing path-level differences between project and global scopes
- `SyncStrategy.swift` — protocol isolating scope-specific behavior (artifact installation, settings/CLAUDE composition, file removal)
- `ProjectSyncStrategy.swift` — project-scope strategy (settings.local.json, CLAUDE.local.md, repo name resolution)
- `GlobalSyncStrategy.swift` — global-scope strategy (settings.json preservation, brew/plugin ownership, MCP scope override to "user")
- `ComponentExecutor.swift` — dispatches install actions (brew, MCP servers, plugins, gitignore, project-scoped file copy/removal)
- `PackInstaller.swift` — auto-installs missing pack components
- `PackUpdater.swift` — shared fetch → validate → trust cycle for updating a single git pack (used by `UpdatePack` and `LockfileOperations`)
- `ResourceRefCounter.swift` — two-tier reference counting (global artifacts + project index manifests) for safe brew/plugin removal
- `LockfileOperations.swift` — reads/writes `mcs.lock.yaml`, checks out locked versions, updates lockfile

### Templates (`Sources/mcs/Templates/`)
- `TemplateEngine.swift` — `__PLACEHOLDER__` substitution
- `TemplateComposer.swift` — section markers for composed files (`<!-- mcs:begin/end -->`), section parsing, user content preservation

## Code Style

SwiftFormat and SwiftLint enforce consistent code style. Both are installed via Homebrew.

```bash
# Format modified files (run before committing)
swiftformat <file-or-directory>

# Lint — check without modifying (CI runs these with --strict)
swiftformat --lint .
swiftlint

# Auto-fix lint issues
swiftlint --fix
```

- **SwiftFormat runs first**, then SwiftLint — SwiftFormat owns formatting rules, SwiftLint owns semantic rules
- Config files: `.swiftformat` and `.swiftlint.yml` at project root
- CI runs both in strict mode (warnings become errors) with GitHub Actions inline annotations
- SwiftLint excludes `Tests/` — only Sources and Package.swift are linted

## Testing

- Test files mirror source: `FooTests.swift` tests `Foo.swift`
- Run a single test class: `swift test --filter MCSTests.FooTests`
- Tests construct all state inline; no external fixtures or shared setup
- **Important**: `swift test` output does not display in Claude Code's terminal. Redirect to a file and read it: `swift test > .test-output/results.txt 2>&1` then read `.test-output/results.txt`

## Key Design Decisions

- **Pure engine, zero bundled content**: `mcs` ships no templates, hooks, settings, or skills — all features come from external packs users add via `mcs pack add`
- **`mcs sync` is the primary command**: per-project multi-select of registered packs, fully idempotent convergence (add/remove/update), per-project artifact placement. `--global` flag handles global-scope install
- **Per-project artifacts**: skills, hooks, commands, and `settings.local.json` go to `<project>/.claude/`; only brew packages and plugins are global
- **MCP scope defaults to `local`**: per-user, per-project isolation via `claude mcp add -s local` (stored in `~/.claude.json` keyed by project path)
- **Convergent sync**: `ProjectState` records per-pack `PackArtifactRecord` (MCP servers, files, template sections, hook commands, settings keys, brew packages, plugins, gitignore entries); re-running converges to desired state by diffing previous vs. selected packs. `mcs pack remove` discovers all scopes via `ProjectIndex` and runs the same `unconfigurePack()` convergence for each
- **External pack protocol**: `TechPack` protocol with `ExternalPackAdapter` bridging YAML manifests (`techpack.yaml`) to the same install/doctor/sync flows
- **Section markers**: composed files use `<!-- mcs:begin/end -->` HTML comments to separate tool-managed content from user content
- **Settings composition**: each pack's hook entries compose into `<project>/.claude/settings.local.json` as individual `HookGroup` entries
- **Backup for mixed-ownership files**: timestamped backup before modifying files with user content (CLAUDE.local.md); tool-managed files are not backed up since they can be regenerated
- **Component-derived doctor checks**: `ComponentDefinition` is the single source of truth — `deriveDoctorCheck()` auto-generates verification from `installAction`, supplementary checks handle extras
- **Project awareness**: doctor detects project root (walk-up for `.git/`), resolves packs from `.claude/.mcs-project` before falling back to section marker inference, then to global manifest
- **Lockfile support**: `mcs.lock.yaml` pins pack commits for reproducible builds; `--lock` checks out pinned commits, `--update` fetches latest
- **Local packs**: `mcs pack add /path` registers a pack read in-place — no git clone, no `mcs pack update`, no directory deletion on remove. Uses `isLocal: Bool?` on `PackEntry` (backward-compatible) and `commitSHA: "local"` sentinel. Trust verification is skipped since scripts change during development
- **GitHub shorthand**: `mcs pack add user/repo` expands to `https://github.com/user/repo.git`. Filesystem paths are checked before shorthand regex to prevent ambiguity with relative paths like `org/pack`
- **Cross-project reference counting**: `ProjectIndex` (`~/.mcs/projects.yaml`) tracks which projects use which packs; `ResourceRefCounter` checks all scopes before removing shared brew packages or plugins. Conservative by default — if state is unreadable, assume resource is still needed. MCP servers are project-independent (scoped via `-s local`) and skip ref counting
