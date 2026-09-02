import Foundation
@testable import mcs
import Testing

// MARK: - Test Bed

/// Reusable sandbox environment for lifecycle tests.
private struct LifecycleTestBed {
    let home: URL
    let project: URL
    let env: Environment
    let mockCLI: MockClaudeCLI

    init() throws {
        (home, project) = try makeSandboxProject(label: "lifecycle")
        env = Environment(home: home)
        mockCLI = MockClaudeCLI()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }

    func makeConfigurator(registry: TechPackRegistry = TechPackRegistry()) -> Configurator {
        Configurator(
            environment: env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: env),
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: project, environment: env),
            claudeCLI: mockCLI
        )
    }

    func makeDoctorRunner(registry: TechPackRegistry, packFilter: String? = nil) -> DoctorRunner {
        DoctorRunner(
            fixMode: false,
            skipConfirmation: true,
            packFilter: packFilter,
            registry: registry,
            environment: env,
            projectRootOverride: project
        )
    }

    func makeGlobalSyncConfigurator(registry: TechPackRegistry = TechPackRegistry()) -> Configurator {
        Configurator(
            environment: env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: env),
            registry: registry,
            strategy: GlobalSyncStrategy(environment: env),
            claudeCLI: mockCLI
        )
    }

    func makeGlobalDoctorRunner(registry: TechPackRegistry) -> DoctorRunner {
        DoctorRunner(
            fixMode: false,
            skipConfirmation: true,
            globalOnly: true,
            registry: registry,
            environment: env,
            projectRootOverride: nil
        )
    }

    /// Create a hook source file in a temp pack directory.
    func makeHookSource(name: String, content: String = "#!/bin/bash\necho hook") throws -> URL {
        let packDir = home.appendingPathComponent("pack-source/hooks")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let file = packDir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Create a settings merge source file.
    func makeSettingsSource(content: String) throws -> URL {
        let file = home.appendingPathComponent("pack-source/settings-\(UUID().uuidString).json")
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Create a skill source file in a temp pack directory.
    func makeSkillSource(name: String, content: String = "# Skill\nDo the thing.") throws -> URL {
        let packDir = home.appendingPathComponent("pack-source/skills")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let file = packDir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - Doctor Convenience

    func runDoctor(registry: TechPackRegistry, packFilter: String? = nil) throws {
        var runner = makeDoctorRunner(registry: registry, packFilter: packFilter)
        try runner.run()
    }

    func runGlobalDoctor(registry: TechPackRegistry) throws {
        var runner = makeGlobalDoctorRunner(registry: registry)
        try runner.run()
    }

    // MARK: - Component Factories

    func hookComponent(
        pack: String, id: String, source: URL, destination: String,
        isRequired: Bool = true,
        hookRegistration: HookRegistration? = nil
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Hook \(id)",
            type: .hookFile,
            packIdentifier: pack,
            dependencies: [],
            isRequired: isRequired,
            hookRegistration: hookRegistration,
            installAction: .copyPackFile(source: source, destination: destination, fileType: .hook)
        )
    }

    func skillComponent(
        pack: String, id: String, source: URL, destination: String
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Skill \(id)",
            type: .skill,
            packIdentifier: pack,
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(source: source, destination: destination, fileType: .skill)
        )
    }

    func commandComponent(
        pack: String, id: String, source: URL, destination: String
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Command \(id)",
            type: .command,
            packIdentifier: pack,
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(source: source, destination: destination, fileType: .command)
        )
    }

    /// Create a command source file in a temp pack directory.
    func makeCommandSource(name: String, content: String = "# Command\nDo the thing.") throws -> URL {
        let packDir = home.appendingPathComponent("pack-source/commands")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let file = packDir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func settingsComponent(pack: String, id: String, source: URL) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Settings \(id)",
            type: .configuration,
            packIdentifier: pack,
            dependencies: [],
            isRequired: true,
            installAction: .settingsMerge(source: source)
        )
    }

    func mcpComponent(
        pack: String, id: String, name: String,
        command: String = "npx", args: [String] = [], env: [String: String] = [:],
        isRequired: Bool = true
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "MCP \(id)",
            type: .mcpServer,
            packIdentifier: pack,
            dependencies: [],
            isRequired: isRequired,
            installAction: .mcpServer(MCPServerConfig(
                name: name, command: command, args: args, env: env
            ))
        )
    }

    // MARK: - Assertions

    func projectState() throws -> ProjectState {
        try ProjectState(projectRoot: project)
    }

    func settingsEnv() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsLocalPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["env"] as? [String: Any] ?? [:]
    }

    var settingsLocalPath: URL {
        project.appendingPathComponent(".claude/settings.local.json")
    }

    var claudeLocalPath: URL {
        project.appendingPathComponent("CLAUDE.local.md")
    }

    /// Derive the expected hook command string for a project-scoped hook destination.
    func projectHookCommand(_ destination: String, interpreter: String = "bash") -> String {
        "\(interpreter) .claude/hooks/\(destination)"
    }
}

// MARK: - Scenario 1: Single-Pack Lifecycle

struct SinglePackLifecycleTests {
    @Test("Full lifecycle: configure -> doctor pass -> drift -> doctor warn -> re-sync -> remove")
    func fullSinglePackLifecycle() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Build a pack with hook + template + settings
        let hookSource = try bed.makeHookSource(name: "lint.sh")
        let settingsSource = try bed.makeSettingsSource(content: """
        {
          "env": { "LINT_ENABLED": "true" }
        }
        """)

        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [
                bed.hookComponent(pack: "test-pack", id: "lint-hook", source: hookSource, destination: "lint.sh", hookRegistration: HookRegistration(event: .postToolUse)),
                bed.mcpComponent(pack: "test-pack", id: "mcp-server", name: "test-mcp", args: ["-y", "test-server"], env: ["API_KEY": "test-key"]),
                bed.settingsComponent(pack: "test-pack", id: "settings", source: settingsSource),
            ],
            templates: [TemplateContribution(
                sectionIdentifier: "test-pack",
                templateContent: "## Test Pack\nLint all the things.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [pack])

        // === Step 1: Configure ===
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify artifacts on disk
        let hookFile = bed.project.appendingPathComponent(".claude/hooks/test-pack/lint.sh")
        #expect(FileManager.default.fileExists(atPath: hookFile.path))

        let settingsData = try Data(contentsOf: bed.settingsLocalPath)
        let settingsJSON = try #require(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
        let envDict = settingsJSON["env"] as? [String: Any]
        #expect(envDict?["LINT_ENABLED"] as? String == "true")

        let claudeContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(claudeContent.contains("<!-- mcs:begin test-pack -->"))
        #expect(claudeContent.contains("Lint all the things."))
        #expect(claudeContent.contains("<!-- mcs:end test-pack -->"))

        // Verify hook command auto-derived into settings
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let postToolGroups = settings.hooks?["PostToolUse"] ?? []
        let hookCommands = postToolGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("test-pack/lint.sh")))

        // Verify MCP server was registered via MockClaudeCLI with local scope
        #expect(bed.mockCLI.mcpAddCalls.contains { $0.name == "test-mcp" && $0.scope == "local" })

