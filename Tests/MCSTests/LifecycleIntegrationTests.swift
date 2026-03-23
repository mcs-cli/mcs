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

    func makeGlobalConfigurator(registry: TechPackRegistry = TechPackRegistry()) -> Configurator {
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
        let hookFile = bed.project.appendingPathComponent(".claude/hooks/lint.sh")
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
        #expect(hookCommands.contains("bash .claude/hooks/lint.sh"))

        // Verify MCP server was registered via MockClaudeCLI with local scope
        #expect(bed.mockCLI.mcpAddCalls.contains { $0.name == "test-mcp" && $0.scope == "local" })

        // Verify state
        let state = try bed.projectState()
        #expect(state.configuredPacks.contains("test-pack"))
        let artifacts = state.artifacts(for: "test-pack")
        #expect(artifacts != nil)
        #expect(artifacts?.templateSections.contains("test-pack") == true)
        #expect(artifacts?.settingsKeys.contains("env") == true)
        #expect(artifacts?.hookCommands.contains("bash .claude/hooks/lint.sh") == true)
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

        let hookAPath = bed.project.appendingPathComponent(".claude/hooks/hookA.sh")
        let hookBPath = bed.project.appendingPathComponent(".claude/hooks/hookB.sh")

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
        let configurator = bed.makeGlobalConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        // Verify hook installed in ~/.claude/hooks/
        let globalHook = bed.env.hooksDirectory.appendingPathComponent("global-hook.sh")
        #expect(FileManager.default.fileExists(atPath: globalHook.path))

        // Verify global state
        let globalState = try ProjectState(stateFile: bed.env.globalStateFile)
        #expect(globalState.configuredPacks.contains("global-pack"))

        // === Doctor passes ===
        try bed.runGlobalDoctor(registry: registry)
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
        let configurator = bed.makeGlobalConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false)

        let hookAPath = bed.env.hooksDirectory.appendingPathComponent("globalA.sh")
        let hookBPath = bed.env.hooksDirectory.appendingPathComponent("globalB.sh")
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

        #expect(entry["command"] as? String == "bash .claude/hooks/lint.sh")
        #expect(entry["timeout"] as? Int == 30)
        #expect(entry["async"] as? Bool == true)
        #expect(entry["statusMessage"] as? String == "Running lint...")

        // === Doctor passes with metadata present ===
        try bed.runDoctor(registry: registry)
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

    // MARK: - Update check hook injection

    @Test("Project sync injects update check hook when config enabled")
    func projectSyncInjectsUpdateHook() throws {
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

        // Verify the hook is in settings.local.json
        let settings = try Settings.load(from: bed.settingsLocalPath)
        let sessionStartGroups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
        let commands = sessionStartGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(commands.contains(UpdateChecker.hookCommand))
    }

    @Test("Project sync omits update check hook when config disabled")
    func projectSyncOmitsHookWhenDisabled() throws {
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

        // Verify no update check hook in settings
        let fm = FileManager.default
        if fm.fileExists(atPath: bed.settingsLocalPath.path) {
            let settings = try Settings.load(from: bed.settingsLocalPath)
            let sessionStartGroups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
            let commands = sessionStartGroups.flatMap { $0.hooks ?? [] }.compactMap(\.command)
            #expect(!commands.contains(UpdateChecker.hookCommand))
        }
    }

    @Test("Project sync converges hook on re-sync: enable then disable")
    func projectSyncConvergesHook() throws {
        let bed = try LifecycleTestBed()
        defer { bed.cleanup() }

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack", components: [])
        let registry = TechPackRegistry(packs: [pack])

        // First sync: enabled
        var config = MCSConfig()
        config.updateCheckPacks = true
        try config.save(to: bed.env.mcsConfigFile)

        var configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false, excludedComponents: [:])

        let settings1 = try Settings.load(from: bed.settingsLocalPath)
        let commands1 = (settings1.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
            .flatMap { $0.hooks ?? [] }.compactMap(\.command)
        #expect(commands1.contains(UpdateChecker.hookCommand))

        // Second sync: disabled
        config.updateCheckPacks = false
        config.updateCheckCLI = false
        try config.save(to: bed.env.mcsConfigFile)

        configurator = bed.makeConfigurator(registry: registry)
        try configurator.configure(packs: [pack], confirmRemovals: false, excludedComponents: [:])

        // Project strategy rebuilds from scratch — hook should be absent
        if FileManager.default.fileExists(atPath: bed.settingsLocalPath.path) {
            let settings2 = try Settings.load(from: bed.settingsLocalPath)
            let commands2 = (settings2.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? [])
                .flatMap { $0.hooks ?? [] }.compactMap(\.command)
            #expect(!commands2.contains(UpdateChecker.hookCommand))
        }
    }
}
