import Foundation
@testable import mcs
import Testing

// MARK: - Global MCP Scope Tests

struct GlobalMCPScopeTests {
    @Test("MCP server is registered with user scope regardless of pack declaration")
    func mcpServerUsesUserScope() throws {
        let tmpDir = try makeGlobalTmpDir(label: "mcp")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.mcp-server",
                displayName: "Test MCP",
                description: "Test MCP server",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test-mcp", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        #expect(mockCLI.mcpAddCalls.count == 1)
        #expect(mockCLI.mcpAddCalls.first?.scope == Constants.MCPScope.user)
    }

    @Test("MCP scope override ignores explicit local scope in pack config")
    func mcpScopeOverrideIgnoresLocalDeclaration() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.mcp-local",
                displayName: "Local MCP",
                description: "Pack declares local scope",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "mcp-local", command: "/usr/bin/true", args: [], env: [:],
                    scope: "local"
                ))
            )]
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        #expect(mockCLI.mcpAddCalls.first?.scope == Constants.MCPScope.user)
    }

    @Test("Artifact record stores user scope for MCP server")
    func mcpArtifactRecordsUserScope() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeGlobalConfigurator(home: tmpDir)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP",
                description: "MCP server",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "my-mcp", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        let state = try ProjectState(stateFile: env.globalStateFile)
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts?.mcpServers.first?.scope == Constants.MCPScope.user)
        #expect(artifacts?.mcpServers.first?.name == "my-mcp")
    }

    @Test("Stale MCP server is removed with user scope")
    func staleMCPRemovedWithUserScope() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        // Pack v1: two MCP servers
        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-keep",
                    displayName: "MCP Keep",
                    description: "Kept",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-keep", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
                ComponentDefinition(
                    id: "test-pack.mcp-drop",
                    displayName: "MCP Drop",
                    description: "Dropped",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-drop", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        try configurator.configure(packs: [packV1], confirmRemovals: false)
        mockCLI.mcpRemoveCalls = []

        // Pack v2: mcp-drop removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-keep",
                    displayName: "MCP Keep",
                    description: "Kept",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-keep", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        try configurator.configure(packs: [packV2], confirmRemovals: false)

        #expect(mockCLI.mcpRemoveCalls.contains(
            MockClaudeCLI.MCPRemoveCall(name: "mcp-drop", scope: Constants.MCPScope.user)
        ))
    }
}

// MARK: - Global Settings Composition Tests

struct GlobalSettingsCompositionTests {
    @Test("Existing user settings are preserved after global sync")
    func preservesExistingUserSettings() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pre-write settings.json with user content
        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        let userSettings = """
        {"permissions":{"allow":["Bash(npm test)"]}}
        """
        try userSettings.write(to: settingsPath, atomically: true, encoding: .utf8)

        let configurator = makeGlobalConfigurator(home: tmpDir)

