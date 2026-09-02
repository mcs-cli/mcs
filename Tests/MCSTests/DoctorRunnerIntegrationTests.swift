import Foundation
@testable import mcs
import Testing

// MARK: - Helpers

private func makeRunner(
    home: URL,
    projectRoot: URL? = nil,
    registry: TechPackRegistry = TechPackRegistry(),
    fixMode: Bool = false,
    globalOnly: Bool = false,
    packFilter: String? = nil
) -> DoctorRunner {
    DoctorRunner(
        fixMode: fixMode,
        skipConfirmation: true,
        packFilter: packFilter,
        globalOnly: globalOnly,
        registry: registry,
        environment: Environment(home: home),
        projectRootOverride: projectRoot
    )
}

// MARK: - DoctorRunner Integration Tests

struct DoctorRunnerIntegrationTests {
    @Test("runner completes with empty registry and no state")
    func emptyRegistryCompletes() throws {
        let (home, project) = try makeSandboxProject(label: "runner-empty")
        defer { try? FileManager.default.removeItem(at: home) }

        var runner = makeRunner(home: home, projectRoot: project)
        // Should not throw — just runs with no packs, no checks
        try runner.run()
    }

    @Test("runner with globalOnly only checks global scope")
    func globalOnlyChecksGlobalScope() throws {
        let (home, _) = try makeSandboxProject(label: "runner-global")
        defer { try? FileManager.default.removeItem(at: home) }

        // Write global state with a pack
        let env = Environment(home: home)
        var globalState = try ProjectState(stateFile: env.globalStateFile)
        globalState.recordPack("test-pack")
        globalState.setArtifacts(
            PackArtifactRecord(settingsKeys: ["env.FOO"]),
            for: "test-pack"
        )
        try globalState.save()

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack")
        let registry = TechPackRegistry(packs: [pack])

        var runner = makeRunner(home: home, registry: registry, globalOnly: true)
        // Should complete without error — the settings key check will fail
        // since there's no settings.json, but that's expected behavior
        try runner.run()
    }

    @Test("runner with pack filter only checks filtered packs")
    func packFilterRestrictsChecks() throws {
        let (home, project) = try makeSandboxProject(label: "runner-filter")
        defer { try? FileManager.default.removeItem(at: home) }

        let packA = MockTechPack(identifier: "pack-a", displayName: "Pack A")
        let packB = MockTechPack(identifier: "pack-b", displayName: "Pack B")
        let registry = TechPackRegistry(packs: [packA, packB])

        // Write project state with both packs
        var state = try ProjectState(projectRoot: project)
        state.recordPack("pack-a")
        state.recordPack("pack-b")
        try state.save()

        // Filter to only pack-a
        var runner = makeRunner(
            home: home, projectRoot: project,
            registry: registry, packFilter: "pack-a"
        )
        try runner.run()
    }

    @Test("runner detects missing artifacts from state file")
    func detectsMissingArtifacts() throws {
        let (home, project) = try makeSandboxProject(label: "runner-artifacts")
        defer { try? FileManager.default.removeItem(at: home) }

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack")
        let registry = TechPackRegistry(packs: [pack])

        // Write project state with artifact records pointing to non-existent files
        var state = try ProjectState(projectRoot: project)
        state.recordPack("test-pack")
        state.setArtifacts(
            PackArtifactRecord(
                files: [".claude/skills/missing-skill.md"],
                fileHashes: [".claude/skills/missing-skill.md": "abc123"]
            ),
            for: "test-pack"
        )
        try state.save()

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        // Should complete — the FileContentCheck will skip (missing file)
        try runner.run()
    }

