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

    func makeConfigurator(
        registry: TechPackRegistry = TechPackRegistry(),
        warningCounter: WarningCounter? = nil
    ) -> Configurator {
        Configurator(
            environment: env,
            output: CLIOutput(colorsEnabled: false, warningCounter: warningCounter, interactiveStdin: false),
            shell: ShellRunner(environment: env),
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: project, environment: env),
            claudeCLI: mockCLI
        )
    }

    func makeDoctorRunner(registry: TechPackRegistry, packFilter: String? = nil, fixMode: Bool = false) -> DoctorRunner {
        DoctorRunner(
            fixMode: fixMode,
            skipConfirmation: true,
            packFilter: packFilter,
            registry: registry,
            environment: env,
            projectRootOverride: project,
            claudeCLI: mockCLI
        )
    }

    func makeGlobalSyncConfigurator(
        registry: TechPackRegistry = TechPackRegistry(),
        warningCounter: WarningCounter? = nil
    ) -> Configurator {
        Configurator(
            environment: env,
            output: CLIOutput(colorsEnabled: false, warningCounter: warningCounter, interactiveStdin: false),
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

    func runDoctor(registry: TechPackRegistry, packFilter: String? = nil) throws -> DoctorSummary {
        var runner = makeDoctorRunner(registry: registry, packFilter: packFilter)
        return try runner.run()
    }

    func runGlobalDoctor(registry: TechPackRegistry) throws -> DoctorSummary {
        var runner = makeGlobalDoctorRunner(registry: registry)
        return try runner.run()
    }

    // MARK: - Component Factories

    func hookComponent(
        pack: String, id: String, source: URL, destination: String,
        hookRegistration: HookRegistration? = nil
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Hook \(id)",
            type: .hookFile,
            packIdentifier: pack,
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

    func brewComponent(
        pack: String, id: String, package: String
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Brew \(id)",
            type: .brewPackage,
            packIdentifier: pack,
            installAction: .brewInstall(package: package)
        )
    }

    func settingsComponent(pack: String, id: String, source: URL) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Settings \(id)",
            type: .configuration,
            packIdentifier: pack,
            installAction: .settingsMerge(source: source)
        )
    }

    func mcpComponent(
        pack: String, id: String, name: String,
        command: String = "npx", args: [String] = [], env: [String: String] = [:]
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "MCP \(id)",
            type: .mcpServer,
            packIdentifier: pack,
            installAction: .mcpServer(MCPServerConfig(
                name: name, command: command, args: args, env: env
            ))
        )
    }

    // MARK: - Assertions

    func projectState() throws -> ProjectState {
        try ProjectState(projectRoot: project)
    }

    func globalState() throws -> ProjectState {
        try ProjectState(stateFile: env.globalStateFile)
    }

    var projectStateFile: URL {
        project
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
    }

    /// Writes the key the removed `--customize` flag used to persist; `ProjectState` has no setter for it.
    func seedLegacyExclusions(_ exclusions: [String: [String]], in stateFile: URL) throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any]
        )
        json["excludedComponents"] = exclusions
        try JSONSerialization.data(withJSONObject: json).write(to: stateFile)
    }

    func storedLegacyExclusions(in stateFile: URL) throws -> Any? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any]
        return json?["excludedComponents"]
    }

    func settingsEnv() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsLocalPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["env"] as? [String: Any] ?? [:]
    }

    var settingsLocalPath: URL {
        project.appendingPathComponent(".claude/settings.local.json")
    }

    /// Every hook command composed into the project's settings under `event`.
    func hookCommands(event: String) throws -> [String] {
        let settings = try Settings.load(from: settingsLocalPath)
        return (settings.hooks?[event] ?? []).flatMap { $0.hooks ?? [] }.compactMap(\.command)
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

        // MockClaudeCLI only records `mcp add`; write what the real CLI would store for local scope.
        let claudeJSON = ["projects": [bed.project.path: ["mcpServers": ["test-mcp": ["command": "npx"]]]]]
        try JSONSerialization.data(withJSONObject: claudeJSON).write(to: bed.env.claudeJSON)

        // === Step 2: Doctor passes ===
        let clean = try bed.runDoctor(registry: registry)
        #expect(clean.issues == 0)

        // === Step 3: Introduce settings drift ===
        var driftedSettings = settingsJSON
        var driftedEnv = envDict ?? [:]
        driftedEnv["LINT_ENABLED"] = "false"
        driftedSettings["env"] = driftedEnv
        let driftedData = try JSONSerialization.data(withJSONObject: driftedSettings, options: [.prettyPrinted, .sortedKeys])
        try driftedData.write(to: bed.settingsLocalPath)

        // === Step 4: Doctor detects drift ===
        let drifted = try bed.runDoctor(registry: registry)
        #expect(drifted.warnings > clean.warnings)
        #expect(drifted.isHealthy)

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
        #expect(try bed.runDoctor(registry: registry).issues == 0)

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
        #expect(try bed.runDoctor(registry: registry).issues == 0)

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
        #expect(try bed.runDoctor(registry: registryV2).issues == 0)
    }
}

// MARK: - Scenario 4: Exclusions Stored by the Removed --customize Flag

struct LegacyExclusionMigrationTests {
    @Test("A component stored as excluded is installed on the next sync and the stored exclusion is cleared")
    func legacyExclusionIsInstalledAndCleared() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try hookPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)

        let hookFile = try excludeInstalledHook(bed: bed)

        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)

        #expect(FileManager.default.fileExists(atPath: hookFile.path))
        #expect(try clearedButPresent(bed: bed))
        #expect(try bed.runDoctor(registry: registry).issues == 0)
    }

    @Test("Doctor fails a component stored as excluded until --fix re-syncs it and drops the exclusion")
    func doctorFixInstallsLegacyExclusion() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try hookPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
        let hookFile = try excludeInstalledHook(bed: bed)

        #expect(try bed.runDoctor(registry: registry).issues > 0)

        var runner = bed.makeDoctorRunner(registry: registry, fixMode: true)
        #expect(try runner.run().isHealthy)
        #expect(FileManager.default.fileExists(atPath: hookFile.path))
        #expect(try clearedButPresent(bed: bed))
        #expect(try bed.runDoctor(registry: registry).issues == 0)
    }

    private func hookPack(bed: LifecycleTestBed) throws -> MockTechPack {
        try MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [
                bed.hookComponent(
                    pack: "my-pack", id: "hookA",
                    source: bed.makeHookSource(name: "hookA.sh"),
                    destination: "hookA.sh"
                ),
            ]
        )
    }

    /// Recreates what an older mcs left behind: the component excluded and never installed.
    private func excludeInstalledHook(bed: LifecycleTestBed) throws -> URL {
        let hookFile = bed.project.appendingPathComponent(".claude/hooks/my-pack/hookA.sh")
        try FileManager.default.removeItem(at: hookFile)
        try bed.seedLegacyExclusions(["my-pack": ["my-pack.hookA"]], in: bed.projectStateFile)
        #expect(try bed.projectState().legacyExcludedComponents == ["my-pack": ["my-pack.hookA"]])
        return hookFile
    }

    /// Older releases require the key, so clearing must leave it in place, empty.
    private func clearedButPresent(bed: LifecycleTestBed) throws -> Bool {
        let stored = try bed.storedLegacyExclusions(in: bed.projectStateFile) as? [String: Any]
        return stored?.isEmpty == true
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
        #expect(try bed.runGlobalDoctor(registry: registry).issues == 0)
    }
}

// MARK: - Scenario 5c: Global install warns about projects that already hold the pack

struct GlobalDuplicationWarningTests {
    /// Seed `~/.mcs/projects.yaml` as a prior `mcs sync` in each project would have.
    private func seedIndex(env: Environment, entries: [(String, [String])]) throws {
        let indexFile = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        for entry in entries {
            indexFile.upsert(projectPath: entry.0, packIDs: entry.1, in: &data)
        }
        try indexFile.save(data)
    }

    /// Project entries only. The `__global__` entry legitimately changes during a global
    /// sync (step 11 upserts it), so it is excluded from the read-only assertion.
    private func projectEntries(env: Environment) throws -> [ProjectIndex.ProjectEntry] {
        try ProjectIndex(path: env.projectsIndexFile).load()
            .projects
            .filter { !$0.isGlobal }
            .sorted { $0.path < $1.path }
    }

    private func makeProjects(in home: URL, _ names: [String]) throws -> [URL] {
        try names.map { name in
            let url = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private func duplicatedPack(bed: LifecycleTestBed) throws -> MockTechPack {
        let hookSource = try bed.makeHookSource(name: "dup-hook.sh")
        return MockTechPack(
            identifier: "dup-pack",
            displayName: "Dup Pack",
            components: [
                bed.hookComponent(pack: "dup-pack", id: "hook", source: hookSource, destination: "dup-hook.sh"),
            ]
        )
    }

    @Test("Warns when tracked projects already configure a pack entering the global scope")
    func warnsAndLeavesProjectEntriesUntouched() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let projects = try makeProjects(in: bed.home, ["project-a", "project-b"])
        try seedIndex(env: bed.env, entries: projects.map { ($0.path, ["dup-pack"]) })
        let before = try projectEntries(env: bed.env)

        let pack = try duplicatedPack(bed: bed)
        let counter = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: TechPackRegistry(packs: [pack]), warningCounter: counter)
            .configure(packs: [pack], confirmRemovals: false)

        // One `warn` header covers every pack and project it names, so the count is
        // stable no matter how many duplicates there are.
        #expect(counter.count == 1)

        // Advisory only: the warning must not touch the projects it names, nor prune
        // their index entries. Only the global scope changes.
        let after = try projectEntries(env: bed.env)
        #expect(after == before)
        #expect(try ProjectState(stateFile: bed.env.globalStateFile).configuredPacks.contains("dup-pack"))
    }

    @Test("Silent when no tracked project holds the pack being installed globally")
    func silentWithoutOverlap() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let projects = try makeProjects(in: bed.home, ["project-a"])
        try seedIndex(env: bed.env, entries: projects.map { ($0.path, ["other-pack"]) })