        // Pack with a hook file that will add hooks to settings
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("start.sh")
        try "#!/bin/bash\necho start".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Start hook",
                description: "Session start hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "start.sh",
                    fileType: .hook
                )
            )]
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify the file still has user content by reading raw JSON
        let rawData = try Data(contentsOf: settingsPath)
        let rawJSON = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
        let permissions = rawJSON?["permissions"] as? [String: Any]
        let allow = permissions?["allow"] as? [String]
        #expect(allow?.contains("Bash(npm test)") == true)
        // Hook should also be present
        let result = try Settings.load(from: settingsPath)
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        #expect(!sessionGroups.isEmpty)
    }

    @Test("Managed hooks are stripped before recompose to prevent duplication")
    func stripsMangedHooksBeforeRecompose() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeGlobalConfigurator(home: tmpDir)

        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("start.sh")
        try "#!/bin/bash\necho start".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Start hook",
                description: "Session start hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "start.sh",
                    fileType: .hook
                )
            )]
        )

        // First sync
        try configurator.configure(packs: [pack], confirmRemovals: false)
        // Second sync
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        let result = try Settings.load(from: settingsPath)
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        // Should have exactly 1 hook group, not duplicated
        #expect(sessionGroups.count == 1)
    }

    @Test("Corrupt settings.json throws fileOperationFailed")
    func corruptJSONThrows() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        try "{ invalid json".write(to: settingsPath, atomically: true, encoding: .utf8)

        let configurator = makeGlobalConfigurator(home: tmpDir)
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Hook",
                description: "Hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: settingsPath, // dummy, won't be reached
                    destination: "hook.sh",
                    fileType: .hook
                )
            )]
        )

        #expect {
            try configurator.configure(packs: [pack], confirmRemovals: false)
        } throws: { error in
            guard case MCSError.fileOperationFailed = error else { return false }
            return true
        }
    }

    @Test("Empty packs do not delete settings.json")
    func emptyPacksDoNotDeleteSettingsJSON() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        try "{}".write(to: settingsPath, atomically: true, encoding: .utf8)

        let configurator = makeGlobalConfigurator(home: tmpDir)
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack"
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        #expect(FileManager.default.fileExists(atPath: settingsPath.path))
    }

    @Test("Hook commands use global path prefix")
    func hookCommandPrefixUsesGlobalPath() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeGlobalConfigurator(home: tmpDir)

        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("start.sh")
        try "#!/bin/bash\necho start".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Start hook",
                description: "Session start hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "start.sh",
                    fileType: .hook
                )
            )]
        )

        try configurator.configure(packs: [pack], confirmRemovals: false)

        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        let result = try Settings.load(from: settingsPath)
        let command = result.hooks?["SessionStart"]?.first?.hooks?.first?.command
        #expect(command == "bash ~/.claude/hooks/start.sh")
        // Must NOT use project-relative path
        #expect(command?.hasPrefix("bash .claude/") != true)
    }
}

// MARK: - Global Claude Composition Tests

struct GlobalClaudeCompositionTests {
    @Test("Template sections are written to global CLAUDE.md")
    func composesToGlobalClaudeMD() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack.section",
                templateContent: "## Test Section\nSome content here.",
                placeholders: []
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let claudePath = tmpDir.appendingPathComponent(".claude/CLAUDE.md")
        #expect(FileManager.default.fileExists(atPath: claudePath.path))
        let content = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(content.contains("## Test Section"))
        #expect(content.contains("mcs:begin test-pack.section"))
    }

    @Test("Empty contributions do not create CLAUDE.md")
    func emptyContributionsSilent() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack"
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let claudePath = tmpDir.appendingPathComponent(".claude/CLAUDE.md")
        #expect(!FileManager.default.fileExists(atPath: claudePath.path))
    }

    @Test("Existing user content in CLAUDE.md is preserved on re-sync")
    func existingUserContentPreserved() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // First sync: install a section so the file has markers
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack.section",
                templateContent: "## Pack Content",
                placeholders: []
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Simulate user appending custom content outside section markers
        let claudePath = tmpDir.appendingPathComponent(".claude/CLAUDE.md")
        var content = try String(contentsOf: claudePath, encoding: .utf8)
        content += "\n# My Custom Content\nUser notes here.\n"
        try content.write(to: claudePath, atomically: true, encoding: .utf8)

        // Re-sync the same pack — user content should survive
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let updated = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(updated.contains("# My Custom Content"))
        #expect(updated.contains("User notes here."))
        #expect(updated.contains("## Pack Content"))
    }

    @Test("Template sections are tracked in artifact record")
    func templateSectionsTracked() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack.section",
                templateContent: "## Section",
                placeholders: []
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        let state = try ProjectState(stateFile: env.globalStateFile)
        let sections = state.artifacts(for: "test-pack")?.templateSections ?? []
        #expect(sections.contains("test-pack.section"))
    }
}

// MARK: - Global File Installation Tests