    @Test("runner with excluded components skips those checks")
    func excludedComponentsSkipped() throws {
        let (home, project) = try makeSandboxProject(label: "runner-excluded")
        defer { try? FileManager.default.removeItem(at: home) }

        let hookComponent = ComponentDefinition(
            id: "test-pack.lint-hook",
            displayName: "Lint Hook",
            description: "A lint hook",
            type: .hookFile,
            packIdentifier: "test-pack",
            dependencies: [],
            isRequired: false,
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/dummy"),
                destination: "lint.sh",
                fileType: .hook
            )
        )
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [hookComponent]
        )
        let registry = TechPackRegistry(packs: [pack])

        // Write project state with the hook excluded
        var state = try ProjectState(projectRoot: project)
        state.recordPack("test-pack")
        state.setExcludedComponents(["test-pack.lint-hook"], for: "test-pack")
        try state.save()

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        // Should complete — the excluded component's check is skipped
        try runner.run()
    }

    @Test("runner resolves project packs from .mcs-project state")
    func resolvesPacksFromProjectState() throws {
        let (home, project) = try makeSandboxProject(label: "runner-state")
        defer { try? FileManager.default.removeItem(at: home) }

        let pack = MockTechPack(identifier: "my-pack", displayName: "My Pack")
        let registry = TechPackRegistry(packs: [pack])

        // Write project state
        var state = try ProjectState(projectRoot: project)
        state.recordPack("my-pack")
        try state.save()

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        // Should detect the pack from project state
        try runner.run()
    }

    @Test("PluginCheck passes when plugin is enabled in project settings.local.json")
    func pluginCheckPassesWithProjectSettings() throws {
        let (home, project) = try makeSandboxProject(label: "runner-plugin-project")
        defer { try? FileManager.default.removeItem(at: home) }

        let pluginComponent = ComponentDefinition(
            id: "test-pack.my-plugin",
            displayName: "My Plugin",
            description: "Test plugin",
            type: .plugin,
            packIdentifier: "test-pack",
            dependencies: [],
            isRequired: true,
            installAction: .plugin(name: "my-plugin")
        )
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [pluginComponent]
        )
        let registry = TechPackRegistry(packs: [pack])

        // Write project state
        var state = try ProjectState(projectRoot: project)
        state.recordPack("test-pack")
        try state.save()

        // Write plugin enablement to project-scoped settings.local.json only
        let claudeDir = project.appendingPathComponent(Constants.FileNames.claudeDirectory)
        let projectSettings = """
        {
          "enabledPlugins": {
            "my-plugin": true
          }
        }
        """
        try projectSettings.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )
        // No global settings.json — plugin is only project-scoped

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        // Should complete without error — PluginCheck should find the plugin
        // in project-scoped settings.local.json
        try runner.run()
    }

    // MARK: - External settings checks resolve project scope (issue #354)

    /// Builds an external pack whose only check is a declarative `hookEventExists`.
    ///
    /// The adapter must be constructed with a sandboxed shell: `convertDoctorCheck` passes
    /// `shell.environment` to the factory, not the runner's environment, so a default shell would
    /// make the check read the real `~/.claude/settings.json`.
    private func externalHookCheckPack(home: URL, packPath: URL) -> ExternalPackAdapter {
        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "external-pack",
            displayName: "External Pack",
            description: "Pack with a declarative hook event check",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: [
                ExternalDoctorCheckDefinition(
                    type: .hookEventExists,
                    name: "SessionStart hook",
                    section: "Hooks",
                    command: nil, args: nil, path: nil, pattern: nil,
                    scope: nil, fixCommand: nil, fixScript: nil,
                    event: "SessionStart",
                    keyPath: nil, expectedValue: nil, isOptional: false
                ),
            ],
            ignore: nil
        )
        return ExternalPackAdapter(
            manifest: manifest,
            packPath: packPath,
            shell: ShellRunner(environment: Environment(home: home)),
            output: CLIOutput(colorsEnabled: false)
        )
    }

    @Test("declarative hookEventExists resolves the project settings.local.json")
    func externalHookCheckFindsProjectScopedEvent() throws {
        let (home, project) = try makeSandboxProject(label: "runner-ext-hook-project")
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = TechPackRegistry(packs: [externalHookCheckPack(home: home, packPath: home)])
        var state = try ProjectState(projectRoot: project)
        state.recordPack("external-pack")
        try state.save()

        // Project-scoped sync writes hook entries here — and nowhere else.
        let projectSettings = """
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "mcs check-updates --hook" }] }
            ]
          }
        }
        """
        try projectSettings.write(
            to: project.appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent(Constants.FileNames.settingsLocal),
            atomically: true, encoding: .utf8
        )
        // No global settings.json — before this fix the check read only that file and failed.

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        let summary = try runner.run()
        #expect(summary.issues == 0)
    }

    @Test("declarative hookEventExists still fails when the event is registered nowhere")
    func externalHookCheckFailsWhenEventMissing() throws {
        let (home, project) = try makeSandboxProject(label: "runner-ext-hook-missing")
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = TechPackRegistry(packs: [externalHookCheckPack(home: home, packPath: home)])
        var state = try ProjectState(projectRoot: project)
        state.recordPack("external-pack")
        try state.save()

        try "{}".write(
            to: project.appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent(Constants.FileNames.settingsLocal),
            atomically: true, encoding: .utf8
        )

        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        let summary = try runner.run()
        #expect(summary.issues > 0)
    }

    @Test("runner resolves colliding hook destinations via collision resolver")
    func collidingHookDestinationsResolvedByDoctor() throws {
        let (home, project) = try makeSandboxProject(label: "runner-collision")
        defer { try? FileManager.default.removeItem(at: home) }

        // Two packs declaring the same hook destination "lint.sh"
        let hookComponentA = ComponentDefinition(
            id: "pack-a.lint",
            displayName: "Lint Hook",
            description: "Lint hook from pack A",
            type: .hookFile,
            packIdentifier: "pack-a",
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/dummy-a"),
                destination: "lint.sh",
                fileType: .hook
            )
        )
        let hookComponentB = ComponentDefinition(
            id: "pack-b.lint",
            displayName: "Lint Hook",
            description: "Lint hook from pack B",
            type: .hookFile,
            packIdentifier: "pack-b",
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/dummy-b"),
                destination: "lint.sh",
                fileType: .hook
            )
        )

        let packA = MockTechPack(
            identifier: "pack-a", displayName: "Pack A",
            components: [hookComponentA]
        )
        let packB = MockTechPack(
            identifier: "pack-b", displayName: "Pack B",
            components: [hookComponentB]
        )
        let registry = TechPackRegistry(packs: [packA, packB])

        // Write hook files at the namespaced paths (as configure would)
        let hooksDir = project.appendingPathComponent(".claude/hooks")
        let namespacedDirA = hooksDir.appendingPathComponent("pack-a")
        let namespacedDirB = hooksDir.appendingPathComponent("pack-b")
        try FileManager.default.createDirectory(at: namespacedDirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: namespacedDirB, withIntermediateDirectories: true)
        try "#!/bin/bash\necho a".write(
            to: namespacedDirA.appendingPathComponent("lint.sh"),
            atomically: true, encoding: .utf8
        )
        try "#!/bin/bash\necho b".write(
            to: namespacedDirB.appendingPathComponent("lint.sh"),
            atomically: true, encoding: .utf8
        )

        // Record both packs in project state with namespaced file paths
        var state = try ProjectState(projectRoot: project)
        state.recordPack("pack-a")
        state.recordPack("pack-b")
        state.setArtifacts(
            PackArtifactRecord(files: [".claude/hooks/pack-a/lint.sh"]),
            for: "pack-a"
        )
        state.setArtifacts(
            PackArtifactRecord(files: [".claude/hooks/pack-b/lint.sh"]),
            for: "pack-b"
        )
        try state.save()

        // Doctor should pass — the collision resolver namespaces the destinations
        // so FileExistsCheck looks at pack-a/lint.sh and pack-b/lint.sh (which exist)
        // rather than the flat lint.sh (which does not exist)
        var runner = makeRunner(home: home, projectRoot: project, registry: registry)
        try runner.run()
    }

    @Test("MCPServerCheck passes via walk-up when project root is a subdirectory of git root")
    func mcpCheckWalksUpToGitRoot() throws {
        let home = try makeGlobalTmpDir(label: "runner-walkup")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        // Git root at home/my-repo, project root at home/my-repo/packages/lib
        let gitRoot = home.appendingPathComponent("my-repo")
        let subProject = gitRoot.appendingPathComponent("packages/lib")
        try FileManager.default.createDirectory(
            at: gitRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: subProject.appendingPathComponent(Constants.FileNames.claudeDirectory),
            withIntermediateDirectories: true
        )

        // Pack with an MCP component
        let mcpComponent = ComponentDefinition(
            id: "test-pack.my-mcp",
            displayName: "My MCP",
            description: "Test MCP server",
            type: .mcpServer,
            packIdentifier: "test-pack",
            dependencies: [],
            isRequired: true,
            installAction: .mcpServer(MCPServerConfig(
                name: "my-mcp", command: "npx", args: ["-y", "my-mcp"], env: [:]
            ))
        )
        let pack = MockTechPack(
            identifier: "test-pack",
            displayName: "Test Pack",
            components: [mcpComponent]
        )
        let registry = TechPackRegistry(packs: [pack])

        // Record pack in project state at the subdirectory root
        var state = try ProjectState(projectRoot: subProject)
        state.recordPack("test-pack")
        state.setArtifacts(
            PackArtifactRecord(mcpServers: [MCPServerRef(name: "my-mcp", scope: "local")]),
            for: "test-pack"
        )
        try state.save()

        // Write ~/.claude.json with the server keyed at the git root (as Claude CLI does)
        let claudeJSON: [String: Any] = [
            "projects": [
                gitRoot.path: [
                    "mcpServers": [
                        "my-mcp": ["command": "npx", "args": ["-y", "my-mcp"]],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        // DoctorRunner with projectRoot at the subdirectory
        var runner = makeRunner(home: home, projectRoot: subProject, registry: registry)
        try runner.run()
    }
}

// MARK: - Summary Warning-Count Tests

/// Regression coverage for the doctor summary warning tally. The count must
/// include warnings emitted *outside* the check loop (collision renames,
/// unregistered packs), which previously printed but were never counted.
///
/// Assertions are deltas: ambient checks (e.g. ProjectIndexCheck) may add
/// warnings of their own, so each test compares two otherwise-identical runs
/// that differ only by the single side-channel warning under test.
struct DoctorSummaryWarningCountTests {
    /// The injected counter is shared across CLIOutput copies, so a warning
    /// emitted through any copy (e.g. the one handed to the collision resolver)
    /// is tallied. This is the mechanism the doctor summary relies on.
    @Test("WarningCounter is shared across CLIOutput value copies")
    func warningCounterSharedAcrossCopies() {
        let counter = WarningCounter()
        let output = CLIOutput(colorsEnabled: false, warningCounter: counter)
        let copy = output // value-type copy, same counter instance

        #expect(counter.count == 0)
        output.warn("first")
        copy.warn("second")
        #expect(counter.count == 2)
    }

    @Test("Skill colliding with a pre-existing unmanaged file is counted in the summary")
    func collisionWarningCounted() throws {
        let (home, project) = try makeSandboxProject(label: "warncount-collision")
        defer { try? FileManager.default.removeItem(at: home) }

        // A pack whose skill targets destination "my-skill".
        let skillSource = home.appendingPathComponent("pack-my-skill")
        try FileManager.default.createDirectory(at: skillSource, withIntermediateDirectories: true)
        try "managed".write(
            to: skillSource.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        let component = ComponentDefinition(
            id: "test-pack.my-skill",
            displayName: "my-skill",
            description: "Skill",
            type: .skill,
            packIdentifier: "test-pack",
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(source: skillSource, destination: "my-skill", fileType: .skill)
        )
        let pack = MockTechPack(
            identifier: "test-pack", displayName: "Test Pack", components: [component]
        )
        let registry = TechPackRegistry(packs: [pack])

        // Configure the pack (no artifacts → nothing tracked at the destination).
        var state = try ProjectState(projectRoot: project)
        state.recordPack("test-pack")
        try state.save()

        // Baseline: no pre-existing file at the destination → no collision.
        var baselineRunner = makeRunner(home: home, projectRoot: project, registry: registry)
        let baseline = try baselineRunner.run()

        // Now plant a pre-existing UNMANAGED skill at the same destination.
        let existingSkill = project.appendingPathComponent(".claude/skills/my-skill")
        try FileManager.default.createDirectory(at: existingSkill, withIntermediateDirectories: true)
        try "user content".write(
            to: existingSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        var collisionRunner = makeRunner(home: home, projectRoot: project, registry: registry)
        let withCollision = try collisionRunner.run()

        // The only difference between the two runs is the collision warning.
        #expect(withCollision.warnings == baseline.warnings + 1)
    }

    @Test("Unregistered --pack filter warning is counted in the summary")
    func unregisteredPackWarningCounted() throws {
        let (home, project) = try makeSandboxProject(label: "warncount-unregistered")
        defer { try? FileManager.default.removeItem(at: home) }

        let pack = MockTechPack(identifier: "test-pack", displayName: "Test Pack")
        let registry = TechPackRegistry(packs: [pack])

        var state = try ProjectState(projectRoot: project)
        state.recordPack("test-pack")
        try state.save()

        // Baseline: filter to the registered pack only.
        var baselineRunner = makeRunner(
            home: home, projectRoot: project, registry: registry, packFilter: "test-pack"
        )
        let baseline = try baselineRunner.run()

        // Add an unregistered pack id to the filter — same checks, plus one
        // "not registered" advisory warning.
        var ghostRunner = makeRunner(
            home: home, projectRoot: project, registry: registry, packFilter: "test-pack,ghost-pack"
        )
        let withGhost = try ghostRunner.run()

        #expect(withGhost.warnings == baseline.warnings + 1)
    }

    /// `--pack "ios, swift"` is a natural thing to type. Without trimming, the second id carries a
    /// leading space, matches no pack, and the run reports it as unregistered instead of checking it.
    @Test("--pack filter tolerates whitespace around comma-separated ids")
    func packFilterTrimsWhitespace() throws {
        let (home, project) = try makeSandboxProject(label: "packfilter-whitespace")
        defer { try? FileManager.default.removeItem(at: home) }

        let registry = TechPackRegistry(packs: [
            MockTechPack(identifier: "pack-a", displayName: "Pack A"),
            MockTechPack(identifier: "pack-b", displayName: "Pack B"),
        ])

        var state = try ProjectState(projectRoot: project)
        state.recordPack("pack-a")
        state.recordPack("pack-b")
        try state.save()

        var tightRunner = makeRunner(
            home: home, projectRoot: project, registry: registry, packFilter: "pack-a,pack-b"
        )
        let tight = try tightRunner.run()

        var spacedRunner = makeRunner(
            home: home, projectRoot: project, registry: registry, packFilter: " pack-a , pack-b "
        )
        let spaced = try spacedRunner.run()

        // Identical filters spelled differently must produce identical runs — in particular no
        // extra "not registered" advisory for a space-prefixed id.
        #expect(spaced.warnings == tight.warnings)
        #expect(spaced.passed == tight.passed)
        #expect(spaced.issues == tight.issues)
    }
}
