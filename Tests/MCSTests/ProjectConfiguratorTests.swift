import Foundation
@testable import mcs
import Testing

// MARK: - Dry Run Tests

struct DryRunTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-dryrun-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(projectPath: URL, home: URL? = nil) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: MockClaudeCLI()
        )
    }

    @Test("Dry run does not create any files")
    func dryRunCreatesNoFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "test",
                templateContent: "Test content",
                placeholders: []
            )]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.dryRun(packs: [pack])

        // No CLAUDE.local.md should be created
        let claudeLocal = tmpDir.appendingPathComponent("CLAUDE.local.md")
        #expect(!FileManager.default.fileExists(atPath: claudeLocal.path))

        // No .claude/ directory should be created
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        #expect(!FileManager.default.fileExists(atPath: claudeDir.path))
    }

    @Test("Dry run does not modify existing project state")
    func dryRunPreservesState() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create an existing project state
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("existing-pack")
        state.setArtifacts(
            PackArtifactRecord(templateSections: ["existing"]),
            for: "existing-pack"
        )
        try state.save()

        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        let stateBefore = try Data(contentsOf: stateFile)

        // Run dry-run with a different pack
        let pack = MockTechPack(identifier: "new-pack", displayName: "New Pack")
        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.dryRun(packs: [pack])

        // State file should be unchanged
        let stateAfter = try Data(contentsOf: stateFile)
        #expect(stateBefore == stateAfter)
    }

    @Test("Dry run correctly identifies additions and removals")
    func dryRunIdentifiesConvergence() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create existing state with pack A configured
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("pack-a")
        state.setArtifacts(
            PackArtifactRecord(
                mcpServers: [MCPServerRef(name: "server-a", scope: "local")],
                templateSections: ["pack-a"]
            ),
            for: "pack-a"
        )
        try state.save()

        // Dry-run with pack B (not pack A) — should show A removed, B added
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [ComponentDefinition(
                id: "pack-b.server",
                displayName: "Server B",
                description: "A server",
                type: .mcpServer,
                packIdentifier: "pack-b",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "server-b",
                    command: "/usr/bin/test",
                    args: [],
                    env: [:]
                ))
            )],
            templates: [TemplateContribution(
                sectionIdentifier: "pack-b",
                templateContent: "Pack B content",
                placeholders: []
            )]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // Capture that it doesn't throw and doesn't modify state
        try configurator.dryRun(packs: [packB])

        // Verify state file is unchanged (pack-a still configured)
        let updatedState = try ProjectState(projectRoot: tmpDir)
        #expect(updatedState.configuredPacks.contains("pack-a"))
        #expect(!updatedState.configuredPacks.contains("pack-b"))
    }

    @Test("Dry run with empty pack list shows nothing to change")
    func dryRunEmptyPacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.dryRun(packs: [])

        // Should not create any files
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        #expect(!FileManager.default.fileExists(atPath: claudeDir.path))
    }
}

// MARK: - Settings Merge Tests