        // Verify state
        let state = try bed.projectState()
        #expect(state.configuredPacks.contains("test-pack"))
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts != nil)
        #expect(artifacts?.templateSections.contains("test-pack") == true)
        #expect(artifacts?.settingsKeys.contains("env") == true)
        #expect(artifacts?.hookCommands.contains(bed.projectHookCommand("test-pack/lint.sh")) == true)
        #expect(artifacts?.mcpServers.contains { $0.name == "test-mcp" } == true)

        // === Step 2: Doctor passes ===
        try bed.runDoctor(registry: registry)

        // === Step 3: Introduce settings drift ===
        var driftedSettings = settingsJSON
        var driftedEnv = envDict ?? [:]
        driftedEnv["LINT_ENABLED"] = "false"
        driftedSettings["env"] = driftedEnv
        let driftedData = try JSONSerialization.data(withJSONObject: driftedSettings, options: [.prettyPrinted, .sortedKeys])
        try driftedData.write(to: bed.settingsLocalPath)

        // === Step 4: Doctor detects drift ===
        try bed.runDoctor(registry: registry)
        // (The runner completes — drift is reported as .warn, not a throw)

        // === Step 5: Re-sync fixes drift ===
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let fixedData = try Data(contentsOf: bed.settingsLocalPath)
        let fixedJSON = try #require(JSONSerialization.jsonObject(with: fixedData) as? [String: Any])
        let fixedEnv = fixedJSON["env"] as? [String: Any]
        #expect(fixedEnv?["LINT_ENABLED"] as? String == "true")

        // === Step 6: Remove the pack ===
        try configurator.configure(packs: [], confirmRemovals: false)

        // Verify MCP server was removed via MockClaudeCLI
        #expect(bed.mockCLI.mcpRemoveCalls.contains { $0.name == "test-mcp" })

        // Verify settings cleaned up (empty packs → settings file removed or empty)
        if FileManager.default.fileExists(atPath: bed.settingsLocalPath.path) {
            let removedData = try Data(contentsOf: bed.settingsLocalPath)
            let removedJSON = try JSONSerialization.jsonObject(with: removedData) as? [String: Any] ?? [:]
            #expect(removedJSON["env"] == nil)
        }

        // Template section should be removed from CLAUDE.local.md
        if FileManager.default.fileExists(atPath: bed.claudeLocalPath.path) {
            let removedContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
            #expect(!removedContent.contains("<!-- mcs:begin test-pack -->"))
        }
    }

    @Test("Hand-edited hook matcher is reported as drift and healed by re-sync")
    func hookMatcherDriftLifecycle() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "gate.sh")
        let pack = MockTechPack(
            identifier: "gate-pack",
            displayName: "Gate Pack",
            components: [
                bed.hookComponent(
                    pack: "gate-pack", id: "gate-hook",
                    source: hookSource, destination: "gate.sh",
                    hookRegistration: HookRegistration(event: .preToolUse, matcher: "Agent|Task")
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Sync installs the hook with the declared matcher ===
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let installed = try Settings.load(from: bed.settingsLocalPath)
        #expect(installed.hooks?["PreToolUse"]?.first?.matcher == "Agent|Task")

        var runner = bed.makeDoctorRunner(registry: registry)
        let clean = try runner.run()
        #expect(clean.warnings == 0)

        // === Step 2: Hand-edit the matcher to one that matches nothing ===
        var drifted = installed
        drifted.hooks?["PreToolUse"]?[0].matcher = "Task"
        try drifted.save(to: bed.settingsLocalPath)

        // === Step 3: Doctor reports the drift the old presence-only check missed ===
        var driftRunner = bed.makeDoctorRunner(registry: registry)
        let driftSummary = try driftRunner.run()
        #expect(driftSummary.warnings > clean.warnings)
        #expect(driftSummary.issues == clean.issues)

        // === Step 4: Re-sync heals it, which is what justifies warn over fail ===
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let healed = try Settings.load(from: bed.settingsLocalPath)
        #expect(healed.hooks?["PreToolUse"]?.first?.matcher == "Agent|Task")

        var healedRunner = bed.makeDoctorRunner(registry: registry)
        #expect(try healedRunner.run().warnings == clean.warnings)
    }

    @Test("Declarative matcher check covers a hook shipped through a settings file")
    func settingsFileHookMatcherLifecycle() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // A hook that arrives via `settingsFile:` rather than a `hook:` component never reaches
        // PackArtifactRecord.hookCommands, so HookSettingsCheck cannot see it at all. The
        // declarative assertion is the only verification available for this shape.
        let settingsSource = try bed.makeSettingsSource(content: """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Agent|Task",
                "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }]
              }
            ]
          }
        }
        """)
        var matcherCheck = ExternalHookEventExistsCheck(
            name: "Gate hook registered", section: "Hooks",
            event: "PreToolUse", matcher: "Agent|Task", commandSubstring: "gate.sh",
            isOptional: false, projectRoot: bed.project
        )
        matcherCheck.environment = bed.env

        let pack = MockTechPack(
            identifier: "settings-hook-pack",
            displayName: "Settings Hook Pack",
            components: [
                bed.settingsComponent(pack: "settings-hook-pack", id: "settings", source: settingsSource),
            ],
            supplementaryDoctorChecks: [matcherCheck]
        )
        let registry = TechPackRegistry(packs: [pack])

        // === Step 1: Sync merges the settings file, doctor confirms the matcher landed ===
        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
        let installed = try Settings.load(from: bed.settingsLocalPath)
        #expect(installed.hooks?["PreToolUse"]?.first?.matcher == "Agent|Task")

        var runner = bed.makeDoctorRunner(registry: registry)
        let clean = try runner.run()
        #expect(clean.warnings == 0)

        // === Step 2: Hand-edit the matcher to one that matches nothing ===
        var drifted = installed
        drifted.hooks?["PreToolUse"]?[0].matcher = "Task"
        try drifted.save(to: bed.settingsLocalPath)

        var driftRunner = bed.makeDoctorRunner(registry: registry)
        let driftSummary = try driftRunner.run()
        #expect(driftSummary.warnings > clean.warnings)
        // Advisory, not fatal — the registration is present, just not as declared.
        #expect(driftSummary.issues == clean.issues)
    }

    @Test("Derived hook entry wins over a settings-file copy regardless of component order")
    func derivedHookWinsOverSettingsFileInEitherOrder() throws {
        // Precedence rationale lives on `ConfiguratorSupport.mergePackComponentsIntoSettings`.
        // Specific to this test: hook destinations are always namespaced under <pack-id>/, so a
        // settings file collides with a derived entry only by spelling out that same namespaced
        // path — which is what this pack does, to force the collision rather than hope for it.
        for settingsFirst in [false, true] {
            let bed = try LifecycleTestBed()
            defer { bed.cleanup() }

            let hookSource = try bed.makeHookSource(name: "gate.sh")
            let settingsSource = try bed.makeSettingsSource(content: """
            {
              "hooks": {
                "PreToolUse": [
                  {
                    "matcher": "Task",
                    "hooks": [{ "type": "command", "command": "bash .claude/hooks/order-pack/gate.sh" }]
                  }
                ]
              }
            }
            """)

            let hook = bed.hookComponent(
                pack: "order-pack", id: "gate-hook",
                source: hookSource, destination: "gate.sh",
                hookRegistration: HookRegistration(event: .preToolUse, matcher: "Agent|Task")
            )
            let settings = bed.settingsComponent(pack: "order-pack", id: "settings", source: settingsSource)

            let pack = MockTechPack(
                identifier: "order-pack",
                displayName: "Order Pack",
                components: settingsFirst ? [settings, hook] : [hook, settings]
            )
            try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
                .configure(packs: [pack], confirmRemovals: false)

            let composed = try Settings.load(from: bed.settingsLocalPath)
            let groups = composed.hooks?["PreToolUse"] ?? []
            // The component's matcher is the one doctor can verify, so it must be the survivor.
            #expect(groups.count == 1, "settingsFirst=\(settingsFirst)")
            #expect(groups.first?.matcher == "Agent|Task", "settingsFirst=\(settingsFirst)")
        }
    }
}

// MARK: - Scenario 2: Multi-Pack Convergence