struct GlobalFileInstallationTests {
    @Test("Skill file installed to global skills directory")
    func skillInstalledToGlobalDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("my-skill.md")
        try "# My Skill".write(to: source, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.skill",
                displayName: "My Skill",
                description: "A skill",
                type: .skill,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .copyPackFile(source: source, destination: "my-skill.md", fileType: .skill)
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let dest = tmpDir.appendingPathComponent(".claude/skills/my-skill.md")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("Hook file installed to global hooks directory")
    func hookInstalledToGlobalDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("start.sh")
        try "#!/bin/bash".write(to: source, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Start Hook",
                description: "A hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .copyPackFile(source: source, destination: "start.sh", fileType: .hook)
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let dest = tmpDir.appendingPathComponent(".claude/hooks/start.sh")
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("File path recorded relative to claude directory")
    func filePathRecordedRelativeToClaudeDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("my-skill.md")
        try "# Skill".write(to: source, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.skill",
                displayName: "My Skill",
                description: "A skill",
                type: .skill,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .copyPackFile(source: source, destination: "my-skill.md", fileType: .skill)
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        let state = try ProjectState(stateFile: env.globalStateFile)
        let files = state.artifacts(for: "test-pack")?.files ?? []
        #expect(files.contains("skills/my-skill.md"))
    }

    @Test("Stale file removed from global directory")
    func staleFileRemovedFromGlobalDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let sourceA = sourceDir.appendingPathComponent("skill-a.md")
        try "skill a".write(to: sourceA, atomically: true, encoding: .utf8)
        let sourceB = sourceDir.appendingPathComponent("skill-b.md")
        try "skill b".write(to: sourceB, atomically: true, encoding: .utf8)

        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "First",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .copyPackFile(source: sourceA, destination: "skill-a.md", fileType: .skill)
                ),
                ComponentDefinition(
                    id: "test-pack.skill-b",
                    displayName: "Skill B",
                    description: "Second",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .copyPackFile(source: sourceB, destination: "skill-b.md", fileType: .skill)
                ),
            ]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let destB = tmpDir.appendingPathComponent(".claude/skills/skill-b.md")
        #expect(FileManager.default.fileExists(atPath: destB.path))

        // Pack v2: skill-b removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "First",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .copyPackFile(source: sourceA, destination: "skill-a.md", fileType: .skill)
                ),
            ]
        )

        try configurator.configure(packs: [packV2], confirmRemovals: false)

        let destA = tmpDir.appendingPathComponent(".claude/skills/skill-a.md")
        #expect(FileManager.default.fileExists(atPath: destA.path))
        #expect(!FileManager.default.fileExists(atPath: destB.path))
    }
}

// MARK: - Global Resolve Built-In Values Tests

struct GlobalResolveBuiltInValuesTests {
    @Test("Global scope returns empty built-in values")
    func resolveBuiltInValuesReturnsEmptyDict() {
        let env = Environment(home: FileManager.default.temporaryDirectory)
        let strategy = GlobalSyncStrategy(environment: env)
        let shell = ShellRunner(environment: env)
        let output = CLIOutput(colorsEnabled: false)

        let values = strategy.resolveBuiltInValues(shell: shell, output: output)
        #expect(values.isEmpty)
    }
}

// MARK: - Global Convergence Flow Tests

struct GlobalConvergenceFlowTests {
    @Test("configureProject hooks are NOT called in global scope")
    func configureProjectHooksNotCalled() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = TrackingMockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack"
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        #expect(pack.configureProjectCallCount == 0)
    }
}

// MARK: - Global Unconfigure Pack Tests

