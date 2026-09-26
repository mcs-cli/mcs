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
    func pluginMarketplaceAdd(repo: String) -> ShellResult
    @discardableResult
    func pluginInstall(ref: PluginRef) -> ShellResult
    @discardableResult
    func pluginRemove(ref: PluginRef) -> ShellResult
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

    /// Register a plugin marketplace.
    @discardableResult
    func pluginMarketplaceAdd(repo: String) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "marketplace", "add", repo],
            additionalEnvironment: claudeEnv
        )
    }

    /// Install a plugin (registers marketplace first).
    @discardableResult
    func pluginInstall(ref: PluginRef) -> ShellResult {
        pluginMarketplaceAdd(repo: ref.marketplaceRepo)

        return shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "install", ref.bareName],
            additionalEnvironment: claudeEnv
        )
    }

    /// Remove a plugin.
    @discardableResult
    func pluginRemove(ref: PluginRef) -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "plugin", "remove", ref.bareName],
            additionalEnvironment: claudeEnv
        )
    }
}
