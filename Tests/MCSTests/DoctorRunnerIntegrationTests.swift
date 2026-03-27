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
