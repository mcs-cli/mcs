/// Centralized string constants used across multiple files.
/// Only strings that appear in 2+ files belong here; single-use
/// constants may be included when they form a logical group with
/// multi-use siblings. Single-file constants should remain local
/// to their type.
enum Constants {
    // MARK: - File Names

    enum FileNames {
        /// The per-project instructions file managed by `mcs sync`.
        static let claudeLocalMD = "CLAUDE.local.md"

        /// The global instructions file managed by `mcs sync --global`.
        static let claudeMD = "CLAUDE.md"

        /// The per-project state file tracking configured packs.
        static let mcsProject = ".mcs-project"

        /// The Claude Code configuration directory name.
        static let claudeDirectory = ".claude"

        /// The Claude Code JSON configuration file.
        static let claudeJSON = ".claude.json"

        /// The global state file tracking globally-installed packs and artifacts.
        static let globalState = "global-state.json"

        /// The process lock file preventing concurrent mcs execution.
        static let mcsLock = "lock"

        /// The update check cache file (timestamp + results).
        static let updateCheckCache = "update-check.json"

        /// The per-project settings file written by `mcs sync`.
        static let settingsLocal = "settings.local.json"

        /// The user preferences file.
        static let mcsConfig = "config.yaml"
    }

    // MARK: - CLI

    enum CLI {
        /// The `/usr/bin/env` path used to resolve commands from PATH.
        static let env = "/usr/bin/env"

        /// The `/usr/bin/which` path for command resolution (POSIX bootstrap).
        static let which = "/usr/bin/which"

        /// The `/bin/bash` path for shell command execution.
        static let bash = "/bin/bash"

        /// The Claude Code CLI binary name.
        static let claudeCommand = "claude"
    }

    // MARK: - JSON Keys

    enum JSONKeys {
        /// The top-level key in `~/.claude.json` for MCP server registrations.
        static let mcpServers = "mcpServers"
        /// The top-level key in `~/.claude.json` for per-project settings.
        static let projects = "projects"
    }

    // MARK: - External Packs

    enum ExternalPacks {
        /// The manifest filename for external tech packs.
        static let manifestFilename = "techpack.yaml"

        /// The registry filename tracking installed packs.
        static let registryFilename = "registry.yaml"

        /// The directory name for pack checkouts.
        static let packsDirectory = "packs"

        /// Sentinel value for `commitSHA` on local (non-git) packs.
        static let localCommitSentinel = "local"

        /// The project index filename tracking cross-project pack usage.
        static let projectsIndexFilename = "projects.yaml"
    }

    // MARK: - Hooks

    /// All Claude Code hook event types.
    /// Source: https://docs.anthropic.com/en/docs/claude-code/hooks
    enum HookEvent: String, CaseIterable, Codable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case notification = "Notification"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case teammateIdle = "TeammateIdle"
        case taskCompleted = "TaskCompleted"
        case configChange = "ConfigChange"
        case instructionsLoaded = "InstructionsLoaded"
        case worktreeCreate = "WorktreeCreate"
        case worktreeRemove = "WorktreeRemove"
        case preCompact = "PreCompact"
        case postCompact = "PostCompact"
        case sessionEnd = "SessionEnd"
        case elicitation = "Elicitation"
        case elicitationResult = "ElicitationResult"

        /// Set of all valid event raw values (for string-based validation).
        static let validRawValues: Set<String> = Set(allCases.map(\.rawValue))
    }

    // MARK: - MCP Scopes

    enum MCPScope {
        /// Per-user, per-project isolation (default for project scope).
        static let local = "local"

        /// Cross-project scope (used for global scope).
        static let user = "user"
    }

    // MARK: - MCS Repository

    enum MCSRepo {
        /// The HTTPS URL for the mcs git repository (used for version checks).
        static let url = "https://github.com/mcs-cli/mcs.git"

        /// The Homebrew formula name for mcs.
        static let brewFormula = "mcs-cli/tap/mcs"
    }

    // MARK: - Plugins

    enum Plugins {
        /// The official Anthropic plugin marketplace identifier.
        static let officialMarketplace = "claude-plugins-official"

        /// The GitHub repo path for the official plugin marketplace.
        static let officialMarketplaceRepo = "anthropics/claude-plugins-official"
    }
}

// MARK: - String Helpers

extension String {
    /// Strips a trailing `.git` suffix, e.g. `"repo.git"` → `"repo"`.
    var strippingGitSuffix: String {
        hasSuffix(".git") ? String(dropLast(4)) : self
    }
}
