import Foundation
@testable import mcs
import Testing

// MARK: - Stub TechPack for testing

/// Minimal TechPack stub that declares specific components for ref counting tests.
private struct StubTechPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String
    let components: [ComponentDefinition]
    var templates: [TemplateContribution] {
        []
    }

    var templateSectionIdentifiers: [String] {
        []
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}

/// Creates a ComponentDefinition with a brew install action.
private func brewComponent(id: String, pack: String, package: String) -> ComponentDefinition {
    ComponentDefinition(
        id: id,
        displayName: package,
        description: "Brew: \(package)",
        type: .brewPackage,
        packIdentifier: pack,
        dependencies: [],
        isRequired: true,
        installAction: .brewInstall(package: package)
    )
}

/// Creates a ComponentDefinition with a plugin install action.
private func pluginComponent(id: String, pack: String, pluginName: String) -> ComponentDefinition {
    ComponentDefinition(
        id: id,
        displayName: pluginName,
        description: "Plugin: \(pluginName)",
        type: .plugin,
        packIdentifier: pack,
        dependencies: [],
        isRequired: true,
        installAction: .plugin(name: pluginName)
    )
}

struct ResourceRefCounterTests {
    private func makeTmpHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-refcount-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Create ~/.mcs directory
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".mcs"),
            withIntermediateDirectories: true
        )
        return dir
    }

    /// Write a global-state.json with configured packs and artifacts.
    private func writeGlobalState(
        home: URL,
        packs: [(id: String, artifacts: PackArtifactRecord)]
    ) throws {
        let env = Environment(home: home)
        var state = try ProjectState(stateFile: env.globalStateFile)
        for (id, artifacts) in packs {
            state.recordPack(id)
            state.setArtifacts(artifacts, for: id)
        }
        try state.save()
    }

    /// Write projects.yaml with the given entries.
    private func writeIndex(
        home: URL,
        entries: [(path: String, packs: [String])]
    ) throws {
        let env = Environment(home: home)
        let indexFile = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        for entry in entries {
            indexFile.upsert(projectPath: entry.path, packIDs: entry.packs, in: &data)
        }
        try indexFile.save(data)
    }

    /// Create a .mcs-project file at a project path with configured packs.
    private func writeProjectState(
        projectRoot: URL,
        packs: [String]
    ) throws {
        var state = try ProjectState(projectRoot: projectRoot)
        for id in packs {
            state.recordPack(id)
        }
        try state.save()
    }

    // MARK: - Brew package owned by one scope only → safe to remove

    @Test("Brew package only in removing scope is safe to remove")
    func brewSingleScope() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Global state: pack-a owns "swiftlint"
        try writeGlobalState(home: home, packs: [
            ("pack-a", PackArtifactRecord(brewPackages: ["swiftlint"])),
        ])

        // No project entries referencing pack-a
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.swiftlint", pack: "pack-a", package: "swiftlint")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        let result = counter.isStillNeeded(
            .brewPackage("swiftlint"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(!result, "Should be safe to remove — no other scope references it")
    }

    // MARK: - Plugin needed by two projects → keep

    @Test("Plugin needed by another project is kept")
    func pluginTwoProjects() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Create two real project directories
        let projectA = home.appendingPathComponent("project-a")
        let projectB = home.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

        // Both projects use pack-x which declares the plugin
        try writeProjectState(projectRoot: projectA, packs: ["pack-x"])
        try writeProjectState(projectRoot: projectB, packs: ["pack-x"])

        // Empty global state (no global packs)
        try writeGlobalState(home: home, packs: [])

        // Index tracks both projects
        try writeIndex(home: home, entries: [
            (projectA.path, ["pack-x"]),
            (projectB.path, ["pack-x"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-x",
                displayName: "Pack X",
                description: "Test",
                components: [
                    pluginComponent(
                        id: "x.plugin", pack: "pack-x",
                        pluginName: "anthropics/claude-plugins-official/pr-review-toolkit"
                    ),
                ]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing from project-a — project-b still needs it
        let result = counter.isStillNeeded(
            .plugin("anthropics/claude-plugins-official/pr-review-toolkit"),
            excludingScope: projectA.path,
            excludingPack: "pack-x"
        )

        #expect(result, "Should be kept — project-b still uses pack-x which declares the plugin")
    }

    // MARK: - Same pack in global + project → both counted

    @Test("Same pack globally and per-project keeps resource when removing from project")
    func dualScopeKeepOnProjectRemoval() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        let projectA = home.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try writeProjectState(projectRoot: projectA, packs: ["pack-z"])

        // Global state: pack-z owns "jq"
        try writeGlobalState(home: home, packs: [
            ("pack-z", PackArtifactRecord(brewPackages: ["jq"])),
        ])

        // Index: both global and project-a use pack-z
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-z"]),
            (projectA.path, ["pack-z"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-z",
                displayName: "Pack Z",
                description: "Test",
                components: [brewComponent(id: "z.jq", pack: "pack-z", package: "jq")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing from project-a — global still owns it in artifacts
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: projectA.path,
            excludingPack: "pack-z"
        )

        #expect(result, "Should be kept — global scope still owns jq via pack-z")
    }

    // MARK: - Pre-existing resource (not in any artifact record) → never touched

    @Test("Resource not in any artifact record is not flagged as still needed")
    func preExistingNotOwned() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Global state: pack-a has empty artifacts (nothing owned)
        try writeGlobalState(home: home, packs: [
            ("pack-a", PackArtifactRecord()),
        ])

        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
        ])

        // Registry has pack-a declaring jq, but artifact record is empty (pre-existing)
        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.jq", pack: "pack-a", package: "jq")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // No other scope exists besides the one being removed
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(!result, "Should not be kept — no other scope references it")
    }

    // MARK: - Stale project path → not counted as reference

    @Test("Stale project path is not counted as reference")
    func staleProjectNotCounted() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Empty global state
        try writeGlobalState(home: home, packs: [])

        // Index includes a non-existent project path
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
            ("/nonexistent/project/path", ["pack-a"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.swiftlint", pack: "pack-a", package: "swiftlint")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing from global — the stale project should NOT count as a reference
        let result = counter.isStillNeeded(
            .brewPackage("swiftlint"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(!result, "Should not be kept — stale project paths don't count as references")
    }

    // MARK: - Unloadable pack → conservative (counts as reference)

    @Test("Unloadable pack from registry is treated conservatively")
    func unloadablePack() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        let projectB = home.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        try writeProjectState(projectRoot: projectB, packs: ["unknown-pack"])

        // Empty global state
        try writeGlobalState(home: home, packs: [])

        // Index: project-b uses "unknown-pack" which is NOT in the registry
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
            (projectB.path, ["unknown-pack"]),
        ])

        // Registry does NOT include "unknown-pack"
        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.jq", pack: "pack-a", package: "jq")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing from global — project-b has an unloadable pack, should be conservative
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(result, "Should be kept — unloadable pack is treated conservatively")
    }

    // MARK: - Index read failure → conservative

    @Test("Missing index file returns conservative result")
    func missingIndexConservative() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Write valid global state but NO projects.yaml
        try writeGlobalState(home: home, packs: [])
        // Don't write any index file — load() returns empty data, not an error

        let registry = TechPackRegistry(packs: [])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // With no global artifacts and no index entries, the result should be "not needed"
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(!result, "No references anywhere — safe to remove")
    }

    // MARK: - Global state unreadable → conservative

    @Test("Unreadable global state is conservative")
    func unreadableGlobalState() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Write invalid JSON as global state
        let invalidJSON = Data("not json".utf8)
        try invalidJSON.write(to: env.globalStateFile)

        try writeIndex(home: home, entries: [])

        let registry = TechPackRegistry(packs: [])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Global state is corrupt — should be conservative
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(result, "Should be kept — can't read global state, conservative fallback")
    }

    // MARK: - Different packs sharing same brew package

    @Test("Two different packs in different scopes sharing brew package → kept")
    func differentPacksSameBrew() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        let projectA = home.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try writeProjectState(projectRoot: projectA, packs: ["pack-b"])

        // Global scope has pack-a owning "jq"
        try writeGlobalState(home: home, packs: [
            ("pack-a", PackArtifactRecord(brewPackages: ["jq"])),
        ])

        // pack-b in project also declares jq
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
            (projectA.path, ["pack-b"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.jq", pack: "pack-a", package: "jq")]
            ),
            StubTechPack(
                identifier: "pack-b",
                displayName: "Pack B",
                description: "Test",
                components: [brewComponent(id: "b.jq", pack: "pack-b", package: "jq")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing pack-a from global — pack-b in project-a also declares jq
        let result = counter.isStillNeeded(
            .brewPackage("jq"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(result, "Should be kept — pack-b in project-a also declares jq")
    }

    // MARK: - Plugin bare name matching

    @Test("Plugin matching works across different full-name formats")
    func pluginBareNameMatching() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        // Global state: pack-a owns bare name, pack-b owns @ format
        // PluginRef uses @ as separator: "name@repo/path"
        try writeGlobalState(home: home, packs: [
            ("pack-a", PackArtifactRecord(plugins: ["pr-review-toolkit"])),
            ("pack-b", PackArtifactRecord(plugins: ["pr-review-toolkit@anthropics/claude-plugins-official"])),
        ])

        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a", "pack-b"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [
                    pluginComponent(id: "a.plugin", pack: "pack-a", pluginName: "pr-review-toolkit"),
                ]
            ),
            StubTechPack(
                identifier: "pack-b",
                displayName: "Pack B",
                description: "Test",
                components: [
                    pluginComponent(
                        id: "b.plugin", pack: "pack-b",
                        pluginName: "pr-review-toolkit@anthropics/claude-plugins-official"
                    ),
                ]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        // Removing pack-a — pack-b also has the same plugin (different format)
        let result = counter.isStillNeeded(
            .plugin("pr-review-toolkit"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(result, "Should be kept — pack-b has same plugin in different format")
    }

    // MARK: - No other scopes at all → safe to remove

    @Test("No other scopes means safe to remove")
    func noOtherScopes() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        try writeGlobalState(home: home, packs: [
            ("pack-a", PackArtifactRecord(brewPackages: ["xcbeautify"])),
        ])

        // Only the global scope exists
        try writeIndex(home: home, entries: [
            (ProjectIndex.globalSentinel, ["pack-a"]),
        ])

        let registry = TechPackRegistry(packs: [
            StubTechPack(
                identifier: "pack-a",
                displayName: "Pack A",
                description: "Test",
                components: [brewComponent(id: "a.xcbeautify", pack: "pack-a", package: "xcbeautify")]
            ),
        ])

        let counter = ResourceRefCounter(
            environment: env,
            output: CLIOutput(),
            registry: registry
        )

        let result = counter.isStillNeeded(
            .brewPackage("xcbeautify"),
            excludingScope: ProjectIndex.globalSentinel,
            excludingPack: "pack-a"
        )

        #expect(!result, "No other scope references it — safe to remove")
    }
}
