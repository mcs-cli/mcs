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

    enum Hooks {
        /// All Claude Code hook event names (PascalCase).
        /// Source: https://docs.anthropic.com/en/docs/claude-code/hooks
        static let validEvents: Set<String> = [
            "SessionStart", "UserPromptSubmit",
            "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
            "Notification",
            "SubagentStart", "SubagentStop",
            "Stop",
            "TeammateIdle", "TaskCompleted",
            "ConfigChange",
            "WorktreeCreate", "WorktreeRemove",
            "PreCompact", "SessionEnd",
        ]
    }

    // MARK: - MCP Scopes

    enum MCPScope {
        /// Per-user, per-project isolation (default for project scope).
        static let local = "local"

        /// Cross-project scope (used for global scope).
        static let user = "user"
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