        let pack = try duplicatedPack(bed: bed)
        let counter = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: TechPackRegistry(packs: [pack]), warningCounter: counter)
            .configure(packs: [pack], confirmRemovals: false)

        #expect(counter.count == 0)
    }

    @Test("Re-syncing a pack the global scope already has does not warn again")
    func silentOnSecondGlobalSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let projects = try makeProjects(in: bed.home, ["project-a"])
        try seedIndex(env: bed.env, entries: projects.map { ($0.path, ["dup-pack"]) })

        let pack = try duplicatedPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        let first = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: registry, warningCounter: first)
            .configure(packs: [pack], confirmRemovals: false)
        #expect(first.count == 1)

        // The trigger is a transition, not an identity: the pack is no longer an addition,
        // so the second sync is quiet. This is also what keeps `mcs update` silent.
        let second = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: registry, warningCounter: second)
            .configure(packs: [pack], confirmRemovals: false)
        #expect(second.count == 0)
    }

    @Test("--dry-run surfaces the same warning and installs nothing")
    func warnsOnDryRunWithoutInstalling() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let projects = try makeProjects(in: bed.home, ["project-a"])
        try seedIndex(env: bed.env, entries: projects.map { ($0.path, ["dup-pack"]) })

        let pack = try duplicatedPack(bed: bed)
        let counter = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: TechPackRegistry(packs: [pack]), warningCounter: counter)
            .dryRun(packs: [pack])

        // `dryRun` keeps no diff of its own, so this covers the second call site's
        // locally-derived additions set.
        #expect(counter.count == 1)
        #expect(try ProjectState(stateFile: bed.env.globalStateFile).configuredPacks.isEmpty)
    }

    @Test("An unreadable project index degrades to a notice — the sync still completes")
    func unreadableIndexDoesNotFailSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        try "{{ not yaml".write(to: bed.env.projectsIndexFile, atomically: true, encoding: .utf8)

        let pack = try duplicatedPack(bed: bed)
        let counter = WarningCounter()
        try bed.makeGlobalSyncConfigurator(registry: TechPackRegistry(packs: [pack]), warningCounter: counter)
            .configure(packs: [pack], confirmRemovals: false)

        // One warning for the unreadable index. The later index *write* also fails, but
        // reports through `output.error`, which does not touch the counter.
        #expect(counter.count == 1)
        #expect(try ProjectState(stateFile: bed.env.globalStateFile).configuredPacks.contains("dup-pack"))
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
        #expect(try bed.runDoctor(registry: registryV2).issues == 0)
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
        #expect(try bed.runDoctor(registry: registry).issues == 0)
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
        config.updateCheck = true
        try config.save(to: bed.env.mcsConfigFile)

        // Sync with a minimal pack
        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack", components: [])
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

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
        config.updateCheck = false
        try config.save(to: bed.env.mcsConfigFile)

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack", components: [])
        let registry = TechPackRegistry(packs: [pack])
        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

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
        config.updateCheck = true
        try config.save(to: bed.env.mcsConfigFile)

        UpdateChecker.syncHook(config: config, env: bed.env, output: output)

        let settings1 = try Settings.load(from: bed.env.claudeSettings)
        let commands1 = (settings1.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
            .flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(commands1.contains(UpdateChecker.hookCommand))

        // Disable → hook removed from global settings.json
        config.updateCheck = false

        UpdateChecker.syncHook(config: config, env: bed.env, output: output)

        let settings2 = try Settings.load(from: bed.env.claudeSettings)
        let commands2 = (settings2.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
            .flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(!commands2.contains(UpdateChecker.hookCommand))
    }
}

extension LifecycleTestBed {
    /// A real adapter, so prompts go through `PromptExecutor` rather than a mock's simulation.
    func adapterPack(
        identifier: String = "adapter-pack",
        displayName: String = "Adapter Pack",
        prompts: [PromptDefinition]
    ) -> ExternalPackAdapter {
        ExternalPackAdapter(
            manifest: ExternalPackManifest(
                schemaVersion: 1,
                identifier: identifier,
                displayName: displayName,
                description: "Pack with real prompt execution",
                author: nil,
                minMCSVersion: nil,
                components: [],
                templates: nil,
                prompts: prompts,
                configureProject: nil,
                supplementaryDoctorChecks: nil,
                ignore: nil
            ),
            packPath: home,
            shell: ShellRunner(environment: env),
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false)
        )
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

    private func fileDetectPrompt(
        _ key: String, patterns: [String], defaultValue: String? = nil
    ) -> PromptDefinition {
        PromptDefinition(
            key: key, type: .fileDetect,
            label: nil, defaultValue: defaultValue, options: nil,
            detectPatterns: patterns, scriptCommand: nil
        )
    }

    private func touch(_ name: String, in directory: URL) throws {
        try "".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
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

    /// A pack with no prompts whose command references `__MEMORIES_BRANCH__`.
    private func placeholderPack(bed: LifecycleTestBed) throws -> MockTechPack {
        let cmdSource = try bed.makeCommandSource(name: "sync.md", content: "branch: __MEMORIES_BRANCH__")
        return MockTechPack(
            identifier: "placeholder-pack",
            displayName: "Placeholder Pack",
            components: [
                bed.commandComponent(
                    pack: "placeholder-pack", id: "sync",
                    source: cmdSource, destination: "sync.md"
                ),
            ],
            templates: []
        )
    }

    @Test("Placeholder no prompt declares reuses its stored value")
    func undeclaredPlaceholderReusesPrior() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try placeholderPack(bed: bed)
        var state = try bed.projectState()
        state.setResolvedValues(["MEMORIES_BRANCH": "main"])
        try state.save()

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)