struct MultiPackConvergenceTests {
    @Test("Two packs compose correctly, selective removal cleans only one")
    func twoPackConvergence() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let settingsA = try bed.makeSettingsSource(content: """
        { "env": { "PACK_A_KEY": "valueA" } }
        """)
        let settingsB = try bed.makeSettingsSource(content: """
        { "env": { "PACK_B_KEY": "valueB" } }
        """)

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [bed.settingsComponent(pack: "pack-a", id: "settings", source: settingsA)],
            templates: [TemplateContribution(
                sectionIdentifier: "pack-a",
                templateContent: "## Pack A\nPack A content.",
                placeholders: []
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [bed.settingsComponent(pack: "pack-b", id: "settings", source: settingsB)],
            templates: [TemplateContribution(
                sectionIdentifier: "pack-b",
                templateContent: "## Pack B\nPack B content.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Configure both ===
        try configurator.configure(packs: [packA, packB], confirmRemovals: false)

        let envDict = try bed.settingsEnv()
        #expect(envDict["PACK_A_KEY"] as? String == "valueA")
        #expect(envDict["PACK_B_KEY"] as? String == "valueB")

        let claudeContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(claudeContent.contains("<!-- mcs:begin pack-a -->"))
        #expect(claudeContent.contains("<!-- mcs:begin pack-b -->"))

        // === Step 2: Doctor passes ===
        try bed.runDoctor(registry: registry)

        // === Step 3: Remove pack A only ===
        try configurator.configure(packs: [packB], confirmRemovals: false)

        let afterEnv = try bed.settingsEnv()
        #expect(afterEnv["PACK_A_KEY"] == nil)
        #expect(afterEnv["PACK_B_KEY"] as? String == "valueB")

        let afterClaude = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(!afterClaude.contains("<!-- mcs:begin pack-a -->"))
        #expect(afterClaude.contains("<!-- mcs:begin pack-b -->"))

        // State only has pack-b
        let state = try bed.projectState()
        #expect(!state.configuredPacks.contains("pack-a"))
        #expect(state.configuredPacks.contains("pack-b"))

        // === Step 4: Re-add pack A ===
        try configurator.configure(packs: [packA, packB], confirmRemovals: false)

        let restoredEnv = try bed.settingsEnv()
        #expect(restoredEnv["PACK_A_KEY"] as? String == "valueA")
        #expect(restoredEnv["PACK_B_KEY"] as? String == "valueB")
    }
}

// MARK: - Scenario 2b: Cross-Pack File Collision Prevention

struct CrossPackCollisionTests {
    @Test("Two packs with same hook filename install to distinct namespaced paths")
    func namespacedHookDestinations() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSourceA = try bed.makeHookSource(name: "lint-a.sh", content: "#!/bin/bash\necho pack-a")
        let hookSourceB = try bed.makeHookSource(name: "lint-b.sh", content: "#!/bin/bash\necho pack-b")

        // Raw destinations — resolver detects the collision and namespaces them
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [
                bed.hookComponent(
                    pack: "pack-a", id: "lint",
                    source: hookSourceA, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [
                bed.hookComponent(
                    pack: "pack-b", id: "lint",
                    source: hookSourceB, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Configure both packs — collision resolver namespaces both ===
        try configurator.configure(packs: [packA, packB], confirmRemovals: false)

        // Verify both files exist at distinct namespaced paths
        let fileA = bed.project.appendingPathComponent(".claude/hooks/pack-a/lint.sh")
        let fileB = bed.project.appendingPathComponent(".claude/hooks/pack-b/lint.sh")
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        #expect(FileManager.default.fileExists(atPath: fileB.path))

        // Verify both hook commands are registered in settings
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let preToolGroups = settings.hooks?["PreToolUse"] ?? []
        let hookCommands = preToolGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("pack-a/lint.sh")))
        #expect(hookCommands.contains(bed.projectHookCommand("pack-b/lint.sh")))

        // Verify artifact records are distinct
        let state = try bed.projectState()
        let artifactsA = state.artifacts(for: "pack-a")
        let artifactsB = state.artifacts(for: "pack-b")
        #expect(artifactsA?.hookCommands.contains(bed.projectHookCommand("pack-a/lint.sh")) == true)
        #expect(artifactsB?.hookCommands.contains(bed.projectHookCommand("pack-b/lint.sh")) == true)

        // === Step 2: Remove pack A — pack B stays namespaced (hooks always use <pack-id>/) ===
        try configurator.configure(packs: [packB], confirmRemovals: false)

        #expect(!FileManager.default.fileExists(atPath: fileA.path))
        // Pack B stays at its namespaced path (hooks are always namespaced)
        #expect(FileManager.default.fileExists(atPath: fileB.path))

        let afterSettings = try Settings.load(from: bed.settingsLocalPath)
        let afterGroups = afterSettings.hooks?["PreToolUse"] ?? []
        let afterCommands = afterGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(!afterCommands.contains(bed.projectHookCommand("pack-a/lint.sh")))
        #expect(afterCommands.contains(bed.projectHookCommand("pack-b/lint.sh")))
    }

    @Test("Single pack hook installs to namespaced path (hooks always use <pack-id>/)")
    func singlePackNamespacedHook() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "lint.sh", content: "#!/bin/bash\necho lint")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.hookComponent(
                    pack: "my-pack", id: "lint",
                    source: hookSource, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Hooks are always namespaced into <pack-id>/ subdirectory
        let namespacedFile = bed.project.appendingPathComponent(".claude/hooks/my-pack/lint.sh")
        let flatFile = bed.project.appendingPathComponent(".claude/hooks/lint.sh")
        #expect(FileManager.default.fileExists(atPath: namespacedFile.path))
        #expect(!FileManager.default.fileExists(atPath: flatFile.path))

        // Hook command should use namespaced path
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let preToolGroups = settings.hooks?["PreToolUse"] ?? []
        let hookCommands = preToolGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("my-pack/lint.sh")))
    }
}

// MARK: - Scenario 2b-dry: Cross-Pack Collision Dry Run

struct CrossPackCollisionDryRunTests {
    @Test("dryRun with colliding hook destinations completes without error")
    func dryRunWithCollidingHooks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSourceA = try bed.makeHookSource(name: "lint-a.sh", content: "#!/bin/bash\necho pack-a")
        let hookSourceB = try bed.makeHookSource(name: "lint-b.sh", content: "#!/bin/bash\necho pack-b")

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [
                bed.hookComponent(
                    pack: "pack-a", id: "lint",
                    source: hookSourceA, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [
                bed.hookComponent(
                    pack: "pack-b", id: "lint",
                    source: hookSourceB, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        let configurator = bed.makeConfigurator(registry: registry)

        // dryRun should complete without error — the collision resolver
        // namespaces both hooks before the summary is printed.
        try configurator.dryRun(packs: [packA, packB])

        // Verify no artifacts were written to disk (dry-run is read-only)
        let flatPath = bed.project.appendingPathComponent(".claude/hooks/lint.sh")
        let namespacedA = bed.project.appendingPathComponent(".claude/hooks/pack-a/lint.sh")
        let namespacedB = bed.project.appendingPathComponent(".claude/hooks/pack-b/lint.sh")
        #expect(!FileManager.default.fileExists(atPath: flatPath.path))
        #expect(!FileManager.default.fileExists(atPath: namespacedA.path))
        #expect(!FileManager.default.fileExists(atPath: namespacedB.path))
    }

    @Test("dryRun after configure shows consistent namespaced paths")
    func dryRunAfterConfigureConsistent() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSourceA = try bed.makeHookSource(name: "dr-a.sh", content: "#!/bin/bash\necho pack-a")
        let hookSourceB = try bed.makeHookSource(name: "dr-b.sh", content: "#!/bin/bash\necho pack-b")

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [
                bed.hookComponent(
                    pack: "pack-a", id: "lint",
                    source: hookSourceA, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .postToolUse)
                ),
            ],
            templates: []
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [
                bed.hookComponent(
                    pack: "pack-b", id: "lint",
                    source: hookSourceB, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .postToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        let configurator = bed.makeConfigurator(registry: registry)

        // Configure first so state exists
        try configurator.configure(packs: [packA, packB], confirmRemovals: false)

        // dryRun on already-configured packs should also complete without error
        try configurator.dryRun(packs: [packA, packB])
    }
}

// MARK: - Scenario 2b: Pre-existing User File Protection

struct UserFileProtectionTests {
    @Test("Pre-existing user hook is preserved — pack hook installs to namespaced path")
    func preExistingUserHookPreserved() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // User manually creates a hook before mcs sync
        let userHookDir = bed.project.appendingPathComponent(".claude/hooks")
        try FileManager.default.createDirectory(at: userHookDir, withIntermediateDirectories: true)
        let userHookFile = userHookDir.appendingPathComponent("lint.sh")
        try "#!/bin/bash\necho user-hook".write(to: userHookFile, atomically: true, encoding: .utf8)

        let hookSource = try bed.makeHookSource(name: "pack-lint.sh", content: "#!/bin/bash\necho pack-hook")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.hookComponent(
                    pack: "my-pack", id: "lint",
                    source: hookSource, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // User's file is untouched (hooks always namespace, so pack goes to my-pack/lint.sh)
        let userContent = try String(contentsOf: userHookFile, encoding: .utf8)
        #expect(userContent.contains("user-hook"))

        // Pack's hook is at namespaced path
        let packHookFile = bed.project.appendingPathComponent(".claude/hooks/my-pack/lint.sh")
        #expect(FileManager.default.fileExists(atPath: packHookFile.path))
        let packContent = try String(contentsOf: packHookFile, encoding: .utf8)
        #expect(packContent.contains("pack-hook"))

        // Hook command uses namespaced path
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let preToolGroups = settings.hooks?["PreToolUse"] ?? []
        let hookCommands = preToolGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("my-pack/lint.sh")))
    }

    @Test("Pre-existing user command is preserved — pack command installs to namespaced path")
    func preExistingUserCommandPreserved() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // User manually creates a command before mcs sync
        let userCmdDir = bed.project.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: userCmdDir, withIntermediateDirectories: true)
        let userCmdFile = userCmdDir.appendingPathComponent("pr.md")
        try "# My PR command\nuser content".write(to: userCmdFile, atomically: true, encoding: .utf8)

