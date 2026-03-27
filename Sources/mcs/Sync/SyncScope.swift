import Foundation

/// Pure data describing the target scope for a sync operation.
///
/// Captures all path-level and flag-level differences between project-scoped
/// and global-scoped sync, so the unified `Configurator` never needs to branch
/// on scope identity for trivially parameterizable values.
struct SyncScope {
    /// Display label for output messages ("Project" or "Global").
    let label: String

    /// The target directory for artifact installation.
    /// Project: `<project>/.claude/`; Global: `~/.claude/`.
    let targetPath: URL

    /// File path for the project state file.
    /// Project: `<project>/.claude/.mcs-project`; Global: `~/.mcs/global-state.json`.
    let stateFile: URL

    /// Path to the composed settings file.
    /// Project: `<project>/.claude/settings.local.json`; Global: `~/.claude/settings.json`.
    let settingsPath: URL

    /// Path to the composed CLAUDE markdown file.
    /// Project: `<project>/CLAUDE.local.md`; Global: `~/.claude/CLAUDE.md`.
    let claudeFilePath: URL

    /// Identifier for this scope in cross-cutting concerns (project index, ref counting).
    /// Project: the project path string; Global: `"__global__"`.
    let scopeIdentifier: String

    /// MCP scope override applied to all MCP server registrations.
    /// `nil` = use the pack's declared scope (project default); `"user"` = global scope.
    let mcpScopeOverride: String?

    /// Whether to scan template content (in addition to copyPackFile sources)
    /// for undeclared placeholders.
    let includeTemplatesInScan: Bool

    /// Whether to run `pack.configureProject(at:context:)` hooks after artifact installation.
    let runConfigureProjectHooks: Bool

    /// Whether this is the global scope (affects template value resolution context).
    let isGlobalScope: Bool

    /// The sync hint shown in error/recovery messages (e.g. `"mcs sync"` or `"mcs sync --global"`).
    let syncHint: String

    /// Suffix for output messages: `" (global)"` when in global scope, empty otherwise.
    let labelSuffix: String

    /// Prefix for hook commands in settings (e.g. `"bash .claude/hooks/"` or `"bash ~/.claude/hooks/"`).
    let hookCommandPrefix: String

    /// Display prefix for file paths in dry-run output (e.g. `".claude/"` or `"~/.claude/"`).
    let fileDisplayPrefix: String
}

// MARK: - Factory Methods

extension SyncScope {
    /// Create a project-scoped sync context.
    static func project(at projectPath: URL, environment _: Environment) -> SyncScope {
        let claudeDir = projectPath.appendingPathComponent(Constants.FileNames.claudeDirectory)
        return SyncScope(
            label: "Project",
            targetPath: claudeDir,
            stateFile: claudeDir.appendingPathComponent(Constants.FileNames.mcsProject),
            settingsPath: claudeDir.appendingPathComponent(Constants.FileNames.settingsLocal),
            claudeFilePath: projectPath.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            scopeIdentifier: projectPath.path,
            mcpScopeOverride: nil,
            includeTemplatesInScan: true,
            runConfigureProjectHooks: true,
            isGlobalScope: false,
            syncHint: "mcs sync",
            labelSuffix: "",
            hookCommandPrefix: "bash .claude/hooks/",
            fileDisplayPrefix: ".claude/"
        )
    }

    /// Create a global-scoped sync context.
    static func global(environment: Environment) -> SyncScope {
        SyncScope(
            label: "Global",
            targetPath: environment.claudeDirectory,
            stateFile: environment.globalStateFile,
            settingsPath: environment.claudeSettings,
            claudeFilePath: environment.globalClaudeMD,
            scopeIdentifier: ProjectIndex.globalSentinel,
            mcpScopeOverride: Constants.MCPScope.user,
            includeTemplatesInScan: false,
            runConfigureProjectHooks: false,
            isGlobalScope: true,
            syncHint: "mcs sync --global",
            labelSuffix: " (global)",
            hookCommandPrefix: "bash ~/.claude/hooks/",
            fileDisplayPrefix: "~/.claude/"
        )
    }
}
