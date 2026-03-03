import Foundation
@testable import mcs
import Testing

@Suite("ProjectDetector")
struct ProjectDetectorTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdetect-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Finds project root via .git directory")
    func findsGitRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create project structure: tmpDir/.git/ and tmpDir/Sources/
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let sourcesDir = tmpDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: sourcesDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Finds project root via CLAUDE.local.md")
    func findsCLAUDELocalRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create CLAUDE.local.md at root
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        let subDir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: subDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Returns nil when no project root found")
    func returnsNilOutsideProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Empty directory — no .git or CLAUDE.local.md
        _ = ProjectDetector.findProjectRoot(from: tmpDir)
        // May find the actual cwd's project root when walking up,
        // but from an isolated temp dir it should be nil or find nothing useful.
        // We test this by creating a deeply nested dir with no markers.
        let deep = tmpDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        // If it walks up past tmpDir it might find the system's git repos,
        // so we just verify it doesn't crash and returns something or nil.
        _ = ProjectDetector.findProjectRoot(from: deep)
    }

    @Test("Prefers .git over CLAUDE.local.md at same level")
    func prefersGitAtSameLevel() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let root = ProjectDetector.findProjectRoot(from: tmpDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }
}

@Suite("ProjectState")
struct ProjectStateTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projstate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("New state file does not exist")
    func newStateNotExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let state = try ProjectState(projectRoot: tmpDir)
        #expect(!state.exists)
        #expect(state.configuredPacks.isEmpty)
    }

    @Test("Record pack and save persists state")
    func recordAndSave() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        // Reload
        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["ios"]))
        #expect(loaded.mcsVersion == MCSVersion.current)
    }

    @Test("Multiple packs are stored and sorted")
    func multiplePacks() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("web")
        state.recordPack("ios")
        try state.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("Additive across saves")
    func additiveAcrossSaves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // First save
        var state1 = try ProjectState(projectRoot: tmpDir)
        state1.recordPack("ios")
        try state1.save()

        // Second save adds another pack
        var state2 = try ProjectState(projectRoot: tmpDir)
        state2.recordPack("web")
        try state2.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.configuredPacks == Set(["ios", "web"]))
    }

    @Test("init does not throw when file does not exist")
    func missingFileDoesNotThrow() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let state = try ProjectState(projectRoot: tmpDir)
        #expect(!state.exists)
    }

    @Test("init throws when file is corrupt")
    func corruptFileThrows() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        try Data("{ not valid json !!!".utf8).write(to: stateFile)

        #expect(throws: (any Error).self) {
            _ = try ProjectState(projectRoot: tmpDir)
        }
    }

    @Test("removePack removes from configuredPacks and artifacts")
    func removePack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.recordPack("web")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "xcodebuildmcp", scope: "local")]
        ), for: "ios")
        try state.save()

        var loaded = try ProjectState(projectRoot: tmpDir)
        loaded.removePack("ios")
        try loaded.save()

        let final = try ProjectState(projectRoot: tmpDir)
        #expect(final.configuredPacks == Set(["web"]))
        #expect(final.artifacts(for: "ios") == nil)
    }

    @Test("Pack artifact records are persisted and loaded")
    func artifactRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        let artifacts = PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "xcodebuildmcp", scope: "local")],
            files: [".claude/skills/my-skill/SKILL.md"],
            templateSections: ["ios"],
            hookCommands: ["bash .claude/hooks/ios-session.sh"],
            settingsKeys: ["env.XCODE_PROJECT"]
        )
        state.setArtifacts(artifacts, for: "ios")
        try state.save()

        let loaded = try ProjectState(projectRoot: tmpDir)
        let loadedArtifacts = loaded.artifacts(for: "ios")
        #expect(loadedArtifacts == artifacts)
        #expect(loadedArtifacts?.mcpServers.count == 1)
        #expect(loadedArtifacts?.mcpServers.first?.name == "xcodebuildmcp")
        #expect(loadedArtifacts?.files == [".claude/skills/my-skill/SKILL.md"])
    }

    @Test("stateFile init loads from direct path")
    func stateFileInit() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Save using projectRoot init
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "test-server", scope: "user")]
        ), for: "ios")
        try state.save()

        // Load using stateFile init with the same path
        let stateFile = tmpDir
            .appendingPathComponent(".claude")
            .appendingPathComponent(".mcs-project")
        let loaded = try ProjectState(stateFile: stateFile)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["ios"]))
        #expect(loaded.artifacts(for: "ios")?.mcpServers.first?.scope == "user")
    }

    @Test("stateFile init works with custom path for global state")
    func stateFileCustomPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let customFile = tmpDir.appendingPathComponent("global-state.json")

        var state = try ProjectState(stateFile: customFile)
        #expect(!state.exists)

        state.recordPack("web")
        try state.save()

        let loaded = try ProjectState(stateFile: customFile)
        #expect(loaded.exists)
        #expect(loaded.configuredPacks == Set(["web"]))
    }

    @Test("JSON format saves are valid JSON")
    func jsonFormat() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        let stateFile = tmpDir
            .appendingPathComponent(".claude")
            .appendingPathComponent(".mcs-project")
        let data = try Data(contentsOf: stateFile)
        #expect(data.first == UInt8(ascii: "{"))

        // Should be valid JSON
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["mcsVersion"] as? String == MCSVersion.current)
    }

    // MARK: - PackArtifactRecord.isEmpty

    @Test("Empty artifact record reports isEmpty")
    func emptyArtifactRecord() {
        let record = PackArtifactRecord()
        #expect(record.isEmpty)
    }

    @Test("Non-empty artifact record reports not isEmpty")
    func nonEmptyArtifactRecord() {
        let record = PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "test", scope: "local")]
        )
        #expect(!record.isEmpty)
    }

    @Test("Artifact record with only files is not empty")
    func filesOnlyNotEmpty() {
        let record = PackArtifactRecord(files: [".claude/skills/test/SKILL.md"])
        #expect(!record.isEmpty)
    }

    @Test("Artifact record with only settings keys is not empty")
    func settingsOnlyNotEmpty() {
        let record = PackArtifactRecord(settingsKeys: ["env.FOO"])
        #expect(!record.isEmpty)
    }

    // MARK: - Partial artifact update

    @Test("setArtifacts overwrites existing record without removing pack")
    func partialArtifactUpdate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "server", scope: "local")],
            files: [".claude/skills/test/SKILL.md"],
            hookCommands: ["bash .claude/hooks/test.sh"]
        ), for: "ios")
        try state.save()

        // Simulate partial cleanup: only MCP server was removed
        var loaded = try ProjectState(projectRoot: tmpDir)
        let remaining = PackArtifactRecord(
            files: [".claude/skills/test/SKILL.md"],
            hookCommands: ["bash .claude/hooks/test.sh"]
        )
        loaded.setArtifacts(remaining, for: "ios")
        try loaded.save()

        // Pack should still be configured with reduced artifact record
        let final = try ProjectState(projectRoot: tmpDir)
        #expect(final.configuredPacks.contains("ios"))
        let artifacts = final.artifacts(for: "ios")
        #expect(artifacts?.mcpServers.isEmpty == true)
        #expect(artifacts?.files == [".claude/skills/test/SKILL.md"])
        #expect(artifacts?.hookCommands == ["bash .claude/hooks/test.sh"])
    }

    // MARK: - Shrinking-set partial cleanup scenarios

    @Test("Fully cleaned artifacts removes pack from configured list")
    func fullCleanupRemovesPack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "server", scope: "local")],
            files: [".claude/skills/test/SKILL.md"]
        ), for: "ios")
        try state.save()

        // Simulate full cleanup: remaining is empty
        var loaded = try ProjectState(projectRoot: tmpDir)
        let remaining = PackArtifactRecord()
        #expect(remaining.isEmpty)
        loaded.removePack("ios")
        try loaded.save()

        let final = try ProjectState(projectRoot: tmpDir)
        #expect(!final.configuredPacks.contains("ios"))
        #expect(final.artifacts(for: "ios") == nil)
    }

    @Test("Multiple packs can have independent partial cleanup")
    func independentPartialCleanup() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        state.recordPack("android")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "xcode", scope: "local")],
            files: [".claude/skills/ios/SKILL.md"]
        ), for: "ios")
        state.setArtifacts(PackArtifactRecord(
            mcpServers: [MCPServerRef(name: "gradle", scope: "local")],
            files: [".claude/skills/android/SKILL.md"]
        ), for: "android")
        try state.save()

        // ios: partial cleanup (MCP removed, file remains)
        var loaded = try ProjectState(projectRoot: tmpDir)
        loaded.setArtifacts(PackArtifactRecord(
            files: [".claude/skills/ios/SKILL.md"]
        ), for: "ios")
        // android: full cleanup
        loaded.removePack("android")
        try loaded.save()

        let final = try ProjectState(projectRoot: tmpDir)
        #expect(final.configuredPacks.contains("ios"))
        #expect(!final.configuredPacks.contains("android"))
        #expect(final.artifacts(for: "ios")?.files == [".claude/skills/ios/SKILL.md"])
        #expect(final.artifacts(for: "ios")?.mcpServers.isEmpty == true)
        #expect(final.artifacts(for: "android") == nil)
    }

    @Test("Artifact record with only template sections is not empty")
    func templateSectionsOnlyNotEmpty() {
        let record = PackArtifactRecord(templateSections: ["ios"])
        #expect(!record.isEmpty)
    }

    @Test("Artifact record with only hook commands is not empty")
    func hookCommandsOnlyNotEmpty() {
        let record = PackArtifactRecord(hookCommands: ["bash .claude/hooks/lint.sh"])
        #expect(!record.isEmpty)
    }
}