        let cmdSource = try bed.makeCommandSource(name: "pr.md", content: "# Pack PR\npack content")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.commandComponent(
                    pack: "my-pack", id: "pr",
                    source: cmdSource, destination: "pr.md"
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // User's file is untouched
        let userContent = try String(contentsOf: userCmdFile, encoding: .utf8)
        #expect(userContent.contains("user content"))

        // Pack's command is at namespaced path
        let packCmdFile = bed.project.appendingPathComponent(".claude/commands/my-pack/pr.md")
        #expect(FileManager.default.fileExists(atPath: packCmdFile.path))
        let packContent = try String(contentsOf: packCmdFile, encoding: .utf8)
        #expect(packContent.contains("pack content"))
    }

    @Test("Tracked file does not trigger false-positive namespace on re-sync")
    func trackedFileNotFalsePositive() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let cmdSource = try bed.makeCommandSource(name: "pr.md", content: "# Pack PR\npack content")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.commandComponent(
                    pack: "my-pack", id: "pr",
                    source: cmdSource, destination: "pr.md"
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // First sync — installs at flat path
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let flatFile = bed.project.appendingPathComponent(".claude/commands/pr.md")
        #expect(FileManager.default.fileExists(atPath: flatFile.path))

        // Second sync — file is tracked, should stay at flat path
        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(FileManager.default.fileExists(atPath: flatFile.path))

        // No namespaced version should exist
        let namespacedFile = bed.project.appendingPathComponent(".claude/commands/my-pack/pr.md")
        #expect(!FileManager.default.fileExists(atPath: namespacedFile.path))
    }

    @Test("Hook always namespaced even without pre-existing file")
    func hookAlwaysNamespacedSinglePack() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "lint.sh", content: "#!/bin/bash\necho lint")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.hookComponent(
                    pack: "my-pack", id: "lint",
                    source: hookSource, destination: "lint.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: []
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Hook installed at namespaced path
        let namespacedFile = bed.project.appendingPathComponent(".claude/hooks/my-pack/lint.sh")
        let flatFile = bed.project.appendingPathComponent(".claude/hooks/lint.sh")
        #expect(FileManager.default.fileExists(atPath: namespacedFile.path))
        #expect(!FileManager.default.fileExists(atPath: flatFile.path))
    }
}

// MARK: - Scenario 3: Pack Update with Template Change

struct PackUpdateTemplateTests {
    @Test("Template v1 -> v2: doctor detects, re-sync fixes")
    func templateUpdateDetectedByDoctor() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packV1 = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "my-pack",
                templateContent: "## My Pack v1\nVersion 1 content.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [packV1])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Configure with v1 ===
        try configurator.configure(packs: [packV1], confirmRemovals: false)

        let content = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(content.contains("Version 1 content."))

        // === Step 2: Doctor passes with v1 ===
        try bed.runDoctor(registry: registry)

        // === Step 3: Create v2 pack and re-configure ===
        let packV2 = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "my-pack",
                templateContent: "## My Pack v2\nVersion 2 content.",
                placeholders: []
            )]
        )
        let registryV2 = TechPackRegistry(packs: [packV2])
        let configuratorV2 = bed.makeConfigurator(registry: registryV2)
        try configuratorV2.configure(packs: [packV2], confirmRemovals: false)

        // Verify content updated
        let updatedContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(updatedContent.contains("Version 2 content."))
        #expect(!updatedContent.contains("Version 1 content."))

        // === Step 4: Doctor passes with v2 ===
        try bed.runDoctor(registry: registryV2)
    }
}

// MARK: - Scenario 4: Component Exclusion Lifecycle

struct ComponentExclusionLifecycleTests {
    @Test("Exclude component removes its artifacts, re-include restores them")
    func excludeAndReinclude() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookA = try bed.makeHookSource(name: "hookA.sh", content: "#!/bin/bash\necho A")
        let hookB = try bed.makeHookSource(name: "hookB.sh", content: "#!/bin/bash\necho B")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.hookComponent(pack: "my-pack", id: "hookA", source: hookA, destination: "hookA.sh", isRequired: false),
                bed.hookComponent(pack: "my-pack", id: "hookB", source: hookB, destination: "hookB.sh", isRequired: false),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        let hookAPath = bed.project.appendingPathComponent(".claude/hooks/my-pack/hookA.sh")
        let hookBPath = bed.project.appendingPathComponent(".claude/hooks/my-pack/hookB.sh")

        // === Step 1: Configure with both ===
        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(FileManager.default.fileExists(atPath: hookAPath.path))
        #expect(FileManager.default.fileExists(atPath: hookBPath.path))

        // === Step 2: Reconfigure with hookA excluded ===
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["my-pack": Set(["my-pack.hookA"])]
        )
        #expect(!FileManager.default.fileExists(atPath: hookAPath.path))
        #expect(FileManager.default.fileExists(atPath: hookBPath.path))

        // Verify exclusion recorded in state
        let state = try bed.projectState()
        let excluded = state.excludedComponents(for: "my-pack")
        #expect(excluded.contains("my-pack.hookA"))

        // === Step 3: Re-include all ===
        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(FileManager.default.fileExists(atPath: hookAPath.path))
        #expect(FileManager.default.fileExists(atPath: hookBPath.path))
    }
}

// MARK: - Scenario 5: Global Scope Sync + Doctor

struct GlobalScopeLifecycleTests {
    @Test("Global scope sync installs artifacts and doctor passes")
    func globalSyncAndDoctor() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "global-hook.sh")

        let pack = MockTechPack(
            identifier: "global-pack",
            displayName: "Global Pack",
            components: [bed.hookComponent(pack: "global-pack", id: "hook", source: hookSource, destination: "global-hook.sh")]
        )
        let registry = TechPackRegistry(packs: [pack])

        // === Configure global scope ===
        let configurator = bed.makeGlobalSyncConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify hook installed in ~/.claude/hooks/
        let globalHook = bed.env.hooksDirectory.appendingPathComponent("global-pack/global-hook.sh")
        #expect(FileManager.default.fileExists(atPath: globalHook.path))

        // Verify global state
        let globalState = try ProjectState(stateFile: bed.env.globalStateFile)
        #expect(globalState.configuredPacks.contains("global-pack"))

        // === Doctor passes ===
        try bed.runGlobalDoctor(registry: registry)
    }
}

// MARK: - Scenario 5b: Shell Command Component Lifecycle

struct ShellCommandLifecycleTests {
    @Test("shellCommand component executes during global sync and survives re-sync")
    func shellCommandGlobalSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Use a harmless shell command that creates a marker file
        let markerPath = bed.home.appendingPathComponent("shell-marker.txt").path
        let pack = MockTechPack(
            identifier: "shell-pack",
            displayName: "Shell Pack",
            components: [
                ComponentDefinition(
                    id: "shell-pack.install",
                    displayName: "Shell install",
                    description: "Install via shell",
                    type: .configuration,
                    packIdentifier: "shell-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .shellCommand(command: "touch '\(markerPath)'")
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])

        // === Configure ===
        let configurator = bed.makeGlobalSyncConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify the shell command ran
        #expect(FileManager.default.fileExists(atPath: markerPath))

        // Verify state
        let state = try ProjectState(stateFile: bed.env.globalStateFile)
        #expect(state.configuredPacks.contains("shell-pack"))

        // === Re-sync (idempotent) ===
        try FileManager.default.removeItem(atPath: markerPath)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Shell command re-runs (no isAlreadyInstalled skip without doctorChecks)
        #expect(FileManager.default.fileExists(atPath: markerPath))
    }

    @Test("shellCommand with interactive flag is accepted and state is recorded")
    func shellCommandInteractiveAccepted() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let markerPath = bed.home.appendingPathComponent("interactive-marker.txt").path
        let pack = MockTechPack(
            identifier: "interactive-pack",
            displayName: "Interactive Pack",
            components: [
                ComponentDefinition(
                    id: "interactive-pack.install",
                    displayName: "Interactive install",
                    description: "Install with interactive flag",
                    type: .configuration,
                    packIdentifier: "interactive-pack",
                    dependencies: [],
                    isRequired: true,
                    installAction: .shellCommand(command: "touch '\(markerPath)'", interactive: true)
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])

        // Configure — interactive commands use forkpty() in real ShellRunner,
        // but the test verifies the component is accepted and state is recorded.
        let configurator = bed.makeGlobalSyncConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify state records the pack
        let state = try ProjectState(stateFile: bed.env.globalStateFile)
        #expect(state.configuredPacks.contains("interactive-pack"))
    }
}