        let installed = bed.project.appendingPathComponent(".claude/commands/sync.md")
        #expect(try String(contentsOf: installed, encoding: .utf8) == "branch: main")
        #expect(try bed.projectState().resolvedValues?["MEMORIES_BRANCH"] == "main")
    }

    @Test("Removing another pack keeps a value a surviving pack references as a placeholder")
    func pruneKeepsReferencedPlaceholderValue() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let placeholderPack = try placeholderPack(bed: bed)
        let promptPack = MockPromptTechPack(
            identifier: "prompt-pack",
            displayName: "Prompt Pack",
            prompts: [inputPrompt("LABEL_PREFIX")]
        )
        let registry = TechPackRegistry(packs: [placeholderPack, promptPack])
        var state = try bed.projectState()
        state.setResolvedValues(["MEMORIES_BRANCH": "main"])
        try state.save()

        let configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [placeholderPack, promptPack], confirmRemovals: false)
        try configurator.configure(packs: [placeholderPack], confirmRemovals: false)

        let values = try bed.projectState().resolvedValues
        #expect(values?["MEMORIES_BRANCH"] == "main")
        #expect(values?["LABEL_PREFIX"] == nil)
    }

    @Test("Removing a pack skips pruning when a surviving pack's templates can't be read")
    func pruneSkippedWhenTemplatesUnreadable() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let unreadable = TemplateFailingPack(identifier: "unreadable-pack")
        let promptPack = MockPromptTechPack(
            identifier: "prompt-pack",
            displayName: "Prompt Pack",
            prompts: [inputPrompt("LABEL_PREFIX")]
        )
        let configurator = bed.makeConfigurator(registry: TechPackRegistry(packs: [unreadable, promptPack]))
        try configurator.configure(packs: [unreadable, promptPack], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["LABEL_PREFIX": "scope:", "TEMPLATE_ONLY_KEY": "kept"])
        configurator.unconfigurePack("prompt-pack", state: &state)

        #expect(state.resolvedValues?["TEMPLATE_ONLY_KEY"] == "kept")
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

    @Test("fileDetect prior still on disk is reused instead of re-detected")
    func fileDetectReuseOnSecondSync() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        try touch("App.xcodeproj", in: bed.project)
        try touch("App.xcworkspace", in: bed.project)

        // Off-TTY, two matches with no prior resolve only through a default that is one of them.
        let pack = MockPromptTechPack(
            identifier: "detect-pack",
            displayName: "Detect Pack",
            prompts: [fileDetectPrompt(
                "PROJECT", patterns: ["*.xcodeproj", "*.xcworkspace"], defaultValue: "App.xcodeproj"
            )],
            defaultAnswer: { _ in "re-asked" }
        )
        let configurator = bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))

        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(try bed.projectState().resolvedValues?["PROJECT"] == "App.xcodeproj")

        var state = try bed.projectState()
        state.setResolvedValues(["PROJECT": "App.xcworkspace"])
        try state.save()

        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(try bed.projectState().resolvedValues?["PROJECT"] == "App.xcworkspace")
    }

    @Test("fileDetect prior is re-asked once the stored file is gone")
    func fileDetectStalePriorReAsks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        try touch("App.xcodeproj", in: bed.project)

        let pack = MockPromptTechPack(
            identifier: "detect-pack",
            displayName: "Detect Pack",
            prompts: [fileDetectPrompt("PROJECT", patterns: ["*.xcodeproj", "*.xcworkspace"])],
            defaultAnswer: { _ in "re-asked" }
        )
        let configurator = bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
        try configurator.configure(packs: [pack], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["PROJECT": "Removed.xcworkspace"])
        try state.save()

        // The re-scan finds only App.xcodeproj, so the stale prior is replaced by that match.
        try configurator.configure(packs: [pack], confirmRemovals: false)
        #expect(try bed.projectState().resolvedValues?["PROJECT"] == "App.xcodeproj")
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

    // MARK: Non-interactive resolution

    @Test("Non-TTY sync fails naming pack and key for an unseeded input with no default")
    func nonInteractiveUnresolvedInputFails() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let prompted = bed.adapterPack(prompts: [inputPrompt("API_KEY")])
        let cmdSource = try bed.makeCommandSource(name: "doc.md")
        let bystander = MockTechPack(
            identifier: "bystander",
            displayName: "Bystander",
            components: [bed.commandComponent(pack: "bystander", id: "doc", source: cmdSource, destination: "doc.md")],
            templates: []
        )
        let packs: [any TechPack] = [prompted, bystander]

        #expect(throws: PromptResolutionError(unresolved: [
            UnresolvedPrompt(packNames: ["Adapter Pack"], key: "API_KEY"),
        ], isGlobalScope: false)) {
            try bed.makeConfigurator(registry: TechPackRegistry(packs: packs))
                .configure(packs: packs, confirmRemovals: false)
        }

        let stateFile = bed.project.appendingPathComponent(".claude/\(Constants.FileNames.mcsProject)")
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))
        #expect(!FileManager.default.fileExists(
            atPath: bed.project.appendingPathComponent(".claude/commands/doc.md").path
        ))
    }

    @Test("Non-TTY sync stores the declared default when nothing is seeded")
    func nonInteractiveUsesDefault() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let level = PromptDefinition(
            key: "LOG_LEVEL", type: .select, label: nil, defaultValue: "debug",
            options: ["info", "debug"].map { PromptOption(value: $0, label: $0) },
            detectPatterns: nil, scriptCommand: nil
        )
        let pack = bed.adapterPack(prompts: [inputPrompt("BRANCH_PREFIX", defaultValue: "feature"), level])

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
            .configure(packs: [pack], confirmRemovals: false)

        let values = try bed.projectState().resolvedValues
        #expect(values?["BRANCH_PREFIX"] == "feature")
        #expect(values?["LOG_LEVEL"] == "debug")
    }

    @Test("Non-TTY sync fails for an undeclared placeholder with no stored value")
    func nonInteractiveUnresolvedPlaceholderFails() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try placeholderPack(bed: bed)

        #expect(throws: PromptResolutionError(unresolved: [
            UnresolvedPrompt(packNames: ["Placeholder Pack"], key: "MEMORIES_BRANCH"),
        ], isGlobalScope: false)) {
            try bed.makeConfigurator(registry: TechPackRegistry(packs: [pack]))
                .configure(packs: [pack], confirmRemovals: false)
        }
    }

    @Test("Non-TTY sync swapping packs that share a key does not inherit the removed pack's value")
    func nonInteractiveSwapAsksFresh() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = bed.adapterPack(
            identifier: "pack-a", displayName: "Pack A",
            prompts: [inputPrompt("BRANCH_PREFIX", defaultValue: "a-default")]
        )
        let packB = bed.adapterPack(
            identifier: "pack-b", displayName: "Pack B",
            prompts: [inputPrompt("BRANCH_PREFIX", defaultValue: "b-default")]
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        try bed.makeConfigurator(registry: registry).configure(packs: [packA], confirmRemovals: false)

        var state = try bed.projectState()
        state.setResolvedValues(["BRANCH_PREFIX": "chosen-for-a"])
        try state.save()

        try bed.makeConfigurator(registry: registry).configure(packs: [packB], confirmRemovals: false)

        #expect(try bed.projectState().resolvedValues?["BRANCH_PREFIX"] == "b-default")
    }

    @Test("A key an earlier pack computes by script is not asked again by a later pack")
    func scriptFirstKeyIsNotReAsked() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let script = PromptDefinition(
            key: "VERSION", type: .script, label: nil, defaultValue: nil,
            options: nil, detectPatterns: nil, scriptCommand: "echo 1.2.3"
        )
        let computing = bed.adapterPack(identifier: "pack-a", displayName: "Pack A", prompts: [script])
        let asking = bed.adapterPack(identifier: "pack-b", displayName: "Pack B", prompts: [inputPrompt("VERSION")])
        let packs: [any TechPack] = [computing, asking]

        try bed.makeConfigurator(registry: TechPackRegistry(packs: packs)).configure(packs: packs, confirmRemovals: false)

        #expect(try bed.projectState().resolvedValues?["VERSION"] == "1.2.3")
    }

    /// Two packs detect `PROJECT` with different patterns, and only the second's file exists.
    private func splitDetectPacks(bed: LifecycleTestBed) throws -> [any TechPack] {
        try touch("App.xcworkspace", in: bed.project)
        return [
            bed.adapterPack(
                identifier: "pack-a", displayName: "Pack A",
                prompts: [fileDetectPrompt("PROJECT", patterns: ["*.xcodeproj"])]
            ),
            bed.adapterPack(
                identifier: "pack-b", displayName: "Pack B",
                prompts: [fileDetectPrompt("PROJECT", patterns: ["*.xcworkspace"])]
            ),
        ]
    }

    private func storePrior(_ values: [String: String], bed: LifecycleTestBed) throws {
        var state = try bed.projectState()
        state.setResolvedValues(values)
        try state.save()
    }

    @Test("Non-TTY sync keeps a fileDetect prior that any declaring pack's scan still finds")
    func nonInteractiveSplitFileDetectKeepsPrior() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let packs = try splitDetectPacks(bed: bed)
        try storePrior(["PROJECT": "App.xcworkspace"], bed: bed)

        try bed.makeConfigurator(registry: TechPackRegistry(packs: packs)).configure(packs: packs, confirmRemovals: false)

        #expect(try bed.projectState().resolvedValues?["PROJECT"] == "App.xcworkspace")
    }

    @Test("Non-TTY sync reuses a prior verbatim when any pack declares the key as input")
    func nonInteractiveMixedTypesKeepPrior() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let packs: [any TechPack] = [
            bed.adapterPack(
                identifier: "pack-a", displayName: "Pack A",
                prompts: [fileDetectPrompt("PROJECT", patterns: ["*.xcodeproj"])]
            ),
            bed.adapterPack(identifier: "pack-b", displayName: "Pack B", prompts: [inputPrompt("PROJECT")]),
        ]
        try storePrior(["PROJECT": "Legacy.xcodeproj"], bed: bed)

        try bed.makeConfigurator(registry: TechPackRegistry(packs: packs)).configure(packs: packs, confirmRemovals: false)

        #expect(try bed.projectState().resolvedValues?["PROJECT"] == "Legacy.xcodeproj")
    }

    @Test(
        "Non-TTY sync fails before removing anything when a selected pack can't be answered",
        arguments: [false, true]
    )
    func nonInteractiveFailureLeavesStateUntouched(confirmRemovals: Bool) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let cmdSource = try bed.makeCommandSource(name: "keep.md")
        let kept = MockTechPack(
            identifier: "kept",
            displayName: "Kept",
            components: [bed.commandComponent(pack: "kept", id: "keep", source: cmdSource, destination: "keep.md")]
        )
        let unanswerable = bed.adapterPack(prompts: [inputPrompt("API_KEY")])
        let registry = TechPackRegistry(packs: [kept, unanswerable])
        try bed.makeConfigurator(registry: registry).configure(packs: [kept], confirmRemovals: false)
        try storePrior(["UNRELATED": "value"], bed: bed)
        let before = try bed.projectState()

        #expect(throws: PromptResolutionError.self) {
            try bed.makeConfigurator(registry: registry)
                .configure(packs: [unanswerable], confirmRemovals: confirmRemovals)
        }

        let after = try bed.projectState()
        #expect(after.configuredPacks == before.configuredPacks)
        #expect(after.resolvedValues == before.resolvedValues)
        #expect(FileManager.default.fileExists(
            atPath: bed.project.appendingPathComponent(".claude/commands/keep.md").path
        ))
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
        let toSync = try ConfiguratorSupport.filterGloballyBlocked(
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
        let toSync = try ConfiguratorSupport.filterGloballyBlocked(
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
            try ConfiguratorSupport.filterGloballyBlocked(
                [shared],
                globallyInstalled: ProjectState(stateFile: bed.env.globalStateFile).configuredPacks,
                previouslyConfigured: [],
                output: CLIOutput(colorsEnabled: false)
            )
        }
    }
}

// MARK: - Update Re-apply

/// End-to-end coverage for the `mcs update` re-apply phase.
///
/// Drives the real `UpdateScopeResolver` and `ScopeReapplier.reapplyScope` rather than
/// `UpdateCommand.perform()`, which builds its own `Environment()` and cannot be pointed
/// at a sandboxed home.
struct UpdateReapplyLifecycleTests {
    @Test(
        "Both-scope pack survives update re-apply",
        arguments: [
            UpdateScopeResolver.Filter.projectOnly, // mcs update --project
            .all, // bare mcs update: global run, then project run
        ]
    )
    func bothScopePackSurvivesUpdate(filter: UpdateScopeResolver.Filter) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let hookSource = try bed.makeHookSource(name: "check.sh")
        let shared = MockTechPack(
            identifier: "shared-pack",
            displayName: "Shared Pack",
            components: [bed.hookComponent(pack: "shared-pack", id: "check", source: hookSource, destination: "check.sh")]
        )
        let registry = TechPackRegistry(packs: [shared])