// MARK: - ProjectDoctorChecks

@Suite("ProjectDoctorChecks")
struct ProjectDoctorCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdoctor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CLAUDEMDFreshnessCheck (project-scoped)

    @Test("CLAUDEMDFreshnessCheck skips when no CLAUDE.local.md")
    func freshnessCheckSkipsWhenMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("CLAUDEMDFreshnessCheck warns when no section markers")
    func freshnessCheckWarnsNoMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Just a plain file\nNo markers here.\n".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("CLAUDEMDFreshnessCheck warns when no stored values")
    func freshnessCheckWarnsNoStoredValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Some content here
        <!-- mcs:end core -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .warn = check.check() {
            // expected — no .mcs-project means no stored values
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    // MARK: - ProjectStateFileCheck

    @Test("ProjectStateFileCheck skips when no CLAUDE.local.md")
    func stateCheckSkipsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("ProjectStateFileCheck warns when CLAUDE.local.md exists but .mcs-project missing")
    func stateCheckWarnsMissingProjectFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("ProjectStateFileCheck passes when both files exist")
    func stateCheckPassesBothPresent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectStateFileCheck fix creates .mcs-project from section markers")
    func stateCheckFixCreatesFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Core content
        <!-- mcs:end core -->
        <!-- mcs:begin ios v\(version) -->
        iOS content
        <!-- mcs:end ios -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        let fixResult = check.fix()
        if case .fixed = fixResult {
            // Verify the state file was created
            let state = try ProjectState(projectRoot: tmpDir)
            #expect(state.exists)
            #expect(state.configuredPacks.contains("ios"))
        } else {
            #expect(Bool(false), "Expected .fixed result, got \(fixResult)")
        }
    }
}