// MARK: - Scenario 6: Stale Artifact Cleanup on Pack Update

struct StaleArtifactCleanupTests {
    @Test("v1 has A,B,C -> v2 removes B renames C->D: stale artifacts cleaned")
    func staleArtifactCleanup() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let skillA = try bed.makeSkillSource(name: "skillA.md", content: "# Skill A")
        let skillB = try bed.makeSkillSource(name: "skillB.md", content: "# Skill B")
        let skillC = try bed.makeSkillSource(name: "skillC.md", content: "# Skill C")

        let packV1 = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.skillComponent(pack: "my-pack", id: "skillA", source: skillA, destination: "skillA.md"),
                bed.skillComponent(pack: "my-pack", id: "skillB", source: skillB, destination: "skillB.md"),
                bed.skillComponent(pack: "my-pack", id: "skillC", source: skillC, destination: "skillC.md"),
            ]
        )
        let registryV1 = TechPackRegistry(packs: [packV1])
        let configuratorV1 = bed.makeConfigurator(registry: registryV1)

        // === Configure with v1 ===
        try configuratorV1.configure(packs: [packV1], confirmRemovals: false)

        let skillsDir = bed.project.appendingPathComponent(".claude/skills")
        #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillA.md").path))
        #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillB.md").path))
        #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillC.md").path))

        // === Create v2: remove B, add D (C->D rename) ===
        let skillD = try bed.makeSkillSource(name: "skillD.md", content: "# Skill D (was C)")
        let packV2 = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.skillComponent(pack: "my-pack", id: "skillA", source: skillA, destination: "skillA.md"),
                bed.skillComponent(pack: "my-pack", id: "skillD", source: skillD, destination: "skillD.md"),
            ]
        )
        let registryV2 = TechPackRegistry(packs: [packV2])
        let configuratorV2 = bed.makeConfigurator(registry: registryV2)

        // === Configure with v2 ===
        try configuratorV2.configure(packs: [packV2], confirmRemovals: false)

        // A still exists, B removed, C removed, D created
        #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillA.md").path))
        #expect(!FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillB.md").path))
        #expect(!FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillC.md").path))
        #expect(FileManager.default.fileExists(atPath: skillsDir.appendingPathComponent("skillD.md").path))

        // Artifact record only tracks A and D
        let state = try bed.projectState()
        let artifacts = try #require(state.artifacts(for: "my-pack"))
        #expect(artifacts.files.contains { $0.contains("skillA.md") })
        #expect(artifacts.files.contains { $0.contains("skillD.md") })
        #expect(!artifacts.files.contains { $0.contains("skillB.md") })
        #expect(!artifacts.files.contains { $0.contains("skillC.md") })

        // === Doctor passes ===
        try bed.runDoctor(registry: registryV2)
    }
}

// MARK: - Scenario 7: Template Dependency Filtering

struct TemplateDependencyFilteringTests {
    @Test("Excluding a component removes its dependent template sections")
    func excludedComponentFiltersDependentTemplate() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "serena-hook.sh")

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.mcpComponent(pack: "my-pack", id: "serena", name: "serena", args: ["-y", "serena"], isRequired: false),
                bed.hookComponent(pack: "my-pack", id: "hook", source: hookSource, destination: "hook.sh"),
            ],
            templates: [
                TemplateContribution(
                    sectionIdentifier: "my-pack",
                    templateContent: "## My Pack\nGeneral instructions.",
                    placeholders: []
                ),
                TemplateContribution(
                    sectionIdentifier: "my-pack-serena",
                    templateContent: "## Serena Instructions\nUse Serena for code editing.",
                    placeholders: [],
                    dependencies: ["my-pack.serena"]
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Configure with all components ===
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let content = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(content.contains("<!-- mcs:begin my-pack -->"))
        #expect(content.contains("<!-- mcs:begin my-pack-serena -->"))
        #expect(content.contains("Use Serena for code editing."))

        // === Step 2: Exclude Serena → dependent template removed ===
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["my-pack": Set(["my-pack.serena"])]
        )

        let afterContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(afterContent.contains("<!-- mcs:begin my-pack -->"))
        #expect(afterContent.contains("General instructions."))
        // Serena-dependent template section should be removed
        #expect(!afterContent.contains("<!-- mcs:begin my-pack-serena -->"))
        #expect(!afterContent.contains("Use Serena for code editing."))

        // MCP server should have been removed
        #expect(bed.mockCLI.mcpRemoveCalls.contains { $0.name == "serena" })

        // === Step 3: Re-include → both templates restored ===
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let restoredContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(restoredContent.contains("<!-- mcs:begin my-pack-serena -->"))
        #expect(restoredContent.contains("Use Serena for code editing."))
    }
}

// MARK: - Scenario 8: Global Scope Exclusion + Doctor

struct GlobalScopeExclusionTests {
    @Test("Global scope exclusion recorded and doctor skips excluded checks")
    func globalExclusionAndDoctor() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookA = try bed.makeHookSource(name: "globalA.sh")
        let hookB = try bed.makeHookSource(name: "globalB.sh")

        let pack = MockTechPack(
            identifier: "global-pack",
            displayName: "Global Pack",
            components: [
                bed.hookComponent(pack: "global-pack", id: "hookA", source: hookA, destination: "globalA.sh", isRequired: false),
                bed.hookComponent(pack: "global-pack", id: "hookB", source: hookB, destination: "globalB.sh", isRequired: false),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])

        // === Step 1: Configure global with both ===
        let configurator = bed.makeGlobalSyncConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let hookAPath = bed.env.hooksDirectory.appendingPathComponent("global-pack/globalA.sh")
        let hookBPath = bed.env.hooksDirectory.appendingPathComponent("global-pack/globalB.sh")
        #expect(FileManager.default.fileExists(atPath: hookAPath.path))
        #expect(FileManager.default.fileExists(atPath: hookBPath.path))

        // === Step 2: Reconfigure with hookA excluded ===
        try configurator.configure(
            packs: [pack],
            confirmRemovals: false,
            excludedComponents: ["global-pack": Set(["global-pack.hookA"])]
        )

        #expect(!FileManager.default.fileExists(atPath: hookAPath.path))
        #expect(FileManager.default.fileExists(atPath: hookBPath.path))

        // Verify exclusion in global state
        let globalState = try ProjectState(stateFile: bed.env.globalStateFile)
        let excluded = globalState.excludedComponents(for: "global-pack")
        #expect(excluded.contains("global-pack.hookA"))

        // === Step 3: Doctor with globalOnly runs without error ===
        try bed.runGlobalDoctor(registry: registry)
    }
}

// MARK: - Scenario 9: Re-sync Restores Tampered Section Content

struct SectionRestorationTests {
    @Test("Re-sync restores tampered section content")
    func reSyncRestoresTamperedSection() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "my-pack",
                templateContent: "## My Pack\nOriginal content that should be preserved.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Configure ===
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let content = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(content.contains("Original content that should be preserved."))

        // === Tamper with section content ===
        let tamperedContent = content.replacingOccurrences(
            of: "Original content that should be preserved.",
            with: "TAMPERED by user."
        )
        try tamperedContent.write(to: bed.claudeLocalPath, atomically: true, encoding: .utf8)

        // Verify the tamper took effect
        let readBack = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(readBack.contains("TAMPERED by user."))

        // === Re-sync restores the original content ===
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let restoredContent = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(restoredContent.contains("Original content that should be preserved."))
        #expect(!restoredContent.contains("TAMPERED by user."))
    }
}

// MARK: - Scenario 9b: Marker-less CLAUDE File Preservation

struct MarkerlessPreservationTests {
    @Test("Sync into a pre-existing marker-less CLAUDE file preserves user content")
    func preExistingMarkerlessContentPreserved() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Pre-seed a hand-written CLAUDE.local.md with NO mcs markers.
        let userRules = "# My personal project rules\nAlways be concise and cite sources."
        try userRules.write(to: bed.claudeLocalPath, atomically: true, encoding: .utf8)