        // Installed in both scopes — the case the global-pack block must never reach.
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)
        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [shared], confirmRemovals: false)
        #expect(try bed.globalState().configuredPacks.contains("shared-pack"))

        // Delete the project copy of the hook so a surviving pack is distinguishable from a
        // re-apply that never ran: `copyPackFile` is convergent, so `configure` restores it.
        let projectHook = bed.project.appendingPathComponent(".claude/hooks/shared-pack/check.sh")
        #expect(FileManager.default.fileExists(atPath: projectHook.path))
        try FileManager.default.removeItem(at: projectHook)

        let runs = try UpdateScopeResolver(environment: bed.env, output: CLIOutput(colorsEnabled: false))
            .resolve(filter: filter, projectRoot: bed.project)
        // An empty run list would pass every assertion below without touching anything.
        #expect(runs.count == (filter == .all ? 2 : 1))

        for run in runs {
            let blocked = try ScopeReapplier.reapplyScope(
                run,
                skippedPackIDs: [],
                registry: registry,
                dryRun: false,
                env: bed.env,
                shell: ShellRunner(environment: bed.env),
                output: CLIOutput(colorsEnabled: false),
                claudeCLI: bed.mockCLI
            )
            // A blocked scope would satisfy the assertions below without doing anything.
            #expect(!blocked)
        }

        // The regression guard: an identity-based filter, or a list sourced from anywhere but
        // the scope's own state, would have handed `configure` a set missing `shared-pack`
        // and unconfigured it from the project without a prompt.
        #expect(try bed.projectState().configuredPacks.contains("shared-pack"))
        #expect(try bed.globalState().configuredPacks.contains("shared-pack"))
        #expect(FileManager.default.fileExists(atPath: projectHook.path))
    }

    @Test("A scope with unresolvable prompts is reported while later scopes still re-apply")
    func unresolvedScopeDoesNotStrandOthers() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let branchSource = try bed.makeCommandSource(name: "branch.md", content: "branch: __MEMORIES_BRANCH__")
        let globalPack = MockTechPack(
            identifier: "global-pack",
            displayName: "Global Pack",
            components: [bed.commandComponent(
                pack: "global-pack", id: "branch", source: branchSource, destination: "branch.md"
            )]
        )
        let hookSource = try bed.makeHookSource(name: "check.sh")
        let projectPack = MockTechPack(
            identifier: "project-pack",
            displayName: "Project Pack",
            components: [bed.hookComponent(pack: "project-pack", id: "check", source: hookSource, destination: "check.sh")]
        )
        let registry = TechPackRegistry(packs: [globalPack, projectPack])

        var globalState = try bed.globalState()
        globalState.setResolvedValues(["MEMORIES_BRANCH": "main"])
        try globalState.save()
        try bed.makeGlobalSyncConfigurator(registry: registry).configure(packs: [globalPack], confirmRemovals: false)
        try bed.makeConfigurator(registry: registry).configure(packs: [projectPack], confirmRemovals: false)

        // The global run can no longer answer its placeholder; the project run must still happen.
        globalState = try bed.globalState()
        globalState.setResolvedValues([:])
        try globalState.save()
        let projectHook = bed.project.appendingPathComponent(".claude/hooks/project-pack/check.sh")
        try FileManager.default.removeItem(at: projectHook)

        let runs = try UpdateScopeResolver(environment: bed.env, output: CLIOutput(colorsEnabled: false))
            .resolve(filter: .all, projectRoot: bed.project)
        #expect(runs.count == 2)

        let unresolved = try ScopeReapplier.reapplyScopes(
            runs,
            skippedPackIDs: [],
            registry: registry,
            dryRun: false,
            env: bed.env,
            shell: ShellRunner(environment: bed.env),
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false),
            claudeCLI: bed.mockCLI
        )

        #expect(unresolved == [runs[0].label])
        #expect(FileManager.default.fileExists(atPath: projectHook.path))
    }

    @Test("A skipped pack makes the whole scope skip re-apply instead of unconfiguring it")
    func skippedPackIsNotUnconfigured() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let sourceA = try bed.makeHookSource(name: "a.sh")
        let sourceB = try bed.makeHookSource(name: "b.sh")
        // Registered hooks, so the settings-recomposition assertion below is not vacuous:
        // without a `hookRegistration` no settings entry is ever written to compare against.
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [bed.hookComponent(
                pack: "pack-a", id: "a", source: sourceA, destination: "a.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [bed.hookComponent(
                pack: "pack-b", id: "b", source: sourceB, destination: "b.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )
        let registry = TechPackRegistry(packs: [packA, packB])

        // Two packs in one scope: with a single pack the "no packs to refresh" guard masks the bug.
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [packA, packB], confirmRemovals: false)

        let hookA = bed.project.appendingPathComponent(".claude/hooks/pack-a/a.sh")
        let hookB = bed.project.appendingPathComponent(".claude/hooks/pack-b/b.sh")
        #expect(FileManager.default.fileExists(atPath: hookA.path))
        #expect(FileManager.default.fileExists(atPath: hookB.path))

        // Deleting A's hook distinguishes "scope was skipped" from "scope converged": a re-apply
        // that ran would restore it, since `copyPackFile` is convergent.
        try FileManager.default.removeItem(at: hookA)

        let runs = try UpdateScopeResolver(environment: bed.env, output: CLIOutput(colorsEnabled: false))
            .resolve(filter: .projectOnly, projectRoot: bed.project)
        #expect(runs.count == 1)

        for run in runs {
            let blocked = try ScopeReapplier.reapplyScope(
                run,
                skippedPackIDs: ["pack-b"],
                registry: registry,
                dryRun: false,
                env: bed.env,
                shell: ShellRunner(environment: bed.env),
                output: CLIOutput(colorsEnabled: false),
                claudeCLI: bed.mockCLI
            )
            #expect(blocked)
        }

        // Subtracting B from the desired state used to unconfigure it with no prompt, so a
        // declined trust prompt or a network failure uninstalled the pack (#382).
        #expect(try bed.projectState().configuredPacks.contains("pack-b"))
        #expect(FileManager.default.fileExists(atPath: hookB.path))

        // `configure` recomposes hooks from the pack list it is handed, so excluding B would
        // strip the entry that invokes the hook it kept.
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let hookCommands = (settings.hooks ?? [:]).values
            .flatMap(\.self).flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("pack-b/b.sh")))

        // The accepted cost of skipping the scope: A is not refreshed this run.
        #expect(!FileManager.default.fileExists(atPath: hookA.path))
    }

    @Test("A configured pack missing from the registry blocks the scope instead of being removed")
    func unresolvedPackIsNotUnconfigured() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let sourceA = try bed.makeHookSource(name: "a.sh")
        let sourceB = try bed.makeHookSource(name: "b.sh")
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [bed.hookComponent(
                pack: "pack-a", id: "a", source: sourceA, destination: "a.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [bed.hookComponent(
                pack: "pack-b", id: "b", source: sourceB, destination: "b.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )

        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA, packB]))
            .configure(packs: [packA, packB], confirmRemovals: false)

        let hookB = bed.project.appendingPathComponent(".claude/hooks/pack-b/b.sh")
        #expect(FileManager.default.fileExists(atPath: hookB.path))

        // B is in state with no registry entry, so it reaches neither `skippedPackIDs` (the
        // update phase only iterates registry entries) nor `unloadableConfiguredPacks`.
        let registryWithoutB = TechPackRegistry(packs: [packA], registeredPackIDs: ["pack-a"])

        let runs = try UpdateScopeResolver(environment: bed.env, output: CLIOutput(colorsEnabled: false))
            .resolve(filter: .projectOnly, projectRoot: bed.project)
        #expect(runs.count == 1)

        for run in runs {
            let blocked = try ScopeReapplier.reapplyScope(
                run,
                skippedPackIDs: [],
                registry: registryWithoutB,
                dryRun: false,
                env: bed.env,
                shell: ShellRunner(environment: bed.env),
                output: CLIOutput(colorsEnabled: false),
                claudeCLI: bed.mockCLI
            )
            #expect(blocked)
        }

        #expect(try bed.projectState().configuredPacks.contains("pack-b"))
        #expect(FileManager.default.fileExists(atPath: hookB.path))

        let settings = try Settings.load(from: bed.settingsLocalPath)
        let hookCommands = (settings.hooks ?? [:]).values
            .flatMap(\.self).flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(hookCommands.contains(bed.projectHookCommand("pack-b/b.sh")))
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
        #expect(try bed.runDoctor(registry: registry).issues == 0)

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

/// Configure `pack` in the project first, then globally — `filterGloballyBlocked` rejects the
/// reverse order, so this is the only sequence that produces a both-scope pack.
private func configureBothScopes(
    bed: LifecycleTestBed,
    pack: any TechPack,
    registry: TechPackRegistry
) throws {
    try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
    try bed.makeGlobalSyncConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
}

// MARK: - Scope Duplication (Issue #371)

/// A pack configured in both the global scope and a project installs its artifacts twice.
/// `mcs sync` blocks the *transition* that creates a duplicate but deliberately leaves an existing
/// one in place, so these tests cover the only thing that finds it afterwards.
///
/// The check reads two real `ProjectState` files with populated artifact records and file hashes,
/// so every fixture is built with the real configurators rather than hand-planted JSON.
@Suite("Scope duplication check")
struct ScopeDuplicationCheckTests {
    private func checks(
        bed: LifecycleTestBed,
        registry: TechPackRegistry,
        packFilter: String? = nil
    ) -> [any DoctorCheck] {
        ScopeDuplicationCheck.checks(
            projectRoot: bed.project,
            registry: registry,
            environment: bed.env,
            packFilter: packFilter.map { Set($0.components(separatedBy: ",")) }
        )
    }

    /// A pack with one skill, one hook and one template — the three surfaces that duplicate.
    private func duplicatingPack(bed: LifecycleTestBed) throws -> any TechPack {
        try MockTechPack(
            identifier: "dup-pack",
            displayName: "Dup Pack",
            components: [
                bed.skillComponent(
                    pack: "dup-pack", id: "skillA",
                    source: bed.makeSkillSource(name: "dup-skill.md"),
                    destination: "dup-skill.md"
                ),
                bed.hookComponent(
                    pack: "dup-pack", id: "hookA",
                    source: bed.makeHookSource(name: "dup-hook.sh"),
                    destination: "dup-hook.sh",
                    hookRegistration: HookRegistration(event: .preToolUse)
                ),
            ],
            templates: [
                TemplateContribution(
                    sectionIdentifier: "dup-pack",
                    templateContent: "Dup pack guidance.",
                    placeholders: []
                ),
            ]
        )
    }

    // MARK: Detection

