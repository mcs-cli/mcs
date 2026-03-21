import Foundation
@testable import mcs
import Testing

struct ManifestBuilderTests {
    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-manifest-builder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Round-trip: build → YAML → load → normalized → validate

    @Test("Round-trip preserves all artifact types through YAML")
    func roundTripFull() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create real files for hooks/skills/commands (FileCopy needs them)
        let hookURL = tmpDir.appendingPathComponent("pre_tool_use.sh")
        try "#!/bin/bash\nexit 0".write(to: hookURL, atomically: true, encoding: .utf8)
        let skillURL = tmpDir.appendingPathComponent("review")
        try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
        let cmdURL = tmpDir.appendingPathComponent("deploy.md")
        try "Deploy command".write(to: cmdURL, atomically: true, encoding: .utf8)

        // Build representative DiscoveredConfiguration
        var config = ConfigurationDiscovery.DiscoveredConfiguration()

        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "docs-server", command: "npx",
                args: ["-y", "docs-mcp@latest"],
                env: ["API_KEY": "secret123", "LOG_LEVEL": "debug"],
                url: nil, scope: "local"
            ),
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "remote", command: nil, args: [],
                env: [:],
                url: "https://example.com/mcp", scope: "user"
            ),
        ]

        config.hookFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "pre_tool_use.sh",
                absolutePath: hookURL,
                hookEvent: "PreToolUse"
            ),
        ]

        config.skillFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "review",
                absolutePath: skillURL
            ),
        ]

        config.commandFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "deploy.md",
                absolutePath: cmdURL
            ),
        ]

        let agentURL = tmpDir.appendingPathComponent("code-reviewer.md")
        try "---\nname: Code Reviewer\n---\nReview code".write(to: agentURL, atomically: true, encoding: .utf8)
        config.agentFiles = [
            ConfigurationDiscovery.DiscoveredFile(
                filename: "code-reviewer.md",
                absolutePath: agentURL
            ),
        ]

        config.plugins = ["pr-review-toolkit@claude-plugins-official"]

        config.gitignoreEntries = [".env", "*.log"]

        config.claudeSections = [
            ConfigurationDiscovery.DiscoveredClaudeSection(
                sectionIdentifier: "test-pack.instructions",
                content: "## Build & Test\nAlways use the build tool."
            ),
        ]

        config.claudeUserContent = "Custom user instructions"

        config.remainingSettingsData = try JSONSerialization.data(
            withJSONObject: ["env": ["THINKING_BUDGET": "10000"]],
            options: [.prettyPrinted, .sortedKeys]
        )

        let metadata = ManifestBuilder.Metadata(
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test tech pack for round-trip validation",
            author: "Test Author"
        )

        let result = ManifestBuilder().build(
            from: config,
            metadata: metadata,
            options: ManifestBuilder.BuildOptions(
                selectedMCPServers: Set(config.mcpServers.map(\.name)),
                selectedHookFiles: Set(config.hookFiles.map(\.filename)),
                selectedSkillFiles: Set(config.skillFiles.map(\.filename)),
                selectedCommandFiles: Set(config.commandFiles.map(\.filename)),
                selectedAgentFiles: Set(config.agentFiles.map(\.filename)),
                selectedPlugins: Set(config.plugins),
                selectedSections: Set(config.claudeSections.map(\.sectionIdentifier)),
                includeUserContent: true,
                includeGitignore: true,
                includeSettings: true
            )
        )

        // 1. Verify typed manifest metadata
        let manifest = result.manifest
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "test-pack")
        #expect(manifest.displayName == "Test Pack")
        #expect(manifest.author == "Test Author")

        // 2. Write YAML to file, parse back, normalize, validate
        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)

        let loaded = try ExternalPackManifest.load(from: yamlFile)
        let normalized = try loaded.normalized()
        try normalized.validate()

        // 3. Verify component counts — 2 MCP + 1 hook + 1 skill + 1 cmd + 1 agent + 1 plugin + 1 settings + 1 gitignore = 9
        let components = try #require(normalized.components)
        #expect(components.count == 9)

        // 4. Verify MCP servers
        let mcpComps = components.filter { $0.type == .mcpServer }
        #expect(mcpComps.count == 2)

        // Stdio server with sensitive env var → placeholder
        let stdioComp = try #require(mcpComps.first { $0.id.contains("docs-server") })
        guard case let .mcpServer(stdioConfig) = stdioComp.installAction else {
            Issue.record("Expected mcpServer install action for docs-server")
            return
        }
        #expect(stdioConfig.command == "npx")
        #expect(stdioConfig.args == ["-y", "docs-mcp@latest"])
        #expect(stdioConfig.env?["API_KEY"] == "__API_KEY__")
        #expect(stdioConfig.env?["LOG_LEVEL"] == "debug")

        // HTTP server with user scope
        let httpComp = try #require(mcpComps.first { $0.id.contains("remote") })
        guard case let .mcpServer(httpConfig) = httpComp.installAction else {
            Issue.record("Expected mcpServer install action for remote")
            return
        }
        #expect(httpConfig.url == "https://example.com/mcp")
        #expect(httpConfig.scope == .user)

        // 5. Verify hook with hookEvent
        let hookComp = try #require(components.first { $0.type == .hookFile })
        #expect(hookComp.hookEvent == "PreToolUse")
        guard case let .copyPackFile(hookFile) = hookComp.installAction else {
            Issue.record("Expected copyPackFile for hook")
            return
        }
        #expect(hookFile.source == "hooks/pre_tool_use.sh")
        #expect(hookFile.destination == "pre_tool_use.sh")
        #expect(hookFile.fileType == .hook)

        // 6. Verify skill
        let skillComp = try #require(components.first { $0.type == .skill })
        guard case let .copyPackFile(skillFile) = skillComp.installAction else {
            Issue.record("Expected copyPackFile for skill")
            return
        }
        #expect(skillFile.fileType == .skill)

        // 7. Verify command
        let cmdComp = try #require(components.first { $0.type == .command })
        guard case let .copyPackFile(cmdFile) = cmdComp.installAction else {
            Issue.record("Expected copyPackFile for command")
            return
        }
        #expect(cmdFile.fileType == .command)

        // 8. Verify agent
        let agentComp = try #require(components.first { $0.type == .agent })
        guard case let .copyPackFile(agentFile) = agentComp.installAction else {
            Issue.record("Expected copyPackFile for agent")
            return
        }
        #expect(agentFile.fileType == .agent)
        #expect(agentFile.destination == "code-reviewer.md")

        // 9. Verify plugin
        let pluginComp = try #require(components.first { $0.type == .plugin })
        guard case let .plugin(pluginName) = pluginComp.installAction else {
            Issue.record("Expected plugin install action")
            return
        }
        #expect(pluginName == "pr-review-toolkit@claude-plugins-official")

        // 10. Verify settings and gitignore (both .configuration type)
        let configComps = components.filter { $0.type == .configuration }
        #expect(configComps.count == 2)
        let settingsComp = configComps.first { $0.id.contains("settings") }
        #expect(settingsComp?.isRequired == true)
        let gitignoreComp = configComps.first { $0.id.contains("gitignore") }
        #expect(gitignoreComp?.isRequired == true)
        guard case let .gitignoreEntries(entries) = gitignoreComp?.installAction else {
            Issue.record("Expected gitignoreEntries install action")
            return
        }
        #expect(entries.contains(".env"))
        #expect(entries.contains("*.log"))

        // 11. Verify templates (section + user content = 2)
        let templates = try #require(normalized.templates)
        #expect(templates.count == 2)

        // 12. Verify prompts (auto-generated for API_KEY)
        let prompts = try #require(normalized.prompts)
        #expect(prompts.count == 1)
        #expect(prompts[0].key == "API_KEY")
        #expect(prompts[0].type == .input)

        // 13. Verify side-channel outputs
        #expect(result.filesToCopy.count == 4) // hook + skill + command + agent
        #expect(result.settingsToWrite != nil)
        #expect(result.templateFiles.count == 2)
    }

    // MARK: - Empty configuration

    @Test("Empty configuration produces valid minimal manifest")
    func emptyConfigRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = ConfigurationDiscovery.DiscoveredConfiguration()
        let metadata = ManifestBuilder.Metadata(
            identifier: "empty-pack",
            displayName: "Empty Pack",
            description: "No artifacts",
            author: nil
        )

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            options: ManifestBuilder.BuildOptions(
                selectedMCPServers: [], selectedHookFiles: [], selectedSkillFiles: [],
                selectedCommandFiles: [], selectedAgentFiles: [], selectedPlugins: [], selectedSections: [],
                includeUserContent: false, includeGitignore: false, includeSettings: false
            )
        )

        // Typed manifest should have no components
        #expect(result.manifest.components == nil)
        #expect(result.manifest.templates == nil)
        #expect(result.manifest.prompts == nil)
        #expect(result.manifest.author == nil)

        // YAML round-trip should still parse and validate
        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)

        let loaded = try ExternalPackManifest.load(from: yamlFile)
        let normalized = try loaded.normalized()
        try normalized.validate()

        #expect(normalized.identifier == "empty-pack")
    }

    // MARK: - Typed manifest direct assertion

    @Test("BuildResult exposes typed manifest matching input")
    func typedManifestDirectAssertion() throws {
        var config = ConfigurationDiscovery.DiscoveredConfiguration()
        config.plugins = ["my-plugin@org"]
        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "test-server", command: "uvx",
                args: ["test-mcp"],
                env: ["TOKEN": "secret"],
                url: nil, scope: "local"
            ),
        ]

        let metadata = ManifestBuilder.Metadata(
            identifier: "direct-test",
            displayName: "Direct Test",
            description: "Test typed manifest",
            author: "Tester"
        )

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            options: ManifestBuilder.BuildOptions(
                selectedMCPServers: Set(config.mcpServers.map(\.name)),
                selectedHookFiles: [], selectedSkillFiles: [],
                selectedCommandFiles: [], selectedAgentFiles: [],
                selectedPlugins: Set(config.plugins),
                selectedSections: [],
                includeUserContent: false, includeGitignore: false, includeSettings: false
            )
        )

        let manifest = result.manifest
        #expect(manifest.identifier == "direct-test")
        #expect(manifest.author == "Tester")

        let components = try #require(manifest.components)
        #expect(components.count == 2) // 1 MCP + 1 plugin

        // MCP server should have TOKEN replaced with placeholder
        let mcpComp = try #require(components.first { $0.type == .mcpServer })
        guard case let .mcpServer(mcpConfig) = mcpComp.installAction else {
            Issue.record("Expected mcpServer action")
            return
        }
        #expect(mcpConfig.command == "uvx")
        #expect(mcpConfig.env?["TOKEN"] == "__TOKEN__")

        // Plugin
        let pluginComp = try #require(components.first { $0.type == .plugin })
        guard case let .plugin(name) = pluginComp.installAction else {
            Issue.record("Expected plugin action")
            return
        }
        #expect(name == "my-plugin@org")

        // Prompt auto-generated for TOKEN
        let prompts = try #require(manifest.prompts)
        #expect(prompts.count == 1)
        #expect(prompts[0].key == "TOKEN")
    }

    // MARK: - Duplicate prompt key deduplication (#183)

    @Test("Shared env var name across MCP servers produces unique prompt keys")
    func duplicatePromptKeysGetSuffix() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var config = ConfigurationDiscovery.DiscoveredConfiguration()
        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "figma", command: "npx", args: ["figma-mcp"],
                env: ["API_KEY": "figma-secret"],
                url: nil, scope: "local"
            ),
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "atlassian", command: "npx", args: ["atlassian-mcp"],
                env: ["API_KEY": "atlassian-secret"],
                url: nil, scope: "local"
            ),
        ]

        let metadata = ManifestBuilder.Metadata(
            identifier: "dedup-test",
            displayName: "Dedup Test",
            description: "Tests duplicate prompt key handling",
            author: nil
        )

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            options: ManifestBuilder.BuildOptions(
                selectedMCPServers: Set(config.mcpServers.map(\.name)),
                selectedHookFiles: [], selectedSkillFiles: [],
                selectedCommandFiles: [], selectedAgentFiles: [], selectedPlugins: [], selectedSections: [],
                includeUserContent: false, includeGitignore: false, includeSettings: false
            )
        )

        // Two unique prompt keys: API_KEY and API_KEY_2
        let prompts = try #require(result.manifest.prompts)
        #expect(prompts.count == 2)
        let keys = Set(prompts.map(\.key))
        #expect(keys == ["API_KEY", "API_KEY_2"])

        // Each server's env uses the correct placeholder
        let components = try #require(result.manifest.components)
        let figmaComp = try #require(components.first { $0.id.contains("figma") })
        guard case let .mcpServer(figmaConfig) = figmaComp.installAction else {
            Issue.record("Expected mcpServer install action for figma")
            return
        }
        #expect(figmaConfig.env?["API_KEY"] == "__API_KEY__")

        let atlassianComp = try #require(components.first { $0.id.contains("atlassian") })
        guard case let .mcpServer(atlassianConfig) = atlassianComp.installAction else {
            Issue.record("Expected mcpServer install action for atlassian")
            return
        }
        #expect(atlassianConfig.env?["API_KEY"] == "__API_KEY_2__")

        // Round-trip: YAML → load → validate passes
        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)
        let loaded = try ExternalPackManifest.load(from: yamlFile)
        let normalized = try loaded.normalized()
        try normalized.validate()
    }

    // MARK: - YAML quoting edge cases

    private func buildAndLoadRoundTrip(
        config: ConfigurationDiscovery.DiscoveredConfiguration = .init(),
        metadata: ManifestBuilder.Metadata,
        selectedMCPServers: Set<String> = []
    ) throws -> (result: ManifestBuilder.BuildResult, loaded: ExternalPackManifest) {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = ManifestBuilder().build(
            from: config, metadata: metadata,
            options: ManifestBuilder.BuildOptions(
                selectedMCPServers: selectedMCPServers,
                selectedHookFiles: [], selectedSkillFiles: [],
                selectedCommandFiles: [], selectedAgentFiles: [], selectedPlugins: [], selectedSections: [],
                includeUserContent: false, includeGitignore: false, includeSettings: false
            )
        )

        let yamlFile = tmpDir.appendingPathComponent("techpack.yaml")
        try result.manifestYAML.write(to: yamlFile, atomically: true, encoding: .utf8)
        let loaded = try ExternalPackManifest.load(from: yamlFile)
        return (result, loaded)
    }

    @Test("Special characters in metadata survive YAML round-trip")
    func specialCharactersInMetadataRoundTrip() throws {
        let metadata = ManifestBuilder.Metadata(
            identifier: "special-chars",
            displayName: "Special Pack",
            description: "Contains # hash and key: value pair",
            author: "&anchor-like author"
        )

        let (result, loaded) = try buildAndLoadRoundTrip(metadata: metadata)

        #expect(result.manifestYAML.contains("description: \"Contains # hash and key: value pair\""))
        #expect(result.manifestYAML.contains("author: \"&anchor-like author\""))
        #expect(loaded.description == "Contains # hash and key: value pair")
        #expect(loaded.author == "&anchor-like author")
    }

    @Test("Newlines and tabs in description are properly escaped")
    func newlinesAndTabsRoundTrip() throws {
        let metadata = ManifestBuilder.Metadata(
            identifier: "newline-pack",
            displayName: "Newline Pack",
            description: "Line one\nLine two\tTabbed",
            author: nil
        )

        let (result, loaded) = try buildAndLoadRoundTrip(metadata: metadata)

        #expect(result.manifestYAML.contains(#"description: "Line one\nLine two\tTabbed""#))
        #expect(loaded.description == "Line one\nLine two\tTabbed")
    }

    @Test("HTTP MCP server URL with fragment survives round-trip")
    func httpURLWithFragmentRoundTrip() throws {
        var config = ConfigurationDiscovery.DiscoveredConfiguration()
        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "fragmented", command: nil, args: [],
                env: [:],
                url: "https://example.com/mcp#section", scope: "local"
            ),
        ]

        let metadata = ManifestBuilder.Metadata(
            identifier: "url-test",
            displayName: "URL Test",
            description: "Tests URL quoting",
            author: nil
        )

        let (_, loaded) = try buildAndLoadRoundTrip(
            config: config, metadata: metadata, selectedMCPServers: ["fragmented"]
        )
        let normalized = try loaded.normalized()

        let mcpComp = try #require(normalized.components?.first { $0.type == .mcpServer })
        guard case let .mcpServer(mcpConfig) = mcpComp.installAction else {
            Issue.record("Expected mcpServer install action")
            return
        }
        #expect(mcpConfig.url == "https://example.com/mcp#section")
    }

    @Test("Component description with special characters survives round-trip")
    func componentDescriptionSpecialCharsRoundTrip() throws {
        var config = ConfigurationDiscovery.DiscoveredConfiguration()
        config.mcpServers = [
            ConfigurationDiscovery.DiscoveredMCPServer(
                name: "server#v2", command: "npx", args: ["test"],
                env: [:],
                url: nil, scope: "local"
            ),
        ]

        let metadata = ManifestBuilder.Metadata(
            identifier: "desc-test",
            displayName: "Desc Test",
            description: "Tests component descriptions",
            author: nil
        )

        let (_, loaded) = try buildAndLoadRoundTrip(
            config: config, metadata: metadata, selectedMCPServers: ["server#v2"]
        )
        let normalized = try loaded.normalized()

        let mcpComp = try #require(normalized.components?.first { $0.type == .mcpServer })
        #expect(mcpComp.description.contains("server#v2"))
        #expect(mcpComp.id.contains("mcp-serverv2"))
        #expect(!mcpComp.id.contains("#"))
    }
}
