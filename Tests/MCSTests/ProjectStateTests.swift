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

    @Test("isEmpty includes new fields")
    func isEmptyIncludesNewFields() {
        var record = PackArtifactRecord()
        #expect(record.isEmpty)

        record.brewPackages = ["swiftlint"]
        #expect(!record.isEmpty)

        record.brewPackages = []
        record.plugins = ["some-plugin"]
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
}