struct GlobalUnconfigurePackTests {
    @Test("unconfigurePack removes MCP server with user scope")
    func unconfigureRemovesMCPWithUserScope() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP",
                description: "MCP server",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "my-mcp", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )

        // First sync to install
        try configurator.configure(packs: [pack], confirmRemovals: false)
        mockCLI.mcpRemoveCalls = []

        // Second sync with empty packs to trigger unconfigure
        try configurator.configure(packs: [], confirmRemovals: false)

        #expect(mockCLI.mcpRemoveCalls.contains(
            MockClaudeCLI.MCPRemoveCall(name: "my-mcp", scope: Constants.MCPScope.user)
        ))
    }

    @Test("unconfigurePack removes files from global directory")
    func unconfigureRemovesFilesFromGlobalDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("my-skill.md")
        try "# Skill".write(to: source, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.skill",
                displayName: "Skill",
                description: "A skill",
                type: .skill,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .copyPackFile(source: source, destination: "my-skill.md", fileType: .skill)
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let dest = tmpDir.appendingPathComponent(".claude/skills/my-skill.md")
        #expect(FileManager.default.fileExists(atPath: dest.path))

        // Unconfigure by deselecting the pack
        try configurator.configure(packs: [], confirmRemovals: false)

        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("unconfigurePack strips template sections from CLAUDE.md")
    func unconfigureStripsTemplateSections() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack.section",
                templateContent: "## Managed Section",
                placeholders: []
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let claudePath = tmpDir.appendingPathComponent(".claude/CLAUDE.md")
        let before = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(before.contains("## Managed Section"))

        // Unconfigure
        try configurator.configure(packs: [], confirmRemovals: false)

        let after = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(!after.contains("## Managed Section"))
        #expect(!after.contains("mcs:begin test-pack.section"))
    }

    @Test("unconfigurePack strips settings keys from settings.json")
    func unconfigureStripsSettingsKeys() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeGlobalConfigurator(home: tmpDir)

        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("hook.sh")
        try "#!/bin/bash".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook",
                displayName: "Hook",
                description: "A hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "hook.sh",
                    fileType: .hook
                )
            )]
        )

        // Install
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let settingsPath = tmpDir.appendingPathComponent(".claude/settings.json")
        let before = try Settings.load(from: settingsPath)
        #expect(before.hooks?["SessionStart"] != nil)

        // Unconfigure
        try configurator.configure(packs: [], confirmRemovals: false)

        let after = try Settings.load(from: settingsPath)
        let sessionGroups = after.hooks?["SessionStart"] ?? []
        #expect(sessionGroups.isEmpty)
    }

    @Test("Deselection of one pack fully unconfigures it while keeping the other")
    func deselectionTriggersUnconfigure() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [ComponentDefinition(
                id: "pack-a.mcp",
                displayName: "MCP A",
                description: "MCP A",
                type: .mcpServer,
                packIdentifier: "pack-a",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "mcp-a", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )

        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [ComponentDefinition(
                id: "pack-b.mcp",
                displayName: "MCP B",
                description: "MCP B",
                type: .mcpServer,
                packIdentifier: "pack-b",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "mcp-b", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )

        // First sync: both packs
        try configurator.configure(packs: [packA, packB], confirmRemovals: false)
        mockCLI.mcpRemoveCalls = []

        // Second sync: only pack-b (deselect pack-a)
        try configurator.configure(packs: [packB], confirmRemovals: false)

        // pack-a's MCP should be removed
        #expect(mockCLI.mcpRemoveCalls.contains(
            MockClaudeCLI.MCPRemoveCall(name: "mcp-a", scope: Constants.MCPScope.user)
        ))
        // pack-b's MCP should NOT be removed
        #expect(!mockCLI.mcpRemoveCalls.contains(
            MockClaudeCLI.MCPRemoveCall(name: "mcp-b", scope: Constants.MCPScope.user)
        ))

        let env = Environment(home: tmpDir)
        let state = try ProjectState(stateFile: env.globalStateFile)
        #expect(state.configuredPacks.contains("pack-b"))
        #expect(!state.configuredPacks.contains("pack-a"))
    }
}

// MARK: - Global Dry Run Tests

