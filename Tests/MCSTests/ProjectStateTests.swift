import Foundation
@testable import mcs
import Testing

struct PackArtifactRecordTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - PackArtifactRecord backward compatibility

    @Test("Decodes existing JSON without brewPackages and plugins fields")
    func backwardCompatDecode() throws {
        let json = """
        {
            "mcpServers": [{"name": "test-server", "scope": "local"}],
            "files": ["skills/test"],
            "templateSections": ["core v1.0.0"],
            "hookCommands": ["bash .claude/hooks/test.sh"],
            "settingsKeys": ["enabledPlugins.test"]
        }
        """
        let data = Data(json.utf8)
        let record = try JSONDecoder().decode(PackArtifactRecord.self, from: data)

        #expect(record.mcpServers.count == 1)
        #expect(record.files == ["skills/test"])
        #expect(record.templateSections == ["core v1.0.0"])
        #expect(record.hookCommands == ["bash .claude/hooks/test.sh"])
        #expect(record.settingsKeys == ["enabledPlugins.test"])
        // New fields default to empty/nil
        #expect(record.brewPackages.isEmpty)
        #expect(record.plugins.isEmpty)
        #expect(record.fileHashes.isEmpty)
        #expect(record.settingsHash == nil)
    }

    @Test("Encodes and decodes new fields correctly")
    func newFieldsRoundTrip() throws {
        var record = PackArtifactRecord()
        record.brewPackages = ["swiftlint", "jq"]
        record.plugins = ["anthropics/claude-plugins-official/pr-review-toolkit"]
        record.fileHashes = [".claude/hooks/test.sh": "abc123"]
        record.settingsHash = "def456"

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PackArtifactRecord.self, from: data)

        #expect(decoded.brewPackages == ["swiftlint", "jq"])
        #expect(decoded.plugins == ["anthropics/claude-plugins-official/pr-review-toolkit"])
        #expect(decoded.fileHashes == [".claude/hooks/test.sh": "abc123"])
        #expect(decoded.settingsHash == "def456")
    }

    @Test("Empty artifact record reports isEmpty")
    func emptyRecordIsEmpty() {
        #expect(PackArtifactRecord().isEmpty)
    }

    /// `isEmpty` gates cleanup-complete: a field it ignores is an artifact left behind on removal.
    @Test("Any single tracked artifact makes the record non-empty", arguments: [
        PackArtifactRecord(mcpServers: [MCPServerRef(name: "test", scope: "local")]),
        PackArtifactRecord(files: [".claude/skills/test/SKILL.md"]),
        PackArtifactRecord(templateSections: ["ios"]),
        PackArtifactRecord(hookCommands: ["bash .claude/hooks/lint.sh"]),
        PackArtifactRecord(settingsKeys: ["env.FOO"]),
        PackArtifactRecord(brewPackages: ["swiftlint"]),
        PackArtifactRecord(plugins: ["some-plugin"]),
        PackArtifactRecord(gitignoreEntries: [".env"]),
        PackArtifactRecord(fileHashes: [".claude/skills/test/SKILL.md": "abc123"]),
    ])
    func singleArtifactIsNotEmpty(record: PackArtifactRecord) {
        #expect(!record.isEmpty)
    }

    // MARK: - ProjectState round-trip

    @Test("Save and load preserves brewPackages and plugins")
    func stateRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stateFile = tmpDir.appendingPathComponent("test-state.json")

        var state = try ProjectState(stateFile: stateFile)
        state.recordPack("test-pack")
        var artifacts = PackArtifactRecord()
        artifacts.brewPackages = ["xcbeautify"]
        artifacts.plugins = ["pr-review-toolkit"]
        artifacts.mcpServers = [MCPServerRef(name: "test", scope: "local")]
        state.setArtifacts(artifacts, for: "test-pack")
        try state.save()

        let loaded = try ProjectState(stateFile: stateFile)
        let loadedArtifacts = loaded.artifacts(for: "test-pack")
        #expect(loadedArtifacts?.brewPackages == ["xcbeautify"])
        #expect(loadedArtifacts?.plugins == ["pr-review-toolkit"])
        #expect(loadedArtifacts?.mcpServers.count == 1)
    }

    @Test("Throws on malformed JSON so callers can surface an actionable message")
    func throwsOnMalformedJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("state.json")
        try "{ not valid json".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try ProjectState(stateFile: file)
        }
    }
}

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
}