        let pack = MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            templates: [TemplateContribution(
                sectionIdentifier: "my-pack",
                templateContent: "## My Pack\nPack-provided guidance.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        let content = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        // User's hand-written rules survive rather than being overwritten.
        #expect(content.contains("Always be concise and cite sources."))
        // The pack section is added with markers.
        #expect(content.contains("<!-- mcs:begin my-pack -->"))
        #expect(content.contains("Pack-provided guidance."))

        // Re-sync is idempotent: prose appears exactly once, single managed section.
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let reSynced = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(occurrences(of: "Always be concise and cite sources.", in: reSynced) == 1)
        #expect(TemplateComposer.parseSections(from: reSynced).count == 1)
    }

    @Test("Single-pack swap preserves user content after all markers are stripped")
    func singlePackSwapPreservesUserContent() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            templates: [TemplateContribution(
                sectionIdentifier: "pack-a",
                templateContent: "## Pack A\nPack A content.",
                placeholders: []
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            templates: [TemplateContribution(
                sectionIdentifier: "pack-b",
                templateContent: "## Pack B\nPack B content.",
                placeholders: []
            )]
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Step 1: Configure pack A, then append user prose outside its markers ===
        try configurator.configure(packs: [packA], confirmRemovals: false)
        let seeded = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
            + "\n\nMy own notes outside markers.\n"
        try seeded.write(to: bed.claudeLocalPath, atomically: true, encoding: .utf8)

        // === Step 2: Swap to pack B only ===
        // Deselecting the sole marked pack strips every marker, leaving a marker-less
        // file that still holds the user's notes.
        try configurator.configure(packs: [packB], confirmRemovals: false)

        let afterClaude = try String(contentsOf: bed.claudeLocalPath, encoding: .utf8)
        #expect(afterClaude.contains("My own notes outside markers."))
        #expect(afterClaude.contains("<!-- mcs:begin pack-b -->"))
        #expect(!afterClaude.contains("<!-- mcs:begin pack-a -->"))
    }
}

// MARK: - Scenario 7: Hook Handler Metadata

struct HookMetadataLifecycleTests {
    @Test("Hook handler fields flow end-to-end into settings.local.json")
    func hookMetadataEndToEnd() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "lint.sh")

        let pack = MockTechPack(
            identifier: "meta-pack",
            displayName: "Meta Pack",
            components: [
                bed.hookComponent(
                    pack: "meta-pack", id: "lint",
                    source: hookSource, destination: "lint.sh",
                    hookRegistration: HookRegistration(
                        event: .postToolUse, timeout: 30,
                        isAsync: true, statusMessage: "Running lint..."
                    )
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // === Configure ===
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // === Verify settings.local.json contains hook handler fields ===
        let data = try Data(contentsOf: bed.settingsLocalPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let postToolGroups = try #require(hooks["PostToolUse"] as? [[String: Any]])
        let firstGroup = try #require(postToolGroups.first)
        let hookEntries = try #require(firstGroup["hooks"] as? [[String: Any]])
        let entry = try #require(hookEntries.first)

        #expect(entry["command"] as? String == bed.projectHookCommand("meta-pack/lint.sh"))
        #expect(entry["timeout"] as? Int == 30)
        #expect(entry["async"] as? Bool == true)
        #expect(entry["statusMessage"] as? String == "Running lint...")

        // === Doctor passes with metadata present ===
        try bed.runDoctor(registry: registry)
    }

    @Test("Hook matcher flows end-to-end into settings.local.json")
    func hookMatcherEndToEnd() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "lint.sh")

        let pack = MockTechPack(
            identifier: "matcher-pack",
            displayName: "Matcher Pack",
            components: [
                bed.hookComponent(
                    pack: "matcher-pack", id: "lint",
                    source: hookSource, destination: "lint.sh",
                    hookRegistration: HookRegistration(
                        event: .preToolUse, matcher: "Edit|Write",
                        timeout: 30
                    )
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        let data = try Data(contentsOf: bed.settingsLocalPath)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(json["hooks"] as? [String: Any])
        let preToolGroups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let firstGroup = try #require(preToolGroups.first)

        #expect(firstGroup["matcher"] as? String == "Edit|Write")

        let hookEntries = try #require(firstGroup["hooks"] as? [[String: Any]])
        let entry = try #require(hookEntries.first)
        #expect(entry["timeout"] as? Int == 30)
    }

    @Test("Hook without metadata produces clean entries (no null fields)")
    func hookWithoutMetadataNoNulls() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "guard.sh")

        let pack = MockTechPack(
            identifier: "plain-pack",
            displayName: "Plain Pack",
            components: [
                bed.hookComponent(
                    pack: "plain-pack", id: "guard",
                    source: hookSource, destination: "guard.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Read raw JSON to verify no null fields leak through
        let data = try Data(contentsOf: bed.settingsLocalPath)
        let rawJSON = try #require(String(data: data, encoding: .utf8))
        #expect(!rawJSON.contains("\"timeout\""))
        #expect(!rawJSON.contains("\"async\""))
        #expect(!rawJSON.contains("\"statusMessage\""))
    }

    // MARK: - Update check hook (global-only)

    @Test("Project sync does not inject update check hook into settings.local.json")
    func projectSyncDoesNotInjectUpdateHookLocally() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Enable update checks in config
        var config = MCSConfig()
        config.updateCheckPacks = true
        try config.save(to: bed.env.mcsConfigFile)

        // Sync with a minimal pack
        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack", components: [])
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false, excludedComponents: [:])

        // Hook must NOT be in project-scoped settings.local.json
        let fm = FileManager.default
        if fm.fileExists(atPath: bed.settingsLocalPath.path) {
            let settings = try Settings.load(from: bed.settingsLocalPath)
            let sessionStartGroups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
            let commands = sessionStartGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
            #expect(!commands.contains(UpdateChecker.hookCommand))
        }

        // syncHook puts it in global settings.json instead
        UpdateChecker.syncHook(config: config, env: bed.env, output: CLIOutput(colorsEnabled: false))
        let globalSettings = try Settings.load(from: bed.env.claudeSettings)
        let globalGroups = globalSettings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
        let globalCommands = globalGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(globalCommands.contains(UpdateChecker.hookCommand))
    }

    @Test("Update check hook not injected anywhere when config disabled")
    func updateHookAbsentWhenDisabled() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Disable update checks in config
        var config = MCSConfig()
        config.updateCheckPacks = false
        config.updateCheckCLI = false
        try config.save(to: bed.env.mcsConfigFile)

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack", components: [])
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false, excludedComponents: [:])

        // Not in project-scoped settings
        let fm = FileManager.default
        if fm.fileExists(atPath: bed.settingsLocalPath.path) {
            let settings = try Settings.load(from: bed.settingsLocalPath)
            let sessionStartGroups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
            let commands = sessionStartGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
            #expect(!commands.contains(UpdateChecker.hookCommand))
        }

        // syncHook with disabled config must not add to global either
        UpdateChecker.syncHook(config: config, env: bed.env, output: CLIOutput(colorsEnabled: false))
        let globalSettings = try Settings.load(from: bed.env.claudeSettings)
        let globalGroups = globalSettings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
        let globalCommands = globalGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(!globalCommands.contains(UpdateChecker.hookCommand))
    }

    @Test("syncHook converges global settings: enable then disable")
    func syncHookConvergesGlobalSettings() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let output = CLIOutput(colorsEnabled: false)

        // Enable → hook appears in global settings.json
        var config = MCSConfig()
        config.updateCheckPacks = true
        try config.save(to: bed.env.mcsConfigFile)

        UpdateChecker.syncHook(config: config, env: bed.env, output: output)

        let settings1 = try Settings.load(from: bed.env.claudeSettings)
        let commands1 = (settings1.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
            .flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(commands1.contains(UpdateChecker.hookCommand))

        // Disable → hook removed from global settings.json
        config.updateCheckPacks = false
        config.updateCheckCLI = false

        UpdateChecker.syncHook(config: config, env: bed.env, output: output)

        let settings2 = try Settings.load(from: bed.env.claudeSettings)
        let commands2 = (settings2.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
            .flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(!commands2.contains(UpdateChecker.hookCommand))
    }
}

// MARK: - Prompt Value Reuse Lifecycle

struct PromptValueReuseLifecycleTests {
    /// Minimal input-style prompt helper.
    private func inputPrompt(_ key: String, defaultValue: String? = nil) -> PromptDefinition {
        PromptDefinition(
            key: key, type: .input,
            label: nil, defaultValue: defaultValue, options: nil,
            detectPatterns: nil, scriptCommand: nil
        )
    }

    private func selectPrompt(_ key: String, options: [String]) -> PromptDefinition {
        PromptDefinition(
            key: key, type: .select,
            label: nil, defaultValue: nil,
            options: options.map { PromptOption(value: $0, label: $0.uppercased()) },
            detectPatterns: nil, scriptCommand: nil
        )
    }

    @Test("Second sync reuses persisted values instead of re-asking")
    func reuseOnSecondSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = MockPromptTechPack(
            identifier: "prompt-pack",
            displayName: "Prompt Pack",
            prompts: [inputPrompt("BRANCH_PREFIX"), inputPrompt("LABEL_PREFIX")],
            defaultAnswer: { "fresh-\($0)" }
        )
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)

        // First sync: no priors → mock's defaultAnswer is used
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let state1 = try bed.projectState()
        #expect(state1.resolvedValues?["BRANCH_PREFIX"] == "fresh-BRANCH_PREFIX")
        #expect(state1.resolvedValues?["LABEL_PREFIX"] == "fresh-LABEL_PREFIX")

        // Pre-seed state with custom values (as if user answered them previously)
        var state = state1
        state.setResolvedValues(["BRANCH_PREFIX": "bruno", "LABEL_PREFIX": "scope:"])
        try state.save()

        // Second sync (non-interactive testbed): reuse path silently seeds allValues;
        // MockPromptTechPack.templateValues skips keys already in resolvedValues.
        try configurator.configure(packs: [pack], confirmRemovals: false)
        let state2 = try bed.projectState()
        #expect(state2.resolvedValues?["BRANCH_PREFIX"] == "bruno")
        #expect(state2.resolvedValues?["LABEL_PREFIX"] == "scope:")
    }

    @Test("New prompt added between syncs: old values reused, new prompt asked")
    func newPromptAddedSkipsGate() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // First sync: single prompt
        let packV1 = MockPromptTechPack(
            identifier: "evolving-pack",
            displayName: "Evolving Pack",
            prompts: [inputPrompt("OLD_KEY")],
            defaultAnswer: { "v1-\($0)" }
        )
        let registry1 = TechPackRegistry(packs: [packV1])
        try bed.makeConfigurator(registry: registry1)
            .configure(packs: [packV1], confirmRemovals: false)

        // Seed the user's answer
        var state = try bed.projectState()
        state.setResolvedValues(["OLD_KEY": "user-answer"])
        try state.save()

        // Second sync: pack update adds a new prompt
        let packV2 = MockPromptTechPack(
            identifier: "evolving-pack",
            displayName: "Evolving Pack",
            prompts: [inputPrompt("OLD_KEY"), inputPrompt("NEW_KEY")],
            defaultAnswer: { "v2-\($0)" }
        )
        let registry2 = TechPackRegistry(packs: [packV2])
        try bed.makeConfigurator(registry: registry2)
            .configure(packs: [packV2], confirmRemovals: false)

        let state2 = try bed.projectState()
        // Old key kept; new key resolved via mock's default (no prior for it)
        #expect(state2.resolvedValues?["OLD_KEY"] == "user-answer")
        #expect(state2.resolvedValues?["NEW_KEY"] == "v2-NEW_KEY")
    }