struct PackSettingsMergeTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-settings-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(projectPath: URL, home: URL? = nil) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: MockClaudeCLI()
        )
    }

    /// Write a JSON settings file and return its URL.
    private func writeSettingsFile(in dir: URL, name: String, settings: Settings) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try settings.save(to: url)
        return url
    }

    @Test("Pack with settingsFile merges settings into settings.local.json")
    func settingsFileMerge() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a pack settings file
        let packSettings = try Settings(extraJSON: [
            "env": JSONSerialization.data(withJSONObject: ["MY_KEY": "my_value"]),
            "alwaysThinkingEnabled": JSONSerialization.data(
                withJSONObject: true, options: .fragmentsAllowed
            ),
        ])
        let settingsURL = try writeSettingsFile(
            in: tmpDir, name: "pack-settings.json", settings: packSettings
        )

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "Merges settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: settingsURL)
            )]
        )

        // Create .claude/ dir and run compose
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("test-pack")
        try state.save()

        try configurator.configure(packs: [pack])

        // Check settings.local.json was created with merged settings
        let result = try Settings.load(from: settingsPath)
        let envData = try #require(result.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["MY_KEY"] == "my_value")
        #expect(result.extraJSON["alwaysThinkingEnabled"] != nil)
    }

    @Test("Multiple packs merge settings additively")
    func multiPackSettingsMerge() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pack A settings
        let settingsA = try Settings(extraJSON: [
            "env": JSONSerialization.data(withJSONObject: ["KEY_A": "value_a"]),
        ])
        let urlA = try writeSettingsFile(
            in: tmpDir, name: "settings-a.json", settings: settingsA
        )

        // Pack B settings
        let settingsB = try Settings(
            enabledPlugins: ["my-plugin": true],
            extraJSON: [
                "env": JSONSerialization.data(withJSONObject: ["KEY_B": "value_b"]),
            ]
        )
        let urlB = try writeSettingsFile(
            in: tmpDir, name: "settings-b.json", settings: settingsB
        )

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [ComponentDefinition(
                id: "pack-a.settings",
                displayName: "Pack A Settings",
                description: "Settings A",
                type: .configuration,
                packIdentifier: "pack-a",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: urlA)
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [ComponentDefinition(
                id: "pack-b.settings",
                displayName: "Pack B Settings",
                description: "Settings B",
                type: .configuration,
                packIdentifier: "pack-b",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: urlB)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [packA, packB])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)
        let envData = try #require(result.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["KEY_A"] == "value_a")
        #expect(env["KEY_B"] == "value_b")
        #expect(result.enabledPlugins?["my-plugin"] == true)
    }

    @Test("Removing a pack excludes its settings on next configure")
    func removePackExcludesSettings() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Pack settings
        let packSettings = try Settings(extraJSON: [
            "env": JSONSerialization.data(withJSONObject: ["PACK_KEY": "pack_value"]),
        ])
        let settingsURL = try writeSettingsFile(
            in: tmpDir, name: "pack-settings.json", settings: packSettings
        )

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "Merges settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: settingsURL)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // First configure with the pack
        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let afterAdd = try Settings.load(from: settingsPath)
        if let envData = afterAdd.extraJSON["env"],
           let env = try JSONSerialization.jsonObject(with: envData) as? [String: String] {
            #expect(env["PACK_KEY"] == "pack_value")
        } else {
            Issue.record("Expected env key PACK_KEY in settings.local.json")
        }

        // Re-configure with no packs (simulate removal)
        try configurator.configure(packs: [], confirmRemovals: false)

        // settings.local.json should either not exist or not have the pack's key
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let afterRemove = try Settings.load(from: settingsPath)
            if let envData = afterRemove.extraJSON["env"],
               let env = try? JSONSerialization.jsonObject(with: envData) as? [String: String] {
                #expect(env["PACK_KEY"] == nil)
            }
        }
        // If file doesn't exist, that's also fine — no settings to write
    }

    @Test("settingsMerge with nil source is a no-op")
    func settingsMergeNilSource() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Test Settings",
                description: "No-op settings",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: nil)
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        // No settings.local.json should be created for a nil-source settingsMerge
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsPath.path))
    }
}

// MARK: - installProjectFile Substitution Tests

struct InstallProjectFileSubstitutionTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-install-sub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutor() -> ComponentExecutor {
        let env = Environment()
        let shell = ShellRunner(environment: env)
        return ComponentExecutor(
            environment: env,
            output: output,
            shell: shell,
            claudeCLI: ClaudeIntegration(shell: shell)
        )
    }

    @Test("installProjectFile substitutes placeholders in single file")
    func singleFileSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        // Create a source file with placeholder
        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let source = packDir.appendingPathComponent("pr.md")
        try "Branch: __BRANCH_PREFIX__/{ticket}".write(
            to: source, atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: source,
            destination: "pr.md",
            fileType: .command,
            projectPath: projectPath,
            resolvedValues: ["BRANCH_PREFIX": "feature"]
        )

        #expect(!result.paths.isEmpty)

        // Read the installed file
        let installed = projectPath
            .appendingPathComponent(".claude/commands/pr.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("feature/{ticket}"))
        #expect(!content.contains("__BRANCH_PREFIX__"))
    }

    @Test("installProjectFile substitutes placeholders in directory files")
    func directoryFileSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        // Create a source directory with files containing placeholders
        let packDir = tmpDir.appendingPathComponent("pack/my-skill")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try "Skill for __REPO_NAME__".write(
            to: packDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: packDir,
            destination: "my-skill",
            fileType: .skill,
            projectPath: projectPath,
            resolvedValues: ["REPO_NAME": "my-app"]
        )

        #expect(!result.paths.isEmpty)

        let installed = projectPath
            .appendingPathComponent(".claude/skills/my-skill/SKILL.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("my-app"))
        #expect(!content.contains("__REPO_NAME__"))
    }

    @Test("installProjectFile without resolvedValues does raw copy")
    func noValuesRawCopy() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let source = packDir.appendingPathComponent("commit.md")
        try "Keep __PLACEHOLDER__ intact".write(
            to: source, atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        _ = exec.installProjectFile(
            source: source,
            destination: "commit.md",
            fileType: .command,
            projectPath: projectPath
        )

        let installed = projectPath
            .appendingPathComponent(".claude/commands/commit.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("__PLACEHOLDER__"))
    }

    @Test("installProjectFile copies binary file without corruption")
    func binaryFileFallsBack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        // Create a binary source file (invalid UTF-8)
        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let source = packDir.appendingPathComponent("data.bin")
        let bytes: [UInt8] = [0xFF, 0xFE, 0x00, 0x01, 0x80, 0x81]
        try Data(bytes).write(to: source)

        var exec = makeExecutor()
        let installResult = exec.installProjectFile(
            source: source,
            destination: "data.bin",
            fileType: .command,
            projectPath: projectPath,
            resolvedValues: ["FOO": "bar"]
        )

        #expect(!installResult.paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/commands/data.bin")
        let result = try Data(contentsOf: installed)
        #expect(result == Data(bytes))
    }
}

// MARK: - Auto-Derived Hook & Plugin Tests

struct AutoDerivedSettingsTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-autoderive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(projectPath: URL, home: URL? = nil) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: MockClaudeCLI()
        )
    }

    /// Create a pack with a hookFile component that has hookEvent set.
    private func makeHookPack(tmpDir: URL) throws -> MockTechPack {
        // Create the hook source file
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("session_start.sh")
        try "#!/bin/bash\necho session".write(
            to: hookSource, atomically: true, encoding: .utf8
        )

        return MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook-session",
                displayName: "Session hook",
                description: "Session start hook",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                hookEvent: "SessionStart",
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "session_start.sh",
                    fileType: .hook
                )
            )]
        )
    }

    /// Create a pack with a plugin component.
    private func makePluginPack() -> MockTechPack {
        MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.plugin-review",
                displayName: "PR Review",
                description: "PR review plugin",
                type: .plugin,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .plugin(name: "pr-review-toolkit@claude-plugins-official")
            )]
        )
    }

    @Test("hookFile with hookEvent auto-derives settings entry")
    func hookEventAutoDerivesSettings() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try makeHookPack(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        // Should have SessionStart hook with project-relative path
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        #expect(!sessionGroups.isEmpty)
        let command = sessionGroups.first?.hooks?.first?.command
        #expect(command == "bash .claude/hooks/session_start.sh")
        // Should NOT use global path
        #expect(command?.contains("~/.claude") != true)
    }

    @Test("plugin component auto-derives enabledPlugins entry")
    func pluginAutoDerivesEnabledPlugins() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = makePluginPack()

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        #expect(result.enabledPlugins?["pr-review-toolkit"] == true)
    }

    @Test("hookFile without hookEvent does not generate settings entry")
    func noHookEventNoSettingsEntry() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create hook source
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("helper.sh")
        try "#!/bin/bash".write(to: hookSource, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [ComponentDefinition(
                id: "test-pack.hook-helper",
                displayName: "Helper hook",
                description: "No hookEvent",
                type: .hookFile,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                // hookEvent is nil
                installAction: .copyPackFile(
                    source: hookSource,
                    destination: "helper.sh",
                    fileType: .hook
                )
            )]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        // No settings.local.json should be created (no derivable entries)
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsPath.path))
    }

    @Test("Auto-derived hooks deduplicate with settingsFile merge")
    func hookDeduplicationWithSettingsFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create hook source
        let packDir = tmpDir.appendingPathComponent("pack/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let hookSource = packDir.appendingPathComponent("session_start.sh")
        try "#!/bin/bash".write(to: hookSource, atomically: true, encoding: .utf8)

        // Create a settings file that also declares the same hook (old-style path)
        var packSettings = Settings()
        packSettings.hooks = [
            "SessionStart": [
                Settings.HookGroup(
                    matcher: nil,
                    hooks: [Settings.HookEntry(
                        type: "command",
                        command: "bash ~/.claude/hooks/session_start.sh"
                    )]
                ),
            ],
        ]
        let settingsURL = tmpDir.appendingPathComponent("pack-settings.json")
        try packSettings.save(to: settingsURL)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.hook-session",
                    displayName: "Session hook",
                    description: "Hook with event",
                    type: .hookFile,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    hookEvent: "SessionStart",
                    installAction: .copyPackFile(
                        source: hookSource,
                        destination: "session_start.sh",
                        fileType: .hook
                    )
                ),
                ComponentDefinition(
                    id: "test-pack.settings",
                    displayName: "Settings",
                    description: "Pack settings",
                    type: .configuration,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .settingsMerge(source: settingsURL)
                ),
            ]
        )

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let result = try Settings.load(from: settingsPath)

        // Should have both entries (different commands — project-local vs global)
        let sessionGroups = result.hooks?["SessionStart"] ?? []
        let commands = sessionGroups.compactMap { $0.hooks?.first?.command }
        #expect(commands.contains("bash .claude/hooks/session_start.sh"))
        #expect(commands.contains("bash ~/.claude/hooks/session_start.sh"))
        #expect(sessionGroups.count == 2)
    }

    @Test("hookCommands tracked in artifact record")
    func hookCommandsInArtifactRecord() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try makeHookPack(tmpDir: tmpDir)

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        try configurator.configure(packs: [pack])

        // Read project state and check hookCommands
        let state = try ProjectState(projectRoot: tmpDir)
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts != nil)
        #expect(artifacts?.hookCommands.contains("bash .claude/hooks/session_start.sh") == true)
    }
}