    @Test("Names every duplicated surface when a pack is configured in both scopes")
    func reportsDuplicatedSurfaces() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let emitted = checks(bed: bed, registry: registry)
        let check = try #require(emitted.first)
        #expect(emitted.count == 1)
        let result = check.check()
        guard case let .fail(message) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(message.contains("also installed globally"))
        #expect(message.contains("1 skill"))
        #expect(message.contains("1 hook"))
        #expect(message.contains("1 CLAUDE.md section"))
        #expect(check.name == "Scope duplication: dup-pack")
        #expect(check.section == "Project")
    }

    @Test("Passes when the pack is in both scopes but nothing actually duplicates")
    func passesWhenNoArtifactsOverlap() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // An MCP server registers `local` in the project and `user` globally — the local one
        // shadows rather than duplicating — and the pack ships no templates or files.
        let pack = MockTechPack(
            identifier: "mcp-only",
            displayName: "MCP Only",
            components: [bed.mcpComponent(pack: "mcp-only", id: "srv", name: "srv")]
        )
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let emitted = checks(bed: bed, registry: registry)
        let check = try #require(emitted.first)
        #expect(emitted.count == 1)
        let result = check.check()
        guard case let .pass(message) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(message.contains("no artifacts overlap"))
    }

    // MARK: Factory scoping

    @Test("Emits nothing when no global scope has ever been synced")
    func emitsNothingWithoutGlobalState() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [pack], confirmRemovals: false)

        // The regression guard: falling back to the pack registry here — as DoctorRunner does
        // for check scoping — would report every project pack as a duplicate.
        #expect(checks(bed: bed, registry: registry).isEmpty)
    }

    @Test("Emits nothing for a pack configured in only one scope")
    func emitsNothingForSingleScopePack() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [pack], confirmRemovals: false)

        #expect(checks(bed: bed, registry: registry).isEmpty)
    }

    @Test("Honours the --pack filter")
    func respectsPackFilter() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        #expect(checks(bed: bed, registry: registry, packFilter: "other-pack").isEmpty)
        #expect(checks(bed: bed, registry: registry, packFilter: "dup-pack").count == 1)
    }

    // MARK: Fixability gates

    @Test("Refuses to fix while the global scope still holds components an older release excluded")
    func blocksFixOnIncompleteGlobalScope() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)
        try bed.seedLegacyExclusions(["dup-pack": ["dup-pack.hookA"]], in: bed.env.globalStateFile)

        let check = try #require(checks(bed: bed, registry: registry).first)
        #expect(check.fixCommandPreview == nil)
        let result = check.fix()
        guard case let .notFixable(reason) = result else {
            Issue.record("Expected .notFixable, got \(result)")
            return
        }
        #expect(reason.contains("mcs sync --global"))
        #expect(try bed.projectState().configuredPacks.contains("dup-pack"))
    }

    @Test("Refuses to fix when the two scopes answered a prompt differently")
    func blocksFixOnDivergentPromptAnswers() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try MockPromptTechPack(
            identifier: "prompt-pack",
            displayName: "Prompt Pack",
            prompts: [PromptDefinition(
                key: "__TOKEN__", type: .input,
                label: nil, defaultValue: "shared", options: nil,
                detectPatterns: nil, scriptCommand: nil
            )],
            components: [
                bed.skillComponent(
                    pack: "prompt-pack", id: "skillA",
                    source: bed.makeSkillSource(name: "prompt-skill.md"),
                    destination: "prompt-skill.md"
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        // Simulate the global scope having been answered differently.
        var globalState = try ProjectState(stateFile: bed.env.globalStateFile)
        globalState.setResolvedValues(["__TOKEN__": "a-different-answer"])
        try globalState.save()

        let check = try #require(checks(bed: bed, registry: registry).first)
        let result = check.fix()
        guard case let .notFixable(reason) = result else {
            Issue.record("Expected .notFixable, got \(result)")
            return
        }
        #expect(reason.contains("__TOKEN__"))
    }

    /// The guard for issue #365: `unconfigurePack` deletes tracked files without consulting the
    /// recorded hash, so an edited file would be silently destroyed. Drift must block the fix.
    @Test("Refuses to fix when an installed file was edited, and leaves it untouched")
    func blocksFixOnEditedFile() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let installedSkill = bed.project.appendingPathComponent(".claude/skills/dup-skill.md")
        try "# Skill\nMy own edits.".write(to: installedSkill, atomically: true, encoding: .utf8)

        let check = try #require(checks(bed: bed, registry: registry).first)
        #expect(check.fixCommandPreview == nil)
        let result = check.fix()
        guard case let .notFixable(reason) = result else {
            Issue.record("Expected .notFixable, got \(result)")
            return
        }
        #expect(reason.contains("dup-skill.md"))
        #expect(reason.contains("changed since install"))

        let survived = try String(contentsOf: installedSkill, encoding: .utf8)
        #expect(survived.contains("My own edits."))
        #expect(try bed.projectState().configuredPacks.contains("dup-pack"))
    }

    // MARK: Fix

    @Test("Fix removes the project copy, keeps the global one, and prunes the project index")
    func fixRemovesProjectCopyOnly() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let projectSkill = bed.project.appendingPathComponent(".claude/skills/dup-skill.md")
        let globalSkill = bed.home.appendingPathComponent(".claude/skills/dup-skill.md")
        #expect(FileManager.default.fileExists(atPath: projectSkill.path))
        #expect(FileManager.default.fileExists(atPath: globalSkill.path))

        let check = try #require(checks(bed: bed, registry: registry).first)
        #expect(check.fixCommandPreview != nil)
        let result = check.fix()
        guard case let .fixed(message) = result else {
            Issue.record("Expected .fixed, got \(result)")
            return
        }
        #expect(message.contains("global copy kept"))

        // Project copy gone, global copy intact.
        #expect(!FileManager.default.fileExists(atPath: projectSkill.path))
        #expect(FileManager.default.fileExists(atPath: globalSkill.path))
        #expect(try !(bed.projectState().configuredPacks.contains("dup-pack")))
        #expect(try ProjectState(stateFile: bed.env.globalStateFile)
            .configuredPacks.contains("dup-pack"))

        // The project's CLAUDE.local.md section is gone; the global CLAUDE.md keeps its own.
        let projectClaude = (try? String(contentsOf: bed.claudeLocalPath, encoding: .utf8)) ?? ""
        #expect(!projectClaude.contains("Dup pack guidance."))

        // The project index no longer credits this project with the pack.
        let indexData = try ProjectIndex(path: bed.env.projectsIndexFile).load()
        let projectEntry = indexData.projects.first { $0.path == bed.project.path }
        #expect(projectEntry?.packs.contains("dup-pack") != true)

        // Re-running finds nothing left to report.
        #expect(checks(bed: bed, registry: registry).isEmpty)
    }

    /// `unconfigurePack` removes gitignore entries without reference counting, so the project
    /// removal would otherwise strip a line the global copy still claims.
    @Test("Fix preserves gitignore entries the global copy still claims")
    func fixPreservesSharedGitignoreEntries() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try MockTechPack(
            identifier: "ignore-pack",
            displayName: "Ignore Pack",
            components: [
                bed.skillComponent(
                    pack: "ignore-pack", id: "skillA",
                    source: bed.makeSkillSource(name: "ignore-skill.md"),
                    destination: "ignore-skill.md"
                ),
                ComponentDefinition(
                    id: "ignore-pack.ignores",
                    displayName: "ignores",
                    description: "Gitignore entries",
                    type: .configuration,
                    packIdentifier: "ignore-pack",
                    installAction: .gitignoreEntries(entries: [".mcs-scratch"])
                ),
            ]
        )
        let registry = TechPackRegistry(packs: [pack])
        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let gitignore = bed.home.appendingPathComponent(".config/git/ignore")
        #expect(try String(contentsOf: gitignore, encoding: .utf8).contains(".mcs-scratch"))

        let fixResult = try #require(checks(bed: bed, registry: registry).first).fix()
        guard case .fixed = fixResult else {
            Issue.record("Expected .fixed, got \(fixResult)")
            return
        }

        let after = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(after.contains(".mcs-scratch"))
    }

    // MARK: Runner integration

    @Test("Doctor surfaces the duplication as an issue")
    func doctorReportsDuplicationAsIssue() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = try duplicatingPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])

        try bed.makeConfigurator(registry: registry)
            .configure(packs: [pack], confirmRemovals: false)
        var baselineRunner = bed.makeDoctorRunner(registry: registry)
        let baseline = try baselineRunner.run()

        try bed.makeGlobalSyncConfigurator(registry: registry)
            .configure(packs: [pack], confirmRemovals: false)
        var runner = bed.makeDoctorRunner(registry: registry)
        let duplicated = try runner.run()

        // Deltas, not absolutes: ambient checks contribute their own results.
        #expect(duplicated.issues > baseline.issues)
    }
}

// MARK: - Gitignore Reference Counting (Issue #378)

/// `GitignoreManager` resolves one file for the whole machine, so a gitignore entry is a shared
/// resource like a brew package or a plugin: two scopes hold two claims on one physical line.
///
/// Both entry points are exercised separately because they orchestrate removal differently:
/// deselection during `mcs sync` runs inside `configure()`, while `mcs pack remove` calls
/// `unconfigurePack` directly and runs none of its install or ensure steps — so on that path a
/// ref-counting miss has nothing after it to put the line back.
@Suite("Gitignore reference counting")
struct GitignoreRefCountTests {
    private func ignorePack(id: String, entry: String) -> any TechPack {
        MockTechPack(
            identifier: id,
            displayName: id,
            components: [
                ComponentDefinition(
                    id: "\(id).ignores",
                    displayName: "ignores",
                    description: "Gitignore entries",
                    type: .configuration,
                    packIdentifier: id,
                    installAction: .gitignoreEntries(entries: [entry])
                ),
            ]
        )
    }

    @Test("Deselecting in the project keeps a line the global scope still claims")
    func syncDeselectionKeepsGloballyClaimedEntry() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = ignorePack(id: "ignore-pack", entry: ".mcs-scratch")
        let registry = TechPackRegistry(packs: [pack])

        try configureBothScopes(bed: bed, pack: pack, registry: registry)

        let gitignore = bed.home.appendingPathComponent(".config/git/ignore")
        #expect(try String(contentsOf: gitignore, encoding: .utf8).contains(".mcs-scratch"))

        // Deselect in the project only.
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [], confirmRemovals: false)

        let after = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(after.contains(".mcs-scratch"), "Global scope still claims the line")

        let globalClaims = try bed.globalState().artifacts(for: "ignore-pack")?.gitignoreEntries
        #expect(globalClaims == [".mcs-scratch"], "Global record is untouched")

        let projectState = try bed.projectState()
        #expect(!projectState.configuredPacks.contains("ignore-pack"), "Project claim released")
    }

    @Test("Pack removal keeps a line another pack still declares")
    func packRemoveKeepsEntryDeclaredByAnotherPack() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let packA = ignorePack(id: "pack-a", entry: ".shared-ignore")
        let packB = ignorePack(id: "pack-b", entry: ".shared-ignore")
        let registry = TechPackRegistry(packs: [packA, packB])

        try bed.makeConfigurator(registry: registry)
            .configure(packs: [packA, packB], confirmRemovals: false)

        let gitignore = bed.home.appendingPathComponent(".config/git/ignore")
        #expect(try String(contentsOf: gitignore, encoding: .utf8).contains(".shared-ignore"))

        // The `mcs pack remove pack-a` shape: `packRemoveSentinel` excludes pack-a in every
        // scope, so only pack-b's declaration can keep the line.
        var state = try bed.projectState()
        bed.makeConfigurator(registry: registry).unconfigurePack(
            "pack-a", state: &state, refCountScope: ProjectIndex.packRemoveSentinel
        )
        try state.save()

        let after = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(after.contains(".shared-ignore"), "pack-b still declares the line")
        #expect(!state.configuredPacks.contains("pack-a"))
        #expect(state.configuredPacks.contains("pack-b"))
    }

    @Test("Pack removal deletes a line no one else claims")
    func packRemoveDeletesSoleClaimedEntry() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = ignorePack(id: "solo-pack", entry: ".solo-ignore")
        let registry = TechPackRegistry(packs: [pack])

        try bed.makeConfigurator(registry: registry)
            .configure(packs: [pack], confirmRemovals: false)

        let gitignore = bed.home.appendingPathComponent(".config/git/ignore")
        #expect(try String(contentsOf: gitignore, encoding: .utf8).contains(".solo-ignore"))

        var state = try bed.projectState()
        bed.makeConfigurator(registry: registry).unconfigurePack(
            "solo-pack", state: &state, refCountScope: ProjectIndex.packRemoveSentinel
        )
        try state.save()

        let after = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(!after.contains(".solo-ignore"), "Nothing else claims it — ref counting must not over-keep")
    }
}