    @Test("Select prior value invalidated when option is removed")
    func selectInvalidationReAsks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // First sync: select with three options
        let packV1 = MockPromptTechPack(
            identifier: "select-pack",
            displayName: "Select Pack",
            prompts: [selectPrompt("LOG_LEVEL", options: ["info", "debug", "trace"])],
            defaultAnswer: { _ in "info" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packV1]))
            .configure(packs: [packV1], confirmRemovals: false)

        // User previously chose "trace"
        var state = try bed.projectState()
        state.setResolvedValues(["LOG_LEVEL": "trace"])
        try state.save()

        // Pack update removes "trace" from options
        let packV2 = MockPromptTechPack(
            identifier: "select-pack",
            displayName: "Select Pack",
            prompts: [selectPrompt("LOG_LEVEL", options: ["info", "debug"])],
            defaultAnswer: { _ in "info" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packV2]))
            .configure(packs: [packV2], confirmRemovals: false)

        let state2 = try bed.projectState()
        // "trace" is no longer valid → partition treats as newDeclared → mock returns default "info"
        #expect(state2.resolvedValues?["LOG_LEVEL"] == "info")
    }

    @Test("Non-interactive sync reuses priors silently")
    func nonInteractiveSilentReuse() throws {
        // This test environment has no TTY, so hasInteractiveStdin == false;
        // the reuse path applies silently without prompting. Verifies that priors
        // fully short-circuit the prompt executor even when some call would have blocked.
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = MockPromptTechPack(
            identifier: "silent-pack",
            displayName: "Silent",
            prompts: [inputPrompt("KEY_A"), inputPrompt("KEY_B")],
            defaultAnswer: { _ in "SHOULD_NOT_APPEAR" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["KEY_A": "alpha", "KEY_B": "beta"])
        try state.save()

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)

        let final = try bed.projectState()
        #expect(final.resolvedValues?["KEY_A"] == "alpha")
        #expect(final.resolvedValues?["KEY_B"] == "beta")
        #expect(final.resolvedValues?["KEY_A"] != "SHOULD_NOT_APPEAR")
    }

    @Test("Removing a pack prunes its resolvedValues; a later pack with same key is asked fresh")
    func removedPackOrphanPruned() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = MockPromptTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            prompts: [inputPrompt("BRANCH_PREFIX")],
            defaultAnswer: { "a-\($0)" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA]))
            .configure(packs: [packA], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["BRANCH_PREFIX": "bruno"])
        try state.save()

        // Deselect pack A: registry still knows the pack (so unconfigure can resolve
        // survivors) but configure() passes an empty selection → removal triggers prune.
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA]))
            .configure(packs: [], confirmRemovals: false)

        // BRANCH_PREFIX should be pruned — no surviving pack declares it.
        let afterRemoval = try bed.projectState()
        #expect(afterRemoval.resolvedValues?["BRANCH_PREFIX"] == nil)

        let packB = MockPromptTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            prompts: [inputPrompt("BRANCH_PREFIX")],
            defaultAnswer: { "b-\($0)" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packB]))
            .configure(packs: [packB], confirmRemovals: false)

        // Pack B sees no prior for BRANCH_PREFIX → mock falls back to its defaultAnswer,
        // NOT the stale "bruno" from removed pack A.
        let final = try bed.projectState()
        #expect(final.resolvedValues?["BRANCH_PREFIX"] == "b-BRANCH_PREFIX")
    }

    @Test("Shared resolved key preserved when one of two declaring packs is removed")
    func sharedKeyRetainedAfterPartialRemoval() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = MockPromptTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            prompts: [inputPrompt("BRANCH_PREFIX")],
            defaultAnswer: { "a-\($0)" }
        )
        let packB = MockPromptTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            prompts: [inputPrompt("BRANCH_PREFIX")],
            defaultAnswer: { "b-\($0)" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA, packB]))
            .configure(packs: [packA, packB], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["BRANCH_PREFIX": "bruno"])
        try state.save()

        // Pack B still declares BRANCH_PREFIX, so the value must survive removal of A.
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA, packB]))
            .configure(packs: [packB], confirmRemovals: false)

        let final = try bed.projectState()
        #expect(final.resolvedValues?["BRANCH_PREFIX"] == "bruno")
    }

    @Test("Pruning skips when a configured survivor pack is missing from the registry")
    func pruningSkippedWhenSurvivorUnresolvable() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = MockPromptTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            prompts: [inputPrompt("KEY_A")],
            defaultAnswer: { "a-\($0)" }
        )
        let packB = MockPromptTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            prompts: [inputPrompt("KEY_B")],
            defaultAnswer: { "b-\($0)" }
        )
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA, packB]))
            .configure(packs: [packA, packB], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["KEY_A": "user-a", "KEY_B": "user-b"])
        try state.save()

        // Direct unconfigure with a registry that omits pack-a simulates pack-a's
        // directory being manually removed from ~/.mcs/packs/ — pack-a stays in
        // state.configuredPacks but can no longer be resolved. The prune helper
        // must refuse to run rather than silently drop keys that still belong.
        state = try bed.projectState()
        let narrowConfigurator = bed.makeConfigurator(
            registry: TechPackRegistry(packs: [packB])
        )
        narrowConfigurator.unconfigurePack("pack-b", state: &state)
        try state.save()

        let final = try bed.projectState()
        #expect(final.resolvedValues?["KEY_A"] == "user-a")
    }

    @Test("--customize forces re-ask even when priors are available")
    func customizeForceReAsk() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Track whether templateValues saw unresolved keys (re-ask path)
        // by using defaultAnswer that differs per call.
        let pack = MockPromptTechPack(
            identifier: "customize-pack",
            displayName: "Customize",
            prompts: [inputPrompt("SETTING")],
            defaultAnswer: { _ in "mock-re-asked" }
        )

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["SETTING": "user-previous"])
        try state.save()

        // Without --customize: non-interactive reuses → state stays "user-previous"
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)
        #expect(try bed.projectState().resolvedValues?["SETTING"] == "user-previous")

        // With --customize: seed bypass → mock's templateValues sees no seeded key
        // and returns priorValues["SETTING"] (still "user-previous" since MockPromptTechPack
        // uses context.priorValues as its answer source). This mirrors real behavior:
        // prompts would run but with priors as defaults. To verify the bypass, seed a
        // different prior and assert templateValues received it, not a pre-seeded resolve.
        state = try bed.projectState()
        state.setResolvedValues(["SETTING": "prior-updated"])
        try state.save()

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false, customize: true)
        // Under --customize, templateValues runs (nothing seeded), returns priorValues["SETTING"]
        #expect(try bed.projectState().resolvedValues?["SETTING"] == "prior-updated")
    }
}