struct GlobalDryRunTests {
    @Test("Dry run does not create any files in global scope")
    func dryRunNoFilesCreated() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP",
                description: "MCP",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "my-mcp", command: "/usr/bin/true", args: [], env: [:]
                ))
            )],
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack.section",
                templateContent: "## Section",
                placeholders: []
            )]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.dryRun(packs: [pack])

        // No state file should be created
        let env = Environment(home: tmpDir)
        #expect(!FileManager.default.fileExists(atPath: env.globalStateFile.path))
        // No CLAUDE.md
        #expect(!FileManager.default.fileExists(atPath: env.globalClaudeMD.path))
        // No settings.json
        #expect(!FileManager.default.fileExists(atPath: env.claudeSettings.path))
    }

    @Test("Dry run preserves existing global state")
    func dryRunPreservesState() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeGlobalConfigurator(home: tmpDir)

        // Install a pack first
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [ComponentDefinition(
                id: "pack-a.mcp",
                displayName: "MCP A",
                description: "MCP A",
                type: .mcpServer,
                packIdentifier: "pack-a",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "mcp-a", command: "/usr/bin/true", args: [], env: [:]
                ))
            )]
        )
        try configurator.configure(packs: [packA], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        let stateBefore = try ProjectState(stateFile: env.globalStateFile)
        #expect(stateBefore.configuredPacks.contains("pack-a"))

        // Dry run with different pack
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B"
        )
        try configurator.dryRun(packs: [packB])

        // State should be unchanged
        let stateAfter = try ProjectState(stateFile: env.globalStateFile)
        #expect(stateAfter.configuredPacks.contains("pack-a"))
        #expect(!stateAfter.configuredPacks.contains("pack-b"))
    }
}

// MARK: - Global Excluded Components Tests

struct GlobalExcludedComponentsTests {
    @Test("Excluded MCP server is removed with user scope")
    func excludedMCPRemovedWithUserScope() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mockCLI = MockClaudeCLI()
        let configurator = makeGlobalConfigurator(home: tmpDir, mockCLI: mockCLI)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-a",
                    displayName: "MCP A",
                    description: "Kept",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-a", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
                ComponentDefinition(
                    id: "test-pack.mcp-b",
                    displayName: "MCP B",
                    description: "To exclude",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-b", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        // First sync: both installed
        try configurator.configure(packs: [pack], confirmRemovals: false)
        mockCLI.mcpRemoveCalls = []

        // Second sync: exclude mcp-b
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.mcp-b"]]
        )

        #expect(mockCLI.mcpRemoveCalls.contains(
            MockClaudeCLI.MCPRemoveCall(name: "mcp-b", scope: Constants.MCPScope.user)
        ))
    }

    @Test("Excluded file is removed from global directory")
    func excludedFileRemovedFromGlobalDir() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceDir = tmpDir.appendingPathComponent("pack/skills")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let sourceA = sourceDir.appendingPathComponent("skill-a.md")
        try "skill a".write(to: sourceA, atomically: true, encoding: .utf8)
        let sourceB = sourceDir.appendingPathComponent("skill-b.md")
        try "skill b".write(to: sourceB, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "First",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(source: sourceA, destination: "skill-a.md", fileType: .skill)
                ),
                ComponentDefinition(
                    id: "test-pack.skill-b",
                    displayName: "Skill B",
                    description: "Second",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(source: sourceB, destination: "skill-b.md", fileType: .skill)
                ),
            ]
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)

        // First sync: both installed
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let destB = tmpDir.appendingPathComponent(".claude/skills/skill-b.md")
        #expect(FileManager.default.fileExists(atPath: destB.path))

        // Second sync: exclude skill-b
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.skill-b"]]
        )

        #expect(!FileManager.default.fileExists(atPath: destB.path))
        let destA = tmpDir.appendingPathComponent(".claude/skills/skill-a.md")
        #expect(FileManager.default.fileExists(atPath: destA.path))
    }
}

// MARK: - Global State and Index Tests

struct GlobalStateAndIndexTests {
    @Test("State file saved to global location")
    func stateFileSavedToGlobalLocation() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack"
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        #expect(FileManager.default.fileExists(atPath: env.globalStateFile.path))
    }

    @Test("Project index uses global sentinel identifier")
    func projectIndexUsesGlobalSentinel() throws {
        let tmpDir = try makeGlobalTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack"
        )

        let configurator = makeGlobalConfigurator(home: tmpDir)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let env = Environment(home: tmpDir)
        let index = ProjectIndex(path: env.projectsIndexFile)
        let data = try index.load()
        let globalProjects = index.projects(withPack: "test-pack", in: data)
        let globalEntry = globalProjects.first { $0.path == ProjectIndex.globalSentinel }
        #expect(globalEntry != nil)
    }
}