// MARK: - Excluded Components

struct ConfiguratorExcludedComponentsTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-exclude-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(
        projectPath: URL,
        home: URL? = nil,
        mockCLI: MockClaudeCLI = MockClaudeCLI()
    ) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: CLIOutput(),
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: mockCLI
        )
    }

    @Test("Excluded component is not installed")
    func excludedComponentSkipped() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Pack with two plugin components
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.plugin-a",
                    displayName: "Plugin A",
                    description: "First plugin",
                    type: .plugin,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .plugin(name: "plugin-a@test")
                ),
                ComponentDefinition(
                    id: "test-pack.plugin-b",
                    displayName: "Plugin B",
                    description: "Second plugin",
                    type: .plugin,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .plugin(name: "plugin-b@test")
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // Exclude plugin-b
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.plugin-b"]]
        )

        // Check settings.local.json — only plugin-a should be enabled
        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let settings = try Settings.load(from: settingsPath)
        #expect(settings.enabledPlugins?["plugin-a"] == true)
        #expect(settings.enabledPlugins?["plugin-b"] == nil)
    }

    @Test("Excluded components are persisted in project state")
    func excludedComponentsPersisted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("my-pack")
        state.setExcludedComponents(["my-pack.mcp-server", "my-pack.hook"], for: "my-pack")
        try state.save()

        // Reload from disk
        let reloaded = try ProjectState(projectRoot: tmpDir)
        let excluded = reloaded.excludedComponents(for: "my-pack")
        #expect(excluded == ["my-pack.mcp-server", "my-pack.hook"])
    }

    @Test("Removing a pack clears its exclusions")
    func removePackClearsExclusions() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("my-pack")
        state.setExcludedComponents(["my-pack.mcp-server"], for: "my-pack")
        state.removePack("my-pack")
        try state.save()

        let reloaded = try ProjectState(projectRoot: tmpDir)
        #expect(reloaded.excludedComponents(for: "my-pack").isEmpty)
        #expect(!reloaded.configuredPacks.contains("my-pack"))
    }

    @Test("Excluded component filters its dependent template from CLAUDE.local.md")
    func excludedComponentFiltersTemplate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.serena",
                    displayName: "Serena",
                    description: "LSP navigation",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "serena", command: "uvx", args: ["serena"], env: [:]
                    ))
                ),
            ],
            templates: [
                TemplateContribution(
                    sectionIdentifier: "test-pack.serena",
                    templateContent: "## Serena instructions",
                    placeholders: [],
                    dependencies: ["test-pack.serena"]
                ),
                TemplateContribution(
                    sectionIdentifier: "test-pack.git",
                    templateContent: "## Git instructions",
                    placeholders: []
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // Exclude serena component
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.serena"]]
        )

        // CLAUDE.local.md should have git template but NOT serena template
        let claudeLocalPath = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = try String(contentsOf: claudeLocalPath, encoding: .utf8)
        #expect(content.contains("Git instructions"))
        #expect(!content.contains("Serena instructions"))

        // Artifact record should only track the git template section
        let state = try ProjectState(projectRoot: tmpDir)
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts?.templateSections == ["test-pack.git"])
    }

    @Test("Previously written template section removed when its dependency is excluded")
    func excludedComponentRemovesDependentTemplateSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.serena",
                    displayName: "Serena",
                    description: "LSP navigation",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "serena-dep-test", command: "uvx", args: ["serena"], env: [:]
                    ))
                ),
            ],
            templates: [
                TemplateContribution(
                    sectionIdentifier: "test-pack.serena",
                    templateContent: "## Serena instructions",
                    placeholders: [],
                    dependencies: ["test-pack.serena"]
                ),
                TemplateContribution(
                    sectionIdentifier: "test-pack.git",
                    templateContent: "## Git instructions",
                    placeholders: []
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // First sync: all components included — both templates written
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: [:]
        )

        let claudeLocalPath = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content1 = try String(contentsOf: claudeLocalPath, encoding: .utf8)
        #expect(content1.contains("Serena instructions"))
        #expect(content1.contains("Git instructions"))

        let state1 = try ProjectState(projectRoot: tmpDir)
        let artifacts1 = state1.artifacts(for: "test-pack")
        #expect(artifacts1?.templateSections.contains("test-pack.serena") == true)

        // Second sync: exclude serena component — serena template section should be removed
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.serena"]]
        )

        let content2 = try String(contentsOf: claudeLocalPath, encoding: .utf8)
        #expect(!content2.contains("Serena instructions"), "Serena template section should be removed from file")
        #expect(content2.contains("Git instructions"), "Git template section should remain")

        let state2 = try ProjectState(projectRoot: tmpDir)
        let artifacts2 = state2.artifacts(for: "test-pack")
        #expect(artifacts2?.templateSections == ["test-pack.git"])
        #expect(artifacts2?.mcpServers.isEmpty == true, "Excluded MCP server should be removed")
    }

    @Test("Newly excluded MCP server is removed from artifact record")
    func excludedMCPServerIsRemoved() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-a",
                    displayName: "MCP A",
                    description: "First MCP server",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-excl-a", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
                ComponentDefinition(
                    id: "test-pack.mcp-b",
                    displayName: "MCP B",
                    description: "Second MCP server",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-excl-b", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        let mockCLI = MockClaudeCLI()
        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir, mockCLI: mockCLI)

        // First sync: both included
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: [:]
        )

        let state1 = try ProjectState(projectRoot: tmpDir)
        let artifacts1 = state1.artifacts(for: "test-pack")
        #expect(artifacts1?.mcpServers.count == 2)

        // Reset mock to track only the second sync's calls
        mockCLI.mcpRemoveCalls = []

        // Second sync: exclude mcp-b
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.mcp-b"]]
        )

        // Verify mcp-excl-b was removed via the mock
        #expect(mockCLI.mcpRemoveCalls.contains { $0.name == "mcp-excl-b" })

        let state2 = try ProjectState(projectRoot: tmpDir)
        let artifacts2 = state2.artifacts(for: "test-pack")
        #expect(artifacts2?.mcpServers.count == 1)
        #expect(artifacts2?.mcpServers.first?.name == "mcp-excl-a")
    }

    @Test("Newly excluded file is removed from disk and artifact record")
    func excludedCopyFileIsRemoved() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let skillsDir = claudeDir.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        // Create a source file the pack will install
        let sourceFile = tmpDir.appendingPathComponent("my-skill.md")
        try "skill content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "A skill file",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(
                        source: sourceFile,
                        destination: "my-skill.md",
                        fileType: .skill
                    )
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // First sync: skill included
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: [:]
        )

        let destFile = skillsDir.appendingPathComponent("my-skill.md")
        #expect(FileManager.default.fileExists(atPath: destFile.path))

        let state1 = try ProjectState(projectRoot: tmpDir)
        #expect(state1.artifacts(for: "test-pack")?.files.isEmpty == false)

        // Second sync: skill excluded
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.skill-a"]]
        )

        #expect(!FileManager.default.fileExists(atPath: destFile.path))

        let state2 = try ProjectState(projectRoot: tmpDir)
        #expect(state2.artifacts(for: "test-pack")?.files.isEmpty == true)
    }

    @Test("First run with exclusion does not crash")
    func firstRunWithExclusionDoesNotCrash() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-a",
                    displayName: "MCP A",
                    description: "An MCP server",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-firstrun", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // First-ever sync with component already excluded — should not error
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.mcp-a"]]
        )

        let state = try ProjectState(projectRoot: tmpDir)
        #expect(state.artifacts(for: "test-pack")?.mcpServers.isEmpty == true)
    }

    @Test("Re-included file is reinstalled after exclusion")
    func reincludedComponentIsReinstalled() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let skillsDir = claudeDir.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("reinclude-skill.md")
        try "skill content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-r",
                    displayName: "Skill R",
                    description: "A skill file",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(
                        source: sourceFile,
                        destination: "reinclude-skill.md",
                        fileType: .skill
                    )
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        let destFile = skillsDir.appendingPathComponent("reinclude-skill.md")

        // First sync: included
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: [:]
        )
        #expect(FileManager.default.fileExists(atPath: destFile.path))
        let state1 = try ProjectState(projectRoot: tmpDir)
        #expect(state1.artifacts(for: "test-pack")?.files.isEmpty == false)

        // Second sync: excluded
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["test-pack": ["test-pack.skill-r"]]
        )
        #expect(!FileManager.default.fileExists(atPath: destFile.path))
        let state2 = try ProjectState(projectRoot: tmpDir)
        #expect(state2.artifacts(for: "test-pack")?.files.isEmpty == true)

        // Third sync: re-included
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: [:]
        )
        #expect(FileManager.default.fileExists(atPath: destFile.path))
        let state3 = try ProjectState(projectRoot: tmpDir)
        #expect(state3.artifacts(for: "test-pack")?.files.isEmpty == false)
    }
}