@Suite("Brew package doctor checks")
struct BrewPackageDoctorTests {
    /// The ISSUE-388 regression: a tap-qualified package is on PATH only under its last
    /// component, so a check testing the declared string reports a healthy install as missing.
    ///
    /// `git` stands in for a satisfied declaration rather than for a real tap install — the PATH
    /// probe is provenance-blind by design, so the system `git` satisfies `acme/tools/git`. That
    /// PATH hit is also what keeps the test hermetic: `configure` runs
    /// `autoInstallGlobalDependencies` at *project* scope (global installs inline instead), so a
    /// declaration it cannot satisfy would reach a real `brew install` and tap a real repository.
    @Test("A tap-qualified brew package that is installed does not warn")
    func tapQualifiedBrewPackagePassesDoctor() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = MockTechPack(
            identifier: "brew-pack",
            displayName: "Brew Pack",
            components: [bed.brewComponent(pack: "brew-pack", id: "tool", package: "acme/tools/git")]
        )
        let registry = TechPackRegistry(packs: [pack])

        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)

        var runner = bed.makeDoctorRunner(registry: registry)
        let summary = try runner.run()
        #expect(summary.warnings == 0)
        #expect(summary.issues == 0)
    }
}

// MARK: - Bootstrap: additive-vs-prune convergence

struct BootstrapIntegrationTests {
    private let tokenPrompt = PromptDefinition(
        key: "API_TOKEN", type: .input, label: nil, defaultValue: nil,
        options: nil, detectPatterns: nil, scriptCommand: nil
    )

    /// Build a pair of packs, seed both into the project's configured set via a first
    /// `Configurator.configure`, and hand back everything BootstrapCommand.runSync needs.
    private func seedTwoPackProject(
        bed: LifecycleTestBed
    ) throws -> (packA: MockTechPack, packB: MockTechPack, registry: TechPackRegistry) {
        let settingsA = try bed.makeSettingsSource(content: """
        { "env": { "PACK_A_KEY": "valueA" } }
        """)
        let settingsB = try bed.makeSettingsSource(content: """
        { "env": { "PACK_B_KEY": "valueB" } }
        """)
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [bed.settingsComponent(pack: "pack-a", id: "settings", source: settingsA)]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [bed.settingsComponent(pack: "pack-b", id: "settings", source: settingsB)]
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [packA, packB], confirmRemovals: false)
        return (packA, packB, registry)
    }

    @Test("--prune swapping in a pack still gets the values mcs.yaml seeds for it")
    func pruneSwapKeepsSeededValues() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)
        let incoming = bed.adapterPack(
            identifier: "pack-c", displayName: "Pack C", prompts: [tokenPrompt]
        )
        let registry = TechPackRegistry(packs: [seeded.packA, seeded.packB, incoming])

        try BootstrapCommand.parse(["--prune", "--yes"]).runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [incoming.identifier],
            projectState: bed.projectState(),
            seededValues: ["API_TOKEN": "seeded"],
            env: bed.env,
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false),
            shell: ShellRunner(environment: bed.env),
            registry: registry
        )

        let after = try bed.projectState()
        #expect(after.configuredPacks == [incoming.identifier])
        #expect(after.resolvedValues?["API_TOKEN"] == "seeded")
    }

    @Test("Bootstrap dry-run counts seeded values as answers")
    func dryRunSeesSeededValues() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let pack = bed.adapterPack(prompts: [tokenPrompt])
        let registry = TechPackRegistry(packs: [pack])

        func warnings(seededValues: [String: String]) throws -> Int {
            let counter = WarningCounter()
            try BootstrapCommand.parse(["--dry-run"]).runSync(
                projectRoot: bed.project,
                desiredIdentifiers: [pack.identifier],
                projectState: bed.projectState(),
                seededValues: seededValues,
                env: bed.env,
                output: CLIOutput(colorsEnabled: false, warningCounter: counter, interactiveStdin: false),
                shell: ShellRunner(environment: bed.env),
                registry: registry
            )
            return counter.count
        }

        #expect(try warnings(seededValues: [:]) == 1)
        #expect(try warnings(seededValues: ["API_TOKEN": "seeded"]) == 0)
    }

    @Test("Additive default preserves a previously-configured pack absent from mcs.yaml")
    func additiveDefaultKeepsExtras() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        // Bootstrap declares only pack-a; pack-b is an extra.
        let command = try BootstrapCommand.parse([])

        let projectState = try bed.projectState()
        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [seeded.packA.identifier],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: seeded.registry
        )

        let after = try bed.projectState()
        #expect(after.configuredPacks.contains(seeded.packA.identifier))
        #expect(after.configuredPacks.contains(seeded.packB.identifier))

        let envDict = try bed.settingsEnv()
        #expect(envDict["PACK_A_KEY"] as? String == "valueA")
        #expect(envDict["PACK_B_KEY"] as? String == "valueB")
    }

    @Test("--prune removes packs configured in the project but absent from mcs.yaml")
    func pruneRemovesExtras() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        let command = try BootstrapCommand.parse(["--prune", "--yes"])

        let projectState = try bed.projectState()
        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [seeded.packA.identifier],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: seeded.registry
        )

        let after = try bed.projectState()
        #expect(after.configuredPacks.contains(seeded.packA.identifier))
        #expect(!after.configuredPacks.contains(seeded.packB.identifier))

        let envDict = try bed.settingsEnv()
        #expect(envDict["PACK_A_KEY"] as? String == "valueA")
        #expect(envDict["PACK_B_KEY"] == nil)
    }

    @Test("Additive re-add of only the declared pack is a no-op — extras untouched")
    func additiveNoOpWhenExtrasStillDeclared() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        let command = try BootstrapCommand.parse([])

        let projectState = try bed.projectState()
        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [seeded.packA.identifier, seeded.packB.identifier],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: seeded.registry
        )

        let after = try bed.projectState()
        #expect(after.configuredPacks == Set([seeded.packA.identifier, seeded.packB.identifier]))
    }

    @Test("Additive mode rejects an extra whose registry entry is gone (would otherwise silently uninstall)")
    func additiveBlocksUnresolvableExtra() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        // Simulate pack-b removed from the registry between runs (e.g. `mcs pack remove`
        // ran out of band). pack-b is still in projectState.configuredPacks as an extra.
        let strippedRegistry = TechPackRegistry(packs: [seeded.packA])
        let command = try BootstrapCommand.parse([])
        let projectState = try bed.projectState()

        // Additive default must NOT silently unconfigure pack-b just because the
        // registry cannot resolve it — that is the exact "filter-then-configure
        // uninstalls" pattern the guard defends against.
        #expect(throws: (any Error).self) {
            try command.runSync(
                projectRoot: bed.project,
                desiredIdentifiers: [seeded.packA.identifier],
                projectState: projectState,
                env: bed.env,
                output: CLIOutput(colorsEnabled: false),
                shell: ShellRunner(environment: bed.env),
                registry: strippedRegistry
            )
        }

        // pack-b's artifacts (the settings env entry) must still be on disk — nothing
        // ran through unconfigurePack.
        let after = try bed.projectState()
        #expect(after.configuredPacks.contains(seeded.packB.identifier))
        let envDict = try bed.settingsEnv()
        #expect(envDict["PACK_B_KEY"] as? String == "valueB")
    }

    @Test("--prune allows an extra whose registry entry is gone through to removal")
    func pruneAllowsUnresolvableExtraThrough() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        let strippedRegistry = TechPackRegistry(packs: [seeded.packA])
        let command = try BootstrapCommand.parse(["--prune", "--yes"])
        let projectState = try bed.projectState()

        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [seeded.packA.identifier],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: strippedRegistry
        )

        let after = try bed.projectState()
        #expect(!after.configuredPacks.contains(seeded.packB.identifier))
        let envDict = try bed.settingsEnv()
        #expect(envDict["PACK_B_KEY"] == nil)
    }

    @Test("dry-run on a fresh project with no registered packs is a no-op, not a failure")
    func dryRunEmptyResolvedIsNoop() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        // Fresh project — no packs configured, no packs in `desiredIdentifiers`
        // (installPacks in dry-run mode does not append IDs for new packs).
        let command = try BootstrapCommand.parse(["--dry-run"])
        let projectState = try bed.projectState()
        let emptyRegistry = TechPackRegistry(packs: [])

        // Must not throw. Prior behavior threw "No packs could be loaded", defeating
        // the preview flow on a fresh manifest.
        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: emptyRegistry
        )

        // No artifacts written.
        #expect(!FileManager.default.fileExists(atPath: bed.settingsLocalPath.path))
    }

    @Test("--prune bypasses the unloadable-scope guard so a broken configured pack can be pruned")
    func pruneBypassesUnloadableScopeGuard() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        // Simulate pack-b becoming unloadable (broken manifest / removed from registry).
        // In additive mode, `scopeIsBlockedByUnloadablePack` would abort the whole scope
        // — meaning a broken pack blocks *any* bootstrap. `--prune` must be able to
        // clean it up instead.
        let strippedRegistry = TechPackRegistry(packs: [seeded.packA])
        let command = try BootstrapCommand.parse(["--prune", "--yes"])
        let projectState = try bed.projectState()

        try command.runSync(
            projectRoot: bed.project,
            desiredIdentifiers: [seeded.packA.identifier],
            projectState: projectState,
            env: bed.env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: bed.env),
            registry: strippedRegistry
        )

        let after = try bed.projectState()
        #expect(!after.configuredPacks.contains(seeded.packB.identifier))
    }

    @Test("--trust-all is the only thing that selects .autoAccept")
    func trustAllFlagSelectsAutoAccept() throws {
        // Pins the flag's spelling and the direction of the mapping. Without this, a renamed
        // flag or an inverted ternary would ship green — every other trust test constructs the
        // policy directly and never parses an argument vector.
        #expect(try BootstrapCommand.parse([]).trustPolicy == .prompt)
        #expect(try BootstrapCommand.parse(["--trust-all"]).trustPolicy == .autoAccept)
        #expect(try BootstrapCommand.parse(["--prune", "--yes"]).trustPolicy == .prompt)
    }
}

// MARK: - Sync --pack: additive-vs-prune convergence

