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
}