// MARK: - Stale Artifact Reconciliation Tests

struct StaleArtifactReconciliationTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-stale-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(
        projectPath: URL,
        home: URL? = nil,
        mockCLI: MockClaudeCLI = MockClaudeCLI()
    ) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: mockCLI
        )
    }

    @Test("Stale file is removed when component is dropped from pack")
    func staleFileRemovedOnPackUpdate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        let skillsDir = claudeDir.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        let sourceA = tmpDir.appendingPathComponent("skill-a.md")
        try "skill a".write(to: sourceA, atomically: true, encoding: .utf8)
        let sourceB = tmpDir.appendingPathComponent("skill-b.md")
        try "skill b".write(to: sourceB, atomically: true, encoding: .utf8)

        // Pack v1: two skills
        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "First skill",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(source: sourceA, destination: "skill-a.md", fileType: .skill)
                ),
                ComponentDefinition(
                    id: "test-pack.skill-b",
                    displayName: "Skill B",
                    description: "Second skill",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(source: sourceB, destination: "skill-b.md", fileType: .skill)
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // First sync: both skills installed
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let destA = skillsDir.appendingPathComponent("skill-a.md")
        let destB = skillsDir.appendingPathComponent("skill-b.md")
        #expect(FileManager.default.fileExists(atPath: destA.path))
        #expect(FileManager.default.fileExists(atPath: destB.path))

        // Pack v2: skill-b removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.skill-a",
                    displayName: "Skill A",
                    description: "First skill",
                    type: .skill,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .copyPackFile(source: sourceA, destination: "skill-a.md", fileType: .skill)
                ),
            ]
        )

        // Second sync: stale skill-b should be removed
        try configurator.configure(packs: [packV2], confirmRemovals: false)

        #expect(FileManager.default.fileExists(atPath: destA.path))
        #expect(!FileManager.default.fileExists(atPath: destB.path))

        let state = try ProjectState(projectRoot: tmpDir)
        let files = state.artifacts(for: "test-pack")?.files ?? []
        #expect(files.contains(where: { $0.contains("skill-a.md") }))
        #expect(!files.contains(where: { $0.contains("skill-b.md") }))
    }

    @Test("Stale MCP server is removed when component is dropped from pack")
    func staleMCPServerRemovedOnPackUpdate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Pack v1: two MCP servers
        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-keep",
                    displayName: "MCP Keep",
                    description: "Kept MCP server",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-keep", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
                ComponentDefinition(
                    id: "test-pack.mcp-drop",
                    displayName: "MCP Drop",
                    description: "MCP server to be dropped",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-drop", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        let mockCLI = MockClaudeCLI()
        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir, mockCLI: mockCLI)

        // First sync: both MCP servers installed
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let state1 = try ProjectState(projectRoot: tmpDir)
        #expect(state1.artifacts(for: "test-pack")?.mcpServers.count == 2)

        // Reset mock to track only the second sync's calls
        mockCLI.mcpRemoveCalls = []

        // Pack v2: mcp-drop removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.mcp-keep",
                    displayName: "MCP Keep",
                    description: "Kept MCP server",
                    type: .mcpServer,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .mcpServer(MCPServerConfig(
                        name: "mcp-keep", command: "/usr/bin/true", args: [], env: [:]
                    ))
                ),
            ]
        )

        // Second sync: stale mcp-drop should be reconciled
        try configurator.configure(packs: [packV2], confirmRemovals: false)

        // Verify mcp-drop removal was attempted via mock
        #expect(mockCLI.mcpRemoveCalls.contains { $0.name == "mcp-drop" })

        let state2 = try ProjectState(projectRoot: tmpDir)
        let mcpServers = state2.artifacts(for: "test-pack")?.mcpServers ?? []
        #expect(mcpServers.count == 1)
        #expect(mcpServers.first?.name == "mcp-keep")
    }

    @Test("Stale settingsMerge keys are cleaned up on re-sync")
    func staleSettingsKeysCleanedUp() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Pack v1: has a settingsMerge component
        let settingsFileV1 = tmpDir.appendingPathComponent("pack-settings-v1.json")
        try """
        {"env": {"MY_VAR": "hello"}}
        """.write(to: settingsFileV1, atomically: true, encoding: .utf8)

        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                ComponentDefinition(
                    id: "test-pack.settings",
                    displayName: "Settings",
                    description: "Pack settings",
                    type: .configuration,
                    packIdentifier: "test-pack",
                    dependencies: [],
                    isRequired: false,
                    installAction: .settingsMerge(source: settingsFileV1)
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)

        // First sync: settings key installed
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let settingsPath = claudeDir.appendingPathComponent("settings.local.json")
        let settings1 = try Settings.load(from: settingsPath)
        let json1 = try JSONSerialization.jsonObject(
            with: #require(settings1.extraJSON["env"])
        ) as? [String: Any]
        #expect(json1?["MY_VAR"] as? String == "hello")

        // Pack v2: settingsMerge component removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: []
        )

        // Second sync: stale settings key should be removed
        try configurator.configure(packs: [packV2], confirmRemovals: false)

        // settings.local.json should be removed (empty content) or not contain env key
        if FileManager.default.fileExists(atPath: settingsPath.path) {
            let settings2 = try Settings.load(from: settingsPath)
            #expect(settings2.extraJSON["env"] == nil)
        }
    }

    @Test("Stale template sections are removed from CLAUDE file on pack update")
    func staleTemplateSectionsRemoved() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Pack v1: two template sections
        let packV1 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [
                TemplateContribution(
                    sectionIdentifier: "test-pack.section-a",
                    templateContent: "Section A content",
                    placeholders: []
                ),
                TemplateContribution(
                    sectionIdentifier: "test-pack.section-b",
                    templateContent: "Section B content",
                    placeholders: []
                ),
            ]
        )

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        let claudePath = tmpDir.appendingPathComponent("CLAUDE.local.md")

        // First sync: both sections written
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let content1 = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(content1.contains("mcs:begin test-pack.section-a"))
        #expect(content1.contains("mcs:begin test-pack.section-b"))

        // Pack v2: section-b removed
        let packV2 = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            templates: [
                TemplateContribution(
                    sectionIdentifier: "test-pack.section-a",
                    templateContent: "Section A content",
                    placeholders: []
                ),
            ]
        )

        // Second sync: stale section-b should be removed from file
        try configurator.configure(packs: [packV2], confirmRemovals: false)

        let content2 = try String(contentsOf: claudePath, encoding: .utf8)
        #expect(content2.contains("mcs:begin test-pack.section-a"))
        #expect(!content2.contains("mcs:begin test-pack.section-b"))
        #expect(!content2.contains("Section B content"))

        // Artifact record should only have section-a
        let state = try ProjectState(projectRoot: tmpDir)
        let sections = state.artifacts(for: "test-pack")?.templateSections ?? []
        #expect(sections == ["test-pack.section-a"])
    }
}