struct SyncPackAdditiveTests {
    /// Two configured packs: pack-a merges a settings key, pack-b registers a hook, so the
    /// assertions cover both the state and what `configure` recomposes from the pack list.
    private func seedTwoPackProject(
        bed: LifecycleTestBed
    ) throws -> (packA: MockTechPack, packB: MockTechPack, registry: TechPackRegistry) {
        let settingsA = try bed.makeSettingsSource(content: """
        { "env": { "PACK_A_KEY": "valueA" } }
        """)
        let hookB = try bed.makeHookSource(name: "guard.sh")
        let packA = MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [bed.settingsComponent(pack: "pack-a", id: "settings", source: settingsA)]
        )
        let packB = MockTechPack(
            identifier: "pack-b",
            displayName: "Pack B",
            components: [bed.hookComponent(
                pack: "pack-b", id: "guard", source: hookB, destination: "guard.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )
        let registry = TechPackRegistry(packs: [packA, packB])
        try bed.makeConfigurator(registry: registry)
            .configure(packs: [packA, packB], confirmRemovals: false)
        return (packA, packB, registry)
    }

    private func sync(
        _ arguments: [String],
        bed: LifecycleTestBed,
        registry: TechPackRegistry
    ) throws {
        try SyncCommand.parse(arguments).syncRequestedPacks(
            configurator: bed.makeConfigurator(registry: registry),
            registry: registry,
            previouslyConfigured: bed.projectState().configuredPacks,
            globallyInstalled: [],
            scopeLabel: "Project",
            targetPath: bed.project.path,
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false)
        )
    }

    private func preToolUseCommands(_ bed: LifecycleTestBed) throws -> [String] {
        try bed.hookCommands(event: Constants.HookEvent.preToolUse.rawValue)
    }

    @Test("--pack keeps packs it does not name, including their composed hook entries")
    func packKeepsUnnamedPacks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)
        let hookCommand = bed.projectHookCommand("pack-b/guard.sh")
        #expect(try preToolUseCommands(bed).contains(hookCommand))

        try sync(["--pack", "pack-a"], bed: bed, registry: seeded.registry)

        #expect(try bed.projectState().configuredPacks == ["pack-a", "pack-b"])
        #expect(try preToolUseCommands(bed).contains(hookCommand))
        #expect(try bed.settingsEnv()["PACK_A_KEY"] as? String == "valueA")
    }

    @Test("--pack --prune removes packs it does not name")
    func pruneRemovesUnnamedPacks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        try sync(["--pack", "pack-a", "--prune", "--yes"], bed: bed, registry: seeded.registry)

        #expect(try bed.projectState().configuredPacks == ["pack-a"])
        #expect(try !preToolUseCommands(bed).contains(bed.projectHookCommand("pack-b/guard.sh")))
    }

    @Test("--pack aborts on a configured pack the registry cannot produce instead of removing it")
    func packAbortsOnUnresolvableExtra() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)
        let strippedRegistry = TechPackRegistry(packs: [seeded.packA])

        #expect(throws: (any Error).self) {
            try sync(["--pack", "pack-a"], bed: bed, registry: strippedRegistry)
        }

        #expect(try bed.projectState().configuredPacks.contains("pack-b"))
        #expect(try preToolUseCommands(bed).contains(bed.projectHookCommand("pack-b/guard.sh")))
    }

    @Test("--prune refuses a --pack name it cannot resolve instead of pruning around it")
    func pruneRefusesUnknownName() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let seeded = try seedTwoPackProject(bed: bed)

        #expect(throws: (any Error).self) {
            try sync(["--pack", "pack-a", "--pack", "pack-bb", "--prune", "--yes"], bed: bed, registry: seeded.registry)
        }

        #expect(try bed.projectState().configuredPacks == ["pack-a", "pack-b"])
    }
}

// MARK: - Doctor --fix: scope re-sync

/// A check a pack author wrote. A re-sync cannot satisfy it, so it must never trigger one.
private struct UnsatisfiableCheck: DoctorCheck {
    let name = "Pack-authored check"
    let section = "Dependencies"

    func check() -> CheckResult {
        .fail("never satisfied")
    }

    func fix() -> FixResult {
        .notFixable("install it yourself")
    }
}

struct DoctorFixResyncTests {
    private func hookPack(_ id: String, bed: LifecycleTestBed) throws -> MockTechPack {
        try MockTechPack(
            identifier: id,
            displayName: id,
            components: [bed.hookComponent(
                pack: id, id: "lint", source: bed.makeHookSource(name: "\(id)-lint.sh"), destination: "lint.sh",
                hookRegistration: HookRegistration(event: .preToolUse)
            )]
        )
    }

    private func installedHook(_ packID: String, bed: LifecycleTestBed) -> URL {
        bed.project.appendingPathComponent(".claude/hooks/\(packID)/lint.sh")
    }

    private func editPackAKey(bed: LifecycleTestBed) throws {
        let data = try Data(contentsOf: bed.settingsLocalPath)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["env"] = ["PACK_A_KEY": "edited"]
        try JSONSerialization.data(withJSONObject: json).write(to: bed.settingsLocalPath)
    }

    /// A settings key a re-sync would reset, plus a hook file whose absence is sync-repairable.
    private func settingsPack(bed: LifecycleTestBed, extraChecks: [any DoctorCheck] = []) throws -> MockTechPack {
        let settings = try bed.makeSettingsSource(content: """
        { "env": { "PACK_A_KEY": "valueA" } }
        """)
        return try MockTechPack(
            identifier: "pack-a",
            displayName: "Pack A",
            components: [
                bed.settingsComponent(pack: "pack-a", id: "settings", source: settings),
                bed.hookComponent(
                    pack: "pack-a", id: "lint", source: bed.makeHookSource(name: "pack-a-lint.sh"), destination: "lint.sh"
                ),
            ],
            supplementaryDoctorChecks: extraChecks
        )
    }

    @Test("--fix re-syncs a failed check's scope onto every configured pack, not just the filtered one")
    func fixRestoresMissingFileAndKeepsOtherPacks() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let packA = try hookPack("pack-a", bed: bed)
        let packB = try hookPack("pack-b", bed: bed)
        let registry = TechPackRegistry(packs: [packA, packB])
        try bed.makeConfigurator(registry: registry).configure(packs: [packA, packB], confirmRemovals: false)

        try FileManager.default.removeItem(at: installedHook("pack-a", bed: bed))

        var runner = bed.makeDoctorRunner(registry: registry, packFilter: "pack-a", fixMode: true)
        let summary = try runner.run()

        #expect(summary.issues > 0)
        #expect(summary.isHealthy)
        #expect(FileManager.default.fileExists(atPath: installedHook("pack-a", bed: bed).path))
        #expect(try bed.projectState().configuredPacks == ["pack-a", "pack-b"])
        #expect(try bed.hookCommands(event: Constants.HookEvent.preToolUse.rawValue)
            .contains(bed.projectHookCommand("pack-b/lint.sh")))
        #expect(try bed.runDoctor(registry: registry).issues == 0)
    }

    @Test("--fix re-syncs, resetting an edited managed value, when a sync-repairable check fails")
    func fixResyncResetsEditedValue() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let pack = try settingsPack(bed: bed)
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
        try editPackAKey(bed: bed)
        try FileManager.default.removeItem(at: installedHook("pack-a", bed: bed))

        var runner = bed.makeDoctorRunner(registry: registry, fixMode: true)
        try runner.run()

        #expect(try bed.settingsEnv()["PACK_A_KEY"] as? String == "valueA")
    }

    @Test("--fix does not re-sync for a failing check a pack author wrote")
    func fixSkipsResyncForPackAuthoredCheck() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let pack = try settingsPack(bed: bed, extraChecks: [UnsatisfiableCheck()])
        let registry = TechPackRegistry(packs: [pack])
        try bed.makeConfigurator(registry: registry).configure(packs: [pack], confirmRemovals: false)
        // `fixResyncResetsEditedValue` shows a re-sync resets this, so an edit that survives
        // proves none ran.
        try editPackAKey(bed: bed)

        var runner = bed.makeDoctorRunner(registry: registry, fixMode: true)
        let summary = try runner.run()

        #expect(try bed.settingsEnv()["PACK_A_KEY"] as? String == "edited")
        #expect(!summary.isHealthy)
    }

    @Test("--pack naming a global-only pack from a project never re-syncs the project")
    func fixDoesNotResyncProjectForGlobalOnlyPack() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let globalPack = try hookPack("pack-g", bed: bed)
        let projectPack = try settingsPack(bed: bed)
        let registry = TechPackRegistry(packs: [globalPack, projectPack])
        try bed.makeGlobalSyncConfigurator(registry: registry).configure(packs: [globalPack], confirmRemovals: false)
        try bed.makeConfigurator(registry: registry).configure(packs: [projectPack], confirmRemovals: false)
        try editPackAKey(bed: bed)
        try FileManager.default.removeItem(at: bed.env.hooksDirectory)

        var runner = bed.makeDoctorRunner(registry: registry, packFilter: "pack-g", fixMode: true)
        try runner.run()

        #expect(try bed.settingsEnv()["PACK_A_KEY"] as? String == "edited")
    }

    @Test("A scope whose re-apply is blocked is left untouched")
    func fixLeavesBlockedScopeUntouched() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let packA = try hookPack("pack-a", bed: bed)
        let packB = try hookPack("pack-b", bed: bed)
        try bed.makeConfigurator(registry: TechPackRegistry(packs: [packA, packB]))
            .configure(packs: [packA, packB], confirmRemovals: false)
        try FileManager.default.removeItem(at: installedHook("pack-a", bed: bed))

        let strippedRegistry = TechPackRegistry(packs: [packA])
        var runner = bed.makeDoctorRunner(registry: strippedRegistry, fixMode: true)
        let summary = try runner.run()

        #expect(!summary.isHealthy)
        #expect(try bed.projectState().configuredPacks.contains("pack-b"))
        #expect(try bed.hookCommands(event: Constants.HookEvent.preToolUse.rawValue)
            .contains(bed.projectHookCommand("pack-b/lint.sh")))
        #expect(!FileManager.default.fileExists(atPath: installedHook("pack-a", bed: bed).path))
    }

    @Test("A re-sync after a scope-duplication fix does not reinstall the removed pack")
    func resyncAfterDuplicationFixKeepsPackRemoved() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }
        let dup = try MockTechPack(
            identifier: "dup-pack",
            displayName: "Dup Pack",
            components: [bed.skillComponent(
                pack: "dup-pack", id: "skillA", source: bed.makeSkillSource(name: "dup-skill.md"), destination: "dup-skill.md"
            )]
        )
        let packA = try hookPack("pack-a", bed: bed)
        let registry = TechPackRegistry(packs: [dup, packA])
        try bed.makeConfigurator(registry: registry).configure(packs: [dup, packA], confirmRemovals: false)
        try bed.makeGlobalSyncConfigurator(registry: registry).configure(packs: [dup], confirmRemovals: false)
        try FileManager.default.removeItem(at: installedHook("pack-a", bed: bed))

        var runner = bed.makeDoctorRunner(registry: registry, fixMode: true)
        try runner.run()

        #expect(try bed.projectState().configuredPacks == ["pack-a"])
        #expect(!FileManager.default.fileExists(atPath: bed.project.appendingPathComponent(".claude/skills/dup-skill.md").path))
        #expect(FileManager.default.fileExists(atPath: installedHook("pack-a", bed: bed).path))
    }
}

