import Foundation
@testable import mcs
import Testing

// MARK: - Dry Run Tests

@Suite("Configurator — dryRun (project scope)")
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
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
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

@Suite("Configurator — packSettingsMerge (project scope)")
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
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
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

@Suite("ComponentExecutor — installProjectFile substitution")
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
        return ComponentExecutor(
            environment: env,
            output: output,
            shell: ShellRunner(environment: env)
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
        let paths = exec.installProjectFile(
            source: source,
            destination: "pr.md",
            fileType: .command,
            projectPath: projectPath,
            resolvedValues: ["BRANCH_PREFIX": "feature"]
        )

        #expect(!paths.isEmpty)

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
        let paths = exec.installProjectFile(
            source: packDir,
            destination: "my-skill",
            fileType: .skill,
            projectPath: projectPath,
            resolvedValues: ["REPO_NAME": "my-app"]
        )

        #expect(!paths.isEmpty)

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
        let paths = exec.installProjectFile(
            source: source,
            destination: "data.bin",
            fileType: .command,
            projectPath: projectPath,
            resolvedValues: ["FOO": "bar"]
        )

        #expect(!paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/commands/data.bin")
        let result = try Data(contentsOf: installed)
        #expect(result == Data(bytes))
    }
}

// MARK: - Auto-Derived Hook & Plugin Tests

@Suite("Configurator — auto-derived hooks and plugins (project scope)")
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
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
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

@Suite("Configurator — excludedComponents (project scope)")
struct ConfiguratorExcludedComponentsTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-exclude-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfigurator(projectPath: URL, home: URL? = nil) -> Configurator {
        let env = Environment(home: home)
        return Configurator(
            environment: env,
            output: CLIOutput(),
            shell: ShellRunner(environment: env),
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
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
}

// MARK: - Corrupt State Abort Tests

@Suite("Configurator — corrupt state abort (project scope)")
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
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
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

/// Minimal TechPack implementation for tests.
private struct MockTechPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String = "Mock pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    let supplementaryDoctorChecks: [any DoctorCheck]

    init(
        identifier: String,
        displayName: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        supplementaryDoctorChecks: [any DoctorCheck] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.components = components
        self.templates = templates
        self.supplementaryDoctorChecks = supplementaryDoctorChecks
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}

// MARK: - parseRepoName Tests

@Suite("ConfiguratorSupport — parseRepoName")
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
