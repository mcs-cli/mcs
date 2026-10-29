import Foundation

/// Protocol for Claude CLI operations, enabling test mocks to avoid real shell calls.
protocol ClaudeCLI: Sendable {
    /// Whether the Claude CLI is available on the system.
    var isAvailable: Bool { get }
    @discardableResult
    func mcpAdd(name: String, scope: String, arguments: [String], workingDirectory: URL?) -> ShellResult
    @discardableResult
    func mcpRemove(name: String, scope: String, workingDirectory: URL?) -> ShellResult
    @discardableResult
    func pluginMarketplaceAdd(source: String) -> ShellResult
    func pluginMarketplaceList() -> ShellResult
    @discardableResult
    func pluginMarketplaceUpdate(name: String) -> ShellResult
    @discardableResult
    func pluginMarketplaceRemove(name: String) -> ShellResult
    func pluginList(workingDirectory: URL?) -> ShellResult
    @discardableResult
    func pluginInstall(id: String, scope: String, workingDirectory: URL?) -> ShellResult
    @discardableResult
    func pluginRemove(id: String, scope: String, workingDirectory: URL?) -> ShellResult
    @discardableResult
    func pluginUpdate(id: String, scope: String, workingDirectory: URL?) -> ShellResult
}

extension ClaudeCLI {
    /// `claude plugin marketplace list --json`, decoded.
    func marketplaces() throws -> [PluginMarketplace] {
        let result = pluginMarketplaceList()
        guard result.succeeded else {
            throw PluginListing.Failure(errorDescription: String(result.stderr.prefix(200)))
        }
        return try JSONDecoder().decode([PluginMarketplace].self, from: Data(result.stdout.utf8))
    }
}

/// Wrapper for the `claude` CLI to manage MCP servers and plugins.
struct ClaudeIntegration: ClaudeCLI {
    let shell: any ShellRunning

    var isAvailable: Bool {
        shell.commandExists(Constants.CLI.claudeCommand)
    }

    /// The claude CLI command, with CLAUDECODE unset to avoid nesting checks.
    private var claudeEnv: [String: String] {
        ["CLAUDECODE": ""]
    }

    // MARK: - MCP Servers

    /// Add an MCP server (removes existing entry first for idempotence).
    ///
    /// `workingDirectory` picks the project a `local`- or `project`-scoped server belongs to:
    /// the CLI keys those scopes by the directory it runs in.
    @discardableResult
    func mcpAdd(
        name: String,
        scope: String = "local",
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) -> ShellResult {
        // Remove first to avoid "already exists" errors
        mcpRemove(name: name, scope: scope, workingDirectory: workingDirectory)

        var args = ["mcp", "add", "-s", scope, name]
        args.append(contentsOf: arguments)
        return shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand] + args,
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }

    /// Remove an MCP server. See `mcpAdd` for how `workingDirectory` selects the project.
    @discardableResult
    func mcpRemove(name: String, scope: String = "local", workingDirectory: URL? = nil) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "mcp", "remove", "-s", scope, name],
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }

    // MARK: - Plugins

    /// Register a plugin marketplace from a GitHub `org/repo`, a URL or a local directory.
    @discardableResult
    func pluginMarketplaceAdd(source: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "add", source],
            additionalEnvironment: claudeEnv
        )
    }

    /// `claude plugin marketplace list --json`.
    func pluginMarketplaceList() -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "list", "--json"],
            additionalEnvironment: claudeEnv
        )
    }

    /// Refresh one marketplace's catalog from its source.
    @discardableResult
    func pluginMarketplaceUpdate(name: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "update", name],
            additionalEnvironment: claudeEnv
        )
    }

    /// Unregister a marketplace. Claude Code uninstalls its plugins from every scope.
    @discardableResult
    func pluginMarketplaceRemove(name: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "remove", name],
            additionalEnvironment: claudeEnv
        )
    }

    /// `claude plugin list --json`. Run in a project, `enabled` reflects that project's settings.
    func pluginList(workingDirectory: URL?) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "list", "--json"],
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }

    /// Install a plugin by its `name@marketplace` id. A `local` install belongs to the project
    /// `workingDirectory` names, as with `mcpAdd`.
    @discardableResult
    func pluginInstall(id: String, scope: String, workingDirectory: URL?) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "install", id, "-s", scope],
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }

    /// Uninstall a plugin from one scope. See `pluginInstall` for `workingDirectory`.
    @discardableResult
    func pluginRemove(id: String, scope: String, workingDirectory: URL?) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "uninstall", id, "-s", scope],
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }

    /// Update a plugin at one scope to its marketplace's current version. See `pluginInstall` for `workingDirectory`.
    @discardableResult
    func pluginUpdate(id: String, scope: String, workingDirectory: URL?) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "update", id, "-s", scope],
            workingDirectory: workingDirectory?.path,
            additionalEnvironment: claudeEnv
        )
    }
}
