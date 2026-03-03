import Foundation
@testable import mcs
import Testing

@Suite("PackRegistryFile")
struct PackRegistryFileTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-registry-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleEntry(
        identifier: String = "test-pack"
    ) -> PackRegistryFile.PackEntry {
        PackRegistryFile.PackEntry(
            identifier: identifier,
            displayName: "Test Pack",
            author: nil,
            sourceURL: "https://github.com/user/\(identifier).git",
            ref: "v1.0.0",
            commitSHA: "abc123def456",
            localPath: identifier,
            addedAt: "2026-02-22T00:00:00Z",
            trustedScriptHashes: ["scripts/setup.sh": "sha256hash"],
            isLocal: nil
        )
    }

    private func sampleLocalEntry(
        identifier: String = "local-pack",
        localPath: String = "/Users/dev/local-pack"
    ) -> PackRegistryFile.PackEntry {
        PackRegistryFile.PackEntry(
            identifier: identifier,
            displayName: "Local Pack",
            author: nil,
            sourceURL: localPath,
            ref: nil,
            commitSHA: "local",
            localPath: localPath,
            addedAt: "2026-01-01T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: true
        )
    }

    // MARK: - Load from missing / empty file

    @Test("Load from missing file returns empty registry")
    func loadMissingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = PackRegistryFile(path: tmpDir.appendingPathComponent("missing.yaml"))
        let data = try registry.load()
        #expect(data.packs.isEmpty)
    }

    @Test("Load from empty file returns empty registry")
    func loadEmptyFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("empty.yaml")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let registry = PackRegistryFile(path: file)
        let data = try registry.load()
        #expect(data.packs.isEmpty)
    }

    // MARK: - Save and load round-trip

    @Test("Save and load round-trip preserves pack entries")
    func saveLoadRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("packs.yaml")
        let registry = PackRegistryFile(path: file)

        var data = PackRegistryFile.RegistryData()
        let entry = sampleEntry()
        registry.register(entry, in: &data)
        try registry.save(data)

        let loaded = try registry.load()
        #expect(loaded.packs.count == 1)
        #expect(loaded.packs[0].identifier == "test-pack")
        #expect(loaded.packs[0].sourceURL == "https://github.com/user/test-pack.git")
        #expect(loaded.packs[0].trustedScriptHashes["scripts/setup.sh"] == "sha256hash")
    }

    @Test("Save creates parent directories if needed")
    func saveCreatesDirectories() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let nested = tmpDir
            .appendingPathComponent("deep")
            .appendingPathComponent("nested")
            .appendingPathComponent("packs.yaml")
        let registry = PackRegistryFile(path: nested)

        let data = PackRegistryFile.RegistryData()
        try registry.save(data)

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: - Register

    @Test("Register adds a new entry")
    func registerNew() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))
        var data = PackRegistryFile.RegistryData()

        registry.register(sampleEntry(identifier: "pack-a"), in: &data)
        #expect(data.packs.count == 1)

        registry.register(sampleEntry(identifier: "pack-b"), in: &data)
        #expect(data.packs.count == 2)
    }

    @Test("Register replaces existing entry with same identifier")
    func registerReplaces() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))
        var data = PackRegistryFile.RegistryData()

        registry.register(sampleEntry(identifier: "pack-a"), in: &data)
        registry.register(sampleEntry(identifier: "pack-a"), in: &data)

        #expect(data.packs.count == 1)
    }

    // MARK: - Remove

    @Test("Remove deletes entry by identifier")
    func removeEntry() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))
        var data = PackRegistryFile.RegistryData()

        registry.register(sampleEntry(identifier: "pack-a"), in: &data)
        registry.register(sampleEntry(identifier: "pack-b"), in: &data)
        #expect(data.packs.count == 2)

        registry.remove(identifier: "pack-a", from: &data)
        #expect(data.packs.count == 1)
        #expect(data.packs[0].identifier == "pack-b")
    }

    @Test("Remove is no-op for unknown identifier")
    func removeUnknown() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))
        var data = PackRegistryFile.RegistryData()

        registry.register(sampleEntry(identifier: "pack-a"), in: &data)
        registry.remove(identifier: "nonexistent", from: &data)
        #expect(data.packs.count == 1)
    }

    // MARK: - Queries

    @Test("Look up pack by identifier")
    func lookupByIdentifier() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))
        var data = PackRegistryFile.RegistryData()

        registry.register(sampleEntry(identifier: "pack-a"), in: &data)
        registry.register(sampleEntry(identifier: "pack-b"), in: &data)

        let found = registry.pack(identifier: "pack-b", in: data)
        #expect(found?.identifier == "pack-b")

        let notFound = registry.pack(identifier: "nonexistent", in: data)
        #expect(notFound == nil)
    }

    // MARK: - Collision Detection

    @Test("No collisions when packs have distinct artifacts")
    func noCollisions() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))

        let existing = PackRegistryFile.CollisionInput(
            identifier: "pack-a",
            mcpServerNames: ["server-a"],
            skillDirectories: ["skill-a"],
            templateSectionIDs: ["pack-a"],
            componentIDs: ["pack-a.comp1"]
        )
        let newPack = PackRegistryFile.CollisionInput(
            identifier: "pack-b",
            mcpServerNames: ["server-b"],
            skillDirectories: ["skill-b"],
            templateSectionIDs: ["pack-b"],
            componentIDs: ["pack-b.comp1"]
        )

        let collisions = registry.detectCollisions(newPack: newPack, existingPacks: [existing])
        #expect(collisions.isEmpty)
    }

    @Test("Detect MCP server name collision")
    func mcpServerCollision() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))

        let existing = PackRegistryFile.CollisionInput(
            identifier: "pack-a",
            mcpServerNames: ["shared-server"],
            skillDirectories: [],
            templateSectionIDs: [],
            componentIDs: []
        )
        let newPack = PackRegistryFile.CollisionInput(
            identifier: "pack-b",
            mcpServerNames: ["shared-server"],
            skillDirectories: [],
            templateSectionIDs: [],
            componentIDs: []
        )

        let collisions = registry.detectCollisions(newPack: newPack, existingPacks: [existing])
        #expect(collisions.count == 1)
        #expect(collisions[0].type == .mcpServerName)
        #expect(collisions[0].artifactName == "shared-server")
        #expect(collisions[0].existingPackIdentifier == "pack-a")
        #expect(collisions[0].newPackIdentifier == "pack-b")
    }

    @Test("Detect multiple collision types")
    func multipleCollisionTypes() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))

        let existing = PackRegistryFile.CollisionInput(
            identifier: "pack-a",
            mcpServerNames: ["server-x"],
            skillDirectories: ["my-skill"],
            templateSectionIDs: ["section-y"],
            componentIDs: []
        )
        let newPack = PackRegistryFile.CollisionInput(
            identifier: "pack-b",
            mcpServerNames: ["server-x"],
            skillDirectories: ["my-skill"],
            templateSectionIDs: ["section-y"],
            componentIDs: []
        )

        let collisions = registry.detectCollisions(newPack: newPack, existingPacks: [existing])
        #expect(collisions.count == 3)

        let types = Set(collisions.map(\.type))
        #expect(types.contains(.mcpServerName))
        #expect(types.contains(.skillDirectory))
        #expect(types.contains(.templateSection))
    }

    // MARK: - Local pack support

    @Test("isLocalPack returns false for git pack entry")
    func isLocalPackFalse() {
        let entry = sampleEntry()
        #expect(!entry.isLocalPack)
    }

    @Test("isLocalPack returns true for local pack entry")
    func isLocalPackTrue() {
        let entry = sampleLocalEntry()
        #expect(entry.isLocalPack)
    }

    @Test("Local pack entry round-trips through save/load")
    func localPackRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("registry.yaml")
        let registry = PackRegistryFile(path: file)

        var data = PackRegistryFile.RegistryData()
        let entry = sampleLocalEntry(identifier: "my-local", localPath: "/Users/dev/my-local")
        registry.register(entry, in: &data)
        try registry.save(data)

        let loaded = try registry.load()
        #expect(loaded.packs.count == 1)
        #expect(loaded.packs[0].isLocalPack)
        #expect(loaded.packs[0].commitSHA == "local")
        #expect(loaded.packs[0].localPath == "/Users/dev/my-local")
    }

    @Test("Decoding registry YAML without isLocal field defaults to non-local")
    func decodeWithoutIsLocal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        packs:
          - identifier: old-pack
            displayName: Old Pack
            version: "1.0.0"
            sourceURL: "https://github.com/user/old-pack.git"
            commitSHA: abc123
            localPath: old-pack
            addedAt: "2026-01-01T00:00:00Z"
            trustedScriptHashes: {}
        """
        let file = tmpDir.appendingPathComponent("registry.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let registry = PackRegistryFile(path: file)
        let data = try registry.load()
        #expect(data.packs.count == 1)
        #expect(!data.packs[0].isLocalPack)
        #expect(data.packs[0].isLocal == nil)
    }

    // MARK: - Author field

    @Test("Pack entry with author round-trips through save/load")
    func authorRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("registry.yaml")
        let registry = PackRegistryFile(path: file)

        let entry = PackRegistryFile.PackEntry(
            identifier: "authored-pack",
            displayName: "Authored Pack",
            author: "Jane Doe",
            sourceURL: "https://github.com/user/authored-pack.git",
            ref: nil,
            commitSHA: "abc123",
            localPath: "authored-pack",
            addedAt: "2026-01-01T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: nil
        )
        var data = PackRegistryFile.RegistryData()
        registry.register(entry, in: &data)
        try registry.save(data)

        let loaded = try registry.load()
        #expect(loaded.packs.count == 1)
        #expect(loaded.packs[0].author == "Jane Doe")
    }

    @Test("Decoding registry YAML without author field defaults to nil")
    func decodeWithoutAuthor() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        packs:
          - identifier: old-pack
            displayName: Old Pack
            version: "1.0.0"
            sourceURL: "https://github.com/user/old-pack.git"
            commitSHA: abc123
            localPath: old-pack
            addedAt: "2026-01-01T00:00:00Z"
            trustedScriptHashes: {}
        """
        let file = tmpDir.appendingPathComponent("registry.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let registry = PackRegistryFile(path: file)
        let data = try registry.load()
        #expect(data.packs.count == 1)
        #expect(data.packs[0].author == nil)
    }

    @Test("resolvedPath returns URL for local pack with absolute path")
    func resolvedPathLocalAbsolute() {
        let entry = sampleLocalEntry()
        let packsDir = URL(fileURLWithPath: "/tmp/packs")
        let result = entry.resolvedPath(packsDirectory: packsDir)
        #expect(result?.path == "/Users/dev/local-pack")
    }

    @Test("resolvedPath returns nil for local pack with empty path")
    func resolvedPathLocalEmpty() {
        let entry = sampleLocalEntry(localPath: "")
        let packsDir = URL(fileURLWithPath: "/tmp/packs")
        #expect(entry.resolvedPath(packsDirectory: packsDir) == nil)
    }

    @Test("resolvedPath returns nil for local pack with relative path")
    func resolvedPathLocalRelative() {
        let entry = sampleLocalEntry(localPath: "relative/path")
        let packsDir = URL(fileURLWithPath: "/tmp/packs")
        #expect(entry.resolvedPath(packsDirectory: packsDir) == nil)
    }

    @Test("resolvedPath uses safePath for git pack")
    func resolvedPathGitPack() {
        let entry = sampleEntry(identifier: "my-git-pack")
        let packsDir = URL(fileURLWithPath: "/tmp/packs")
        let result = entry.resolvedPath(packsDirectory: packsDir)
        #expect(result?.path == "/tmp/packs/my-git-pack")
    }

    @Test("Skip collision check against same identifier")
    func skipSelfCollision() {
        let registry = PackRegistryFile(path: URL(fileURLWithPath: "/tmp/unused"))

        let pack = PackRegistryFile.CollisionInput(
            identifier: "same-pack",
            mcpServerNames: ["server-a"],
            skillDirectories: [],
            templateSectionIDs: [],
            componentIDs: []
        )

        // When updating, the existing list may contain the same pack — should be skipped
        let collisions = registry.detectCollisions(newPack: pack, existingPacks: [pack])
        #expect(collisions.isEmpty)
    }
}