// MARK: - Corrupt State Abort Tests

struct CorruptStateAbortTests {
    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-corrupt-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(projectPath: URL, home: URL? = nil) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env),
            claudeCLI: MockClaudeCLI()
        )
    }

    @Test("configure throws when .mcs-project is corrupt")
    func corruptStateAborts() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write corrupt JSON to .mcs-project
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        try Data("{ not valid json !!!".utf8).write(to: stateFile)

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        let pack = MockTechPack(identifier: "test-pack", displayName: "Test")

        #expect(throws: (any Error).self) {
            try configurator.configure(packs: [pack])
        }
    }

    @Test("configure succeeds when .mcs-project does not exist")
    func missingStateIsNotAnError() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configurator = makeConfigurator(projectPath: tmpDir, home: tmpDir)
        let pack = MockTechPack(identifier: "test-pack", displayName: "Test")

        // Should not throw — missing file is a fresh project, not corruption
        try configurator.configure(packs: [pack])
    }
}

// MARK: - parseRepoName Tests

struct ParseRepoNameTests {
    @Test("HTTPS URL with .git suffix")
    func httpsWithGit() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://github.com/user/awesome-app.git") == "awesome-app")
    }

    @Test("HTTPS URL without .git suffix")
    func httpsWithoutGit() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://github.com/user/repo") == "repo")
    }

    @Test("SCP-style SSH URL")
    func sshScp() {
        #expect(ConfiguratorSupport.parseRepoName(from: "git@github.com:user/awesome-app.git") == "awesome-app")
    }

    @Test("ssh:// protocol URL")
    func sshProtocol() {
        #expect(ConfiguratorSupport.parseRepoName(from: "ssh://git@github.com/user/repo.git") == "repo")
    }

    @Test("GitLab HTTPS URL")
    func gitlabHttps() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://gitlab.com/org/my-project.git") == "my-project")
    }

    @Test("GitLab SSH URL")
    func gitlabSsh() {
        #expect(ConfiguratorSupport.parseRepoName(from: "git@gitlab.com:org/my-project.git") == "my-project")
    }

    @Test("GitLab subgroup HTTPS URL")
    func gitlabSubgroup() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://gitlab.com/org/subgroup/repo.git") == "repo")
    }

    @Test("GitLab subgroup SSH URL")
    func gitlabSubgroupSsh() {
        #expect(ConfiguratorSupport.parseRepoName(from: "git@gitlab.com:org/subgroup/repo.git") == "repo")
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(ConfiguratorSupport.parseRepoName(from: "") == nil)
    }

    @Test("Whitespace-only returns nil")
    func whitespaceOnly() {
        #expect(ConfiguratorSupport.parseRepoName(from: "   \n") == nil)
    }

    @Test("URL ending in just .git returns nil")
    func onlyDotGit() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://github.com/.git") == nil)
    }

    @Test("Trailing newline is trimmed")
    func trailingNewline() {
        #expect(ConfiguratorSupport.parseRepoName(from: "https://github.com/user/repo.git\n") == "repo")
    }

    @Test("file:// protocol URL")
    func fileProtocol() {
        #expect(ConfiguratorSupport.parseRepoName(from: "file:///Users/dev/repos/my-repo.git") == "my-repo")
    }
}