// MARK: - Bootstrap: MCSConfig migration is dry-run safe

struct BootstrapMigrationPersistenceTests {
    @Test("BootstrapCommand.perform in dry-run does not persist the legacy-key migration")
    func dryRunLeavesLegacyConfigIntact() throws {
        // The BootstrapCommand.perform path threads MCSConfig.load through
        // `if !dryRun`, and `MCSConfig.load` itself never writes to disk anymore —
        // pin both invariants with a direct check on the load API, since the full
        // BootstrapCommand.perform requires cwd + registry + claude-cli plumbing.
        let tmpDir = try makeTmpDir(label: "bootstrap-migration")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        let original = "update-check-packs: false\n"
        try original.write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.didMigrateLegacyUpdateCheck)

        let onDisk = try String(contentsOf: path, encoding: .utf8)
        #expect(onDisk == original, "load must not touch the file — the persist step is caller-driven")

        // The non-dry-run path in Bootstrap/Sync explicitly opts into persistence.
        config.persistMigrationIfNeeded(to: path)
        let afterPersist = try String(contentsOf: path, encoding: .utf8)
        #expect(afterPersist.contains("update-check: false"))
    }
}

private struct TemplateFailingPack: TechPack {
    let identifier: String
    let displayName: String = "Template Failing Pack"
    let description: String = "A pack whose templates throw"
    let components: [ComponentDefinition] = []
    var templates: [TemplateContribution] {
        get throws { throw TemplateLoadError() }
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}

    private struct TemplateLoadError: Error, LocalizedError {
        var errorDescription: String? {
            "simulated template load failure"
        }
    }
}

// MARK: - Directory-sourced skills drop files upstream

struct DroppedDirectoryFileTests {
    private enum Scope: CaseIterable {
        case project, global
    }

    private func configure(
        _ bed: LifecycleTestBed,
        scope: Scope,
        pack: MockTechPack,
        warningCounter: WarningCounter? = nil
    ) throws {
        let registry = TechPackRegistry(packs: [pack])
        let configurator = switch scope {
        case .project: bed.makeConfigurator(registry: registry, warningCounter: warningCounter)
        case .global: bed.makeGlobalSyncConfigurator(registry: registry, warningCounter: warningCounter)
        }
        try configurator.configure(packs: [pack], confirmRemovals: false)
    }

    private func installedSkill(_ bed: LifecycleTestBed, scope: Scope) -> URL {
        switch scope {
        case .project: bed.project.appendingPathComponent(".claude/skills/my-skill")
        case .global: bed.env.skillsDirectory.appendingPathComponent("my-skill")
        }
    }

    private func state(_ bed: LifecycleTestBed, scope: Scope) throws -> ProjectState {
        switch scope {
        case .project: try bed.projectState()
        case .global: try bed.globalState()
        }
    }

    private func record(_ bed: LifecycleTestBed, scope: Scope) throws -> PackArtifactRecord {
        try #require(state(bed, scope: scope).artifacts(for: "my-pack"))
    }

    private func trackedKey(_: LifecycleTestBed, scope: Scope, _ name: String) -> String {
        switch scope {
        case .project: ".claude/skills/my-skill/\(name)"
        case .global: "skills/my-skill/\(name)"
        }
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makePack(_ bed: LifecycleTestBed, source: URL) -> MockTechPack {
        MockTechPack(
            identifier: "my-pack",
            displayName: "My Pack",
            components: [bed.skillComponent(pack: "my-pack", id: "skill", source: source, destination: "my-skill")]
        )
    }

    @Test("Re-sync removes files the pack dropped and prunes emptied directories", arguments: Scope.allCases)
    private func removesDroppedFiles(scope: Scope) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("# Skill", to: source.appendingPathComponent("SKILL.md"))
        try write("old", to: source.appendingPathComponent("old.md"))
        try write("old ref", to: source.appendingPathComponent("references/old-ref.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: scope, pack: pack)

        let installed = installedSkill(bed, scope: scope)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("old.md").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("references/old-ref.md").path))

        try fm.removeItem(at: source.appendingPathComponent("old.md"))
        try fm.removeItem(at: source.appendingPathComponent("references"))
        try write("new", to: source.appendingPathComponent("new.md"))
        try configure(bed, scope: scope, pack: pack)

        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("old.md").path))
        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("references").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("SKILL.md").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("new.md").path))

        #expect(try Set(record(bed, scope: scope).fileHashes.keys) == [
            trackedKey(bed, scope: scope, "SKILL.md"),
            trackedKey(bed, scope: scope, "new.md"),
        ])
    }

    @Test("A dropped file the user already deleted is untracked without warnings", arguments: Scope.allCases)
    private func droppedFileAlreadyAbsent(scope: Scope) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("# Skill", to: source.appendingPathComponent("SKILL.md"))
        try write("old", to: source.appendingPathComponent("old.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: scope, pack: pack)

        let fm = FileManager.default
        try fm.removeItem(at: source.appendingPathComponent("old.md"))
        try fm.removeItem(at: installedSkill(bed, scope: scope).appendingPathComponent("old.md"))
        let counter = WarningCounter()
        try configure(bed, scope: scope, pack: pack, warningCounter: counter)

        let oldKey = trackedKey(bed, scope: scope, "old.md")
        #expect(try record(bed, scope: scope).fileHashes[oldKey] == nil)
        #expect(try !record(bed, scope: scope).files.contains(oldKey))
        #expect(counter.count == 0)
    }

    @Test(
        "A dropped file that cannot be deleted warns once, stays tracked, and is removed on the next sync",
        .enabled(if: getuid() != 0, "root ignores directory permissions"),
        arguments: Scope.allCases
    )
    private func failedRemovalRetries(scope: Scope) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("# Skill", to: source.appendingPathComponent("SKILL.md"))
        try write("old", to: source.appendingPathComponent("stale/old.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: scope, pack: pack)

        let fm = FileManager.default
        let staleDir = installedSkill(bed, scope: scope).appendingPathComponent("stale")
        let oldFile = staleDir.appendingPathComponent("old.md")
        try fm.removeItem(at: source.appendingPathComponent("stale"))
        // A read-only parent makes the delete fail; restore it first or cleanup fails too.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staleDir.path)
        defer { _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staleDir.path) }

        let counter = WarningCounter()
        try configure(bed, scope: scope, pack: pack, warningCounter: counter)

        #expect(counter.count == 1)
        #expect(fm.fileExists(atPath: oldFile.path))
        let failed = try record(bed, scope: scope)
        switch scope {
        case .project: #expect(failed.files.contains(trackedKey(bed, scope: scope, "stale")))
        case .global: #expect(failed.fileHashes[trackedKey(bed, scope: scope, "stale/old.md")] != nil)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staleDir.path)
        try configure(bed, scope: scope, pack: pack)

        #expect(!fm.fileExists(atPath: staleDir.path))
        let retried = try record(bed, scope: scope)
        #expect(!retried.files.contains(trackedKey(bed, scope: scope, "stale")))
        #expect(retried.fileHashes[trackedKey(bed, scope: scope, "stale/old.md")] == nil)
    }

    @Test("A file the user adds inside an installed skill survives re-sync untracked", arguments: Scope.allCases)
    private func preservesUserFile(scope: Scope) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("# Skill", to: source.appendingPathComponent("SKILL.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: scope, pack: pack)

        let userFile = installedSkill(bed, scope: scope).appendingPathComponent("notes.md")
        try write("mine", to: userFile)
        try configure(bed, scope: scope, pack: pack)

        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(try record(bed, scope: scope).fileHashes[trackedKey(bed, scope: scope, "notes.md")] == nil)
    }

    @Test("First sync over a legacy record keeps user files it hashed, then cleanup resumes", arguments: Scope.allCases)
    private func legacyRecordRebaselines(scope: Scope) throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("# Skill", to: source.appendingPathComponent("SKILL.md"))
        try write("keep", to: source.appendingPathComponent("references/keep.md"))
        try write("old ref", to: source.appendingPathComponent("references/old-ref.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: scope, pack: pack)

        // Older mcs hashed every file under the installed directory, including ones the user added.
        let installed = installedSkill(bed, scope: scope)
        let userFile = installed.appendingPathComponent("notes.md")
        try write("mine", to: userFile)
        var legacyState = try state(bed, scope: scope)
        var legacy = try record(bed, scope: scope)
        legacy.fileHashes[trackedKey(bed, scope: scope, "notes.md")] = try FileHasher.sha256(of: userFile)
        legacy.fileHashesShippedOnly = nil
        legacyState.setArtifacts(legacy, for: "my-pack")
        try legacyState.save()

        try configure(bed, scope: scope, pack: pack)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: userFile.path))
        #expect(try record(bed, scope: scope).fileHashes[trackedKey(bed, scope: scope, "notes.md")] == nil)
        #expect(try record(bed, scope: scope).fileHashesShippedOnly == true)

        try fm.removeItem(at: source.appendingPathComponent("references/old-ref.md"))
        try configure(bed, scope: scope, pack: pack)

        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("references/old-ref.md").path))
        #expect(fm.fileExists(atPath: installed.appendingPathComponent("references/keep.md").path))
        #expect(fm.fileExists(atPath: userFile.path))
    }

    @Test("Pruning emptied directories stops at the installed skill directory")
    func pruneStopsAtInstalledRoot() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let source = bed.home.appendingPathComponent("pack-source/my-skill")
        try write("a", to: source.appendingPathComponent("docs/a.md"))
        try write("b", to: source.appendingPathComponent("b.md"))
        let pack = makePack(bed, source: source)
        try configure(bed, scope: .global, pack: pack)

        let fm = FileManager.default
        try fm.removeItem(at: source.appendingPathComponent("docs"))
        try fm.removeItem(at: source.appendingPathComponent("b.md"))
        try configure(bed, scope: .global, pack: pack)

        let installed = installedSkill(bed, scope: .global)
        #expect(try fm.contentsOfDirectory(atPath: installed.path).isEmpty)
    }
}
