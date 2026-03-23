import Foundation

/// Protocol for Claude CLI operations, enabling test mocks to avoid real shell calls.
protocol ClaudeCLI: Sendable {
    /// Whether the Claude CLI is available on the system.
    var isAvailable: Bool { get }
    @discardableResult
    func mcpAdd(name: String, scope: String, arguments: [String]) -> ShellResult
    @discardableResult
    func mcpRemove(name: String, scope: String) -> ShellResult
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
    @discardableResult
    func mcpAdd(
        name: String,
        scope: String = "local",
        arguments: [String] = []
    ) -> ShellResult {
        // Remove first to avoid "already exists" errors
        mcpRemove(name: name, scope: scope)

        var args = ["mcp", "add", "-s", scope, name]
        args.append(contentsOf: arguments)
        return shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand] + args,
            additionalEnvironment: claudeEnv
        )
    }

    /// Remove an MCP server.
    @discardableResult
    func mcpRemove(name: String, scope: String = "local") -> ShellResult {
        shell.run(
            Constants.CLI.env,
            arguments: [Constants.CLI.claudeCommand, "mcp", "remove", "-s", scope, name],
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