// MARK: - Global Pack Blocking

/// End-to-end coverage for blocking globally-installed packs from project sync.
///
/// These drive `Configurator` directly rather than `SyncCommand.perform()`, which
/// builds its own `Environment()` and cannot be pointed at a sandboxed home.
struct GlobalPackBlockingLifecycleTests {
    @Test("Global-only pack is filtered out and never reaches project state")
    func globalOnlyPackIsNotInstalledInProject() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let shared = MockTechPack(identifier: "shared-pack", displayName: "Shared Pack")
        let projectOnly = MockTechPack(identifier: "project-pack", displayName: "Project Pack")
        let registry = TechPackRegistry(packs: [shared, projectOnly])

        // Install `shared-pack` globally.
        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)

        let globallyInstalled = try ProjectState(stateFile: bed.env.globalStateFile).configuredPacks
        #expect(globallyInstalled.contains("shared-pack"))

        // `mcs sync --all` in the project: both packs are candidates, `shared-pack`
        // is blocked because it is global and not yet configured here. Drive the real
        // filter, not a copy of it — a reimplementation here would keep passing even
        // if `performProject` stopped calling it.
        let toSync = try SyncCommand.filterGloballyBlocked(
            [shared, projectOnly],
            globallyInstalled: globallyInstalled,
            previouslyConfigured: bed.projectState().configuredPacks,
            output: CLIOutput(colorsEnabled: false)
        )
        #expect(toSync.map(\.identifier) == ["project-pack"])

        try bed.makeConfigurator(registry: registry)
            .configure(packs: toSync, confirmRemovals: false)

        let projectPacks = try bed.projectState().configuredPacks
        #expect(!projectPacks.contains("shared-pack"))
        #expect(projectPacks.contains("project-pack"))
    }

    @Test("Both-scope pack survives a project sync instead of being silently removed")
    func bothScopePackSurvivesProjectSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let shared = MockTechPack(identifier: "shared-pack", displayName: "Shared Pack")
        let registry = TechPackRegistry(packs: [shared])

        // Pre-existing state: installed in the project FIRST, then globally.
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)
        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)

        #expect(try bed.projectState().configuredPacks.contains("shared-pack"))

        // The regression guard: blocking by bare identity here would drop the pack
        // from the desired set, and `configure(confirmRemovals: false)` would
        // unconfigure it without a prompt.
        let toSync = try SyncCommand.filterGloballyBlocked(
            [shared],
            globallyInstalled: ProjectState(stateFile: bed.env.globalStateFile).configuredPacks,
            previouslyConfigured: bed.projectState().configuredPacks,
            output: CLIOutput(colorsEnabled: false)
        )
        #expect(toSync.map(\.identifier) == ["shared-pack"])

        try bed.makeConfigurator(registry: registry)
            .configure(packs: toSync, confirmRemovals: false)

        #expect(try bed.projectState().configuredPacks.contains("shared-pack"))
    }

    @Test("Missing global state blocks nothing — machines that never ran --global")
    func missingGlobalStateBlocksNothing() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        #expect(!FileManager.default.fileExists(atPath: bed.env.globalStateFile.path))

        let pack = MockTechPack(identifier: "ios", displayName: "iOS")
        // `ProjectState.load` returns early for a missing file rather than throwing,
        // so an untouched global scope yields an empty set and nothing is filtered.
        let toSync = try SyncCommand.filterGloballyBlocked(
            [pack],
            globallyInstalled: ProjectState(stateFile: bed.env.globalStateFile).configuredPacks,
            previouslyConfigured: [],
            output: CLIOutput(colorsEnabled: false)
        )
        #expect(toSync.map(\.identifier) == ["ios"])
    }

    @Test("Refuses to sync when every requested pack is globally installed")
    func refusesWhenEveryPackIsBlocked() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let shared = MockTechPack(identifier: "shared-pack", displayName: "Shared Pack")
        let registry = TechPackRegistry(packs: [shared])

        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)

        // Returning an empty pack list instead of throwing would make `configure`
        // converge on an empty desired set and unconfigure the whole project.
        #expect(throws: (any Error).self) {
            try SyncCommand.filterGloballyBlocked(
                [shared],
                globallyInstalled: ProjectState(stateFile: bed.env.globalStateFile).configuredPacks,
                previouslyConfigured: [],
                output: CLIOutput(colorsEnabled: false)
            )
        }
    }
}

// MARK: - Scenario: Hook Interpreters

struct HookInterpreterLifecycleTests {
    /// The invocation a real pack needs for a TypeScript hook on Node.
    private static let tsInterpreter = "node --experimental-strip-types --disable-warning=ExperimentalWarning"

    @Test("Declared, inferred and default hook interpreters all compose, verify and clean up")
    func hookInterpreterLifecycle() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let tsSource = try bed.makeHookSource(name: "gate.ts", content: "console.log('gate')")
        let jsSource = try bed.makeHookSource(name: "fmt.js", content: "console.log('fmt')")
        let shSource = try bed.makeHookSource(name: "legacy.sh")

        let pack = MockTechPack(
            identifier: "ts-pack",
            displayName: "TS Pack",
            components: [
                bed.hookComponent(
                    pack: "ts-pack", id: "gate", source: tsSource, destination: "gate.ts",
                    hookRegistration: HookRegistration(event: .preToolUse, interpreter: Self.tsInterpreter)
                ),
                bed.hookComponent(
                    pack: "ts-pack", id: "fmt", source: jsSource, destination: "fmt.js",
                    hookRegistration: HookRegistration(event: .postToolUse)
                ),
                bed.hookComponent(
                    pack: "ts-pack", id: "legacy", source: shSource, destination: "legacy.sh",
                    hookRegistration: HookRegistration(event: .sessionStart)
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])

        // 1. Sync
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Hooks are always namespaced under the pack id (collision resolver phase 0).
        let expected = [
            bed.projectHookCommand("ts-pack/gate.ts", interpreter: Self.tsInterpreter),
            bed.projectHookCommand("ts-pack/fmt.js", interpreter: "node"),
            bed.projectHookCommand("ts-pack/legacy.sh"),
        ]

        // 2. Each command lands in settings.local.json under its own event
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let registered = (settings.hooks ?? [:]).values.flatMap { groups in
            groups.compactMap(\.hooks?.first?.command)
        }
        for command in expected {
            #expect(registered.contains(command), "settings should register '\(command)'")
        }
        #expect(settings.hooks?["PreToolUse"]?.first?.hooks?.first?.command == expected[0])

        // 3. And is recorded for convergence
        let artifacts = try #require(bed.projectState().artifacts(for: "ts-pack"))
        for command in expected {
            #expect(artifacts.hookCommands.contains(command), "state should record '\(command)'")
        }

        // 4. Doctor joins the recorded commands back to their components without complaint
        try bed.runDoctor(registry: registry)

        // 5. Deselecting the pack removes the files and every hook entry, interpreter regardless
        try configurator.configure(packs: [], confirmRemovals: false)

        if FileManager.default.fileExists(atPath: bed.settingsLocalPath.path) {
            let after = try Settings.load(from: bed.settingsLocalPath)
            let remaining = (after.hooks ?? [:]).values.flatMap { groups in
                groups.compactMap(\.hooks?.first?.command)
            }
            for command in expected {
                #expect(!remaining.contains(command), "'\(command)' should be gone")
            }
        }
        for destination in ["ts-pack/gate.ts", "ts-pack/fmt.js", "ts-pack/legacy.sh"] {
            let installed = bed.project.appendingPathComponent(".claude/hooks/\(destination)")
            #expect(!FileManager.default.fileExists(atPath: installed.path))
        }
    }
}
