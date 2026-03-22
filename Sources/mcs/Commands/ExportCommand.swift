import ArgumentParser
import Foundation

/// Export current Claude Code configuration to a techpack.yaml pack directory.
///
/// This wizard reads live configuration files (settings, MCP servers, hooks,
/// skills, CLAUDE.md) and generates a reusable, shareable tech pack.
struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export current configuration as a tech pack"
    )

    @Argument(help: "Output directory for the generated pack")
    var outputDir: String

    @Flag(name: .long, help: "Export global scope (~/.claude/) instead of project scope")
    var global = false

    @Option(name: .long, help: "Pack identifier (prompted if omitted)")
    var identifier: String?

    @Flag(name: .long, help: "Include everything without prompts")
    var nonInteractive = false

    @Flag(name: .long, help: "Preview what would be exported without writing")
    var dryRun = false

    func run() throws {
        let env = Environment()
        let output = CLIOutput()

        output.header("Export Configuration")

        // 1. Determine scope
        let scope: ConfigurationDiscovery.Scope
        if global {
            scope = .global
            output.info("  Scope: global (~/.claude/)")
        } else {
            guard let projectRoot = ProjectDetector.findProjectRoot() else {
                throw ExportError.noProjectFound
            }
            scope = .project(projectRoot)
            output.info("  Scope: project (\(projectRoot.lastPathComponent))")
        }

        // 2. Discover configuration
        let discovery = ConfigurationDiscovery(environment: env, output: output)
        let config = discovery.discover(scope: scope)

        guard !config.isEmpty else {
            throw ExportError.noConfigurationFound
        }

        output.plain("")
        printDiscoverySummary(config, output: output)

        // 3. Select artifacts
        let selection: Selection = if nonInteractive {
            selectAll(from: config)
        } else {
            interactiveSelect(config: config, output: output)
        }

        // 4. Gather metadata
        let metadata: ManifestBuilder.Metadata = if nonInteractive {
            ManifestBuilder.Metadata(
                identifier: identifier ?? "exported-pack",
                displayName: identifier?.replacingOccurrences(of: "-", with: " ").capitalized ?? "Exported Pack",
                description: "Exported Claude Code configuration",
                author: gitAuthorName(environment: env)
            )
        } else {
            gatherMetadata(environment: env, output: output)
        }

        // 5. Build manifest
        let builder = ManifestBuilder()
        let options = ManifestBuilder.BuildOptions(
            selectedMCPServers: selection.mcpServers,
            selectedHookFiles: selection.hookFiles,
            selectedSkillFiles: selection.skillFiles,
            selectedCommandFiles: selection.commandFiles,
            selectedAgentFiles: selection.agentFiles,
            selectedPlugins: selection.plugins,
            selectedSections: selection.sections,
            includeUserContent: selection.includeUserContent,
            includeGitignore: selection.includeGitignore,
            includeSettings: selection.includeSettings
        )
        let result = builder.build(from: config, metadata: metadata, options: options)

        let outputURL = URL(fileURLWithPath: outputDir).standardizedFileURL

        // 6. Write or preview
        let writer = PackWriter(output: output)
        if dryRun {
            output.plain("")
            writer.preview(result: result, outputDir: outputURL)
        } else {
            output.plain("")
            output.sectionHeader("Writing pack to \(outputURL.path)")
            try writer.write(result: result, to: outputURL)

            output.plain("")
            output.success("Pack exported successfully!")
            printPostExportHints(config: config, output: output)
        }
    }

    // MARK: - Discovery Summary

    private func printDiscoverySummary(_ config: ConfigurationDiscovery.DiscoveredConfiguration, output: CLIOutput) {
        output.sectionHeader("Discovered configuration:")
        if !config.mcpServers.isEmpty {
            output.plain("  MCP servers:   \(config.mcpServers.map(\.name).joined(separator: ", "))")
        }
        if !config.hookFiles.isEmpty {
            output.plain("  Hook files:    \(config.hookFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.skillFiles.isEmpty {
            output.plain("  Skills:        \(config.skillFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.commandFiles.isEmpty {
            output.plain("  Commands:      \(config.commandFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.agentFiles.isEmpty {
            output.plain("  Agents:        \(config.agentFiles.map(\.filename).joined(separator: ", "))")
        }
        if !config.plugins.isEmpty {
            output.plain("  Plugins:       \(config.plugins.joined(separator: ", "))")
        }
        if !config.claudeSections.isEmpty {
            output.plain("  CLAUDE.md:     \(config.claudeSections.count) managed section(s)")
        }
        if config.claudeUserContent != nil {
            output.plain("  CLAUDE.md:     user content present")
        }
        if !config.gitignoreEntries.isEmpty {
            output.plain("  Gitignore:     \(config.gitignoreEntries.count) entries")
        }
        if config.remainingSettingsData != nil {
            output.plain("  Settings:      additional keys present")
        }
        output.plain("")
    }

    // MARK: - Selection

    struct Selection {
        var mcpServers: Set<String>
        var hookFiles: Set<String>
        var skillFiles: Set<String>
        var commandFiles: Set<String>
        var agentFiles: Set<String>
        var plugins: Set<String>
        var sections: Set<String>
        var includeUserContent: Bool
        var includeGitignore: Bool
        var includeSettings: Bool
    }

    private func selectAll(from config: ConfigurationDiscovery.DiscoveredConfiguration) -> Selection {
        Selection(
            mcpServers: Set(config.mcpServers.map(\.name)),
            hookFiles: Set(config.hookFiles.map(\.filename)),
            skillFiles: Set(config.skillFiles.map(\.filename)),
            commandFiles: Set(config.commandFiles.map(\.filename)),
            agentFiles: Set(config.agentFiles.map(\.filename)),
            plugins: Set(config.plugins),
            sections: Set(config.claudeSections.map(\.sectionIdentifier)),
            includeUserContent: config.claudeUserContent != nil,
            includeGitignore: !config.gitignoreEntries.isEmpty,
            includeSettings: config.remainingSettingsData != nil
        )
    }

    private enum ItemCategory { case mcp, hooks, skills, commands, agents, plugins, sections }
    private enum SentinelKey { case userContent, gitignore, settings }

    private func interactiveSelect(
        config: ConfigurationDiscovery.DiscoveredConfiguration,
        output: CLIOutput
    ) -> Selection {
        var groups: [SelectableGroup] = []
        var counter = 0
        var mappings: [ItemCategory: [Int: String]] = [:]
        var sentinels: [SentinelKey: Int] = [:]

        // Helper: append a group of named items, tracking index→name mappings by category
        func appendItems(
            _ items: [(name: String, description: String)],
            category: ItemCategory
        ) -> [SelectableItem] {
            items.map { item in
                counter += 1
                mappings[category, default: [:]][counter] = item.name
                return SelectableItem(number: counter, name: item.name, description: item.description, isSelected: true)
            }
        }

        // Helper: create a single toggle item, tracked as a sentinel
        func appendSentinel(name: String, description: String, key: SentinelKey) -> SelectableItem {
            counter += 1
            sentinels[key] = counter
            return SelectableItem(number: counter, name: name, description: description, isSelected: true)
        }

        // MCP Servers
        if !config.mcpServers.isEmpty {
            let items = appendItems(config.mcpServers.map { server in
                let warn = server.sensitiveEnvVarNames.isEmpty ? "" : " (contains sensitive env vars)"
                return (name: server.name, description: server.isHTTP ? "HTTP MCP server\(warn)" : (server.command ?? "MCP server") + warn)
            }, category: .mcp)
            groups.append(SelectableGroup(title: "MCP Servers", items: items, requiredItems: []))
        }

        // Hook files
        if !config.hookFiles.isEmpty {
            let items = appendItems(config.hookFiles.map { hook in
                let eventInfo = hook.hookRegistration.map { " → \($0.event)" } ?? " (unknown event)"
                return (name: hook.filename, description: "Hook script\(eventInfo)")
            }, category: .hooks)
            groups.append(SelectableGroup(title: "Hooks", items: items, requiredItems: []))
        }

        // Skills
        if !config.skillFiles.isEmpty {
            let items = appendItems(config.skillFiles.map { (name: $0.filename, description: "Skill file") }, category: .skills)
            groups.append(SelectableGroup(title: "Skills", items: items, requiredItems: []))
        }

        // Commands
        if !config.commandFiles.isEmpty {
            let items = appendItems(config.commandFiles.map { (name: $0.filename, description: "Slash command") }, category: .commands)
            groups.append(SelectableGroup(title: "Commands", items: items, requiredItems: []))
        }

        // Agents
        if !config.agentFiles.isEmpty {
            let items = appendItems(config.agentFiles.map { (name: $0.filename, description: "Subagent") }, category: .agents)
            groups.append(SelectableGroup(title: "Agents", items: items, requiredItems: []))
        }

        // Plugins
        if !config.plugins.isEmpty {
            let items = appendItems(config.plugins.map { (name: $0, description: "Plugin") }, category: .plugins)
            groups.append(SelectableGroup(title: "Plugins", items: items, requiredItems: []))
        }

        // CLAUDE.md sections + user content
        var claudeItems: [SelectableItem] = []
        if !config.claudeSections.isEmpty {
            claudeItems += appendItems(
                config.claudeSections.map { (name: $0.sectionIdentifier, description: "Managed section") },
                category: .sections
            )
        }
        if config.claudeUserContent != nil {
            claudeItems.append(appendSentinel(name: "User content", description: "Content outside managed sections", key: .userContent))
        }
        if !claudeItems.isEmpty {
            groups.append(SelectableGroup(title: "CLAUDE.md Content", items: claudeItems, requiredItems: []))
        }

        // Gitignore + Settings
        var extraItems: [SelectableItem] = []
        if !config.gitignoreEntries.isEmpty {
            extraItems.append(
                appendSentinel(name: "Gitignore entries", description: "\(config.gitignoreEntries.count) entries", key: .gitignore)
            )
        }
        if config.remainingSettingsData != nil {
            extraItems.append(appendSentinel(name: "Additional settings", description: "env vars, permissions, etc.", key: .settings))
        }
        if !extraItems.isEmpty {
            groups.append(SelectableGroup(title: "Other", items: extraItems, requiredItems: []))
        }

        // Run multi-select
        let selected = output.multiSelect(groups: &groups)

        func selectedNames(_ category: ItemCategory) -> Set<String> {
            guard let mapping = mappings[category] else { return [] }
            return Set(mapping.filter { selected.contains($0.key) }.values)
        }

        return Selection(
            mcpServers: selectedNames(.mcp),
            hookFiles: selectedNames(.hooks),
            skillFiles: selectedNames(.skills),
            commandFiles: selectedNames(.commands),
            agentFiles: selectedNames(.agents),
            plugins: selectedNames(.plugins),
            sections: selectedNames(.sections),
            includeUserContent: sentinels[.userContent].map { selected.contains($0) } ?? false,
            includeGitignore: sentinels[.gitignore].map { selected.contains($0) } ?? false,
            includeSettings: sentinels[.settings].map { selected.contains($0) } ?? false
        )
    }

    // MARK: - Metadata

    private func gatherMetadata(environment env: Environment, output: CLIOutput) -> ManifestBuilder.Metadata {
        output.sectionHeader("Pack metadata:")

        let defaultID = identifier ?? "my-pack"
        let id = output.promptInline("Pack identifier", default: defaultID)
        let name = output.promptInline("Display name", default: id.replacingOccurrences(of: "-", with: " ").capitalized)
        let desc = output.promptInline("Description", default: "Exported Claude Code configuration")
        let defaultAuthor = gitAuthorName(environment: env)
        let author = output.promptInline("Author", default: defaultAuthor)

        output.plain("")

        return ManifestBuilder.Metadata(
            identifier: id,
            displayName: name,
            description: desc,
            author: author.isEmpty ? nil : author
        )
    }

    // MARK: - Post-export Hints

    private func printPostExportHints(
        config: ConfigurationDiscovery.DiscoveredConfiguration,
        output: CLIOutput
    ) {
        let resolvedPath = URL(fileURLWithPath: outputDir).standardizedFileURL.path
        var hints: [String] = []

        // Check for MCP servers that might need brew (dynamic symlink resolution)
        let detectedFormulas = Set(config.mcpServers.compactMap { server -> String? in
            guard let command = server.command else { return nil }
            return Homebrew.detectFormula(for: command)
        })
        if !detectedFormulas.isEmpty {
            hints.append("Some MCP servers may need brew packages: \(detectedFormulas.sorted().joined(separator: ", "))")
            hints.append("Add `brew: <package>` components to your techpack.yaml if needed")
        }

        // Check for hooks without matched events
        let unmatchedHooks = config.hookFiles.filter { $0.hookRegistration == nil }
        if !unmatchedHooks.isEmpty {
            hints.append("Hook files without matched events: \(unmatchedHooks.map(\.filename).joined(separator: ", "))")
            hints.append("Add `hookEvent:` to these components in techpack.yaml")
        }

        // Check for sensitive env vars
        let sensitiveServers = config.mcpServers.filter { !$0.sensitiveEnvVarNames.isEmpty }
        if !sensitiveServers.isEmpty {
            hints.append("Sensitive env vars were replaced with __PLACEHOLDER__ tokens")
            hints.append("Users will be prompted for values during `mcs sync`")
        }

        if !hints.isEmpty {
            output.plain("")
            output.warn("Review notes:")
            for hint in hints {
                output.plain("  - \(hint)")
            }
        }

        output.plain("")
        output.info("Next steps:")
        output.plain("  1. Review the generated techpack.yaml")
        output.plain("  2. Test with: mcs pack add \(resolvedPath)")
        output.plain("  3. Share via git: push to a repository and use mcs pack add <url>")
    }

    // MARK: - Helpers

    private func gitAuthorName(environment: Environment) -> String? {
        let result = ShellRunner(environment: environment).run(environment.gitPath, arguments: ["config", "user.name"])
        return result.succeeded ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
