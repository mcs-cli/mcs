import Foundation
@testable import mcs
import Testing

// MARK: - Argument Parsing

struct PackCommandParsingTests {
    // MARK: - AddPack

    @Test("AddPack parses source argument")
    func addPackSource() throws {
        let cmd = try AddPack.parse(["https://github.com/user/repo.git"])
        #expect(cmd.source == "https://github.com/user/repo.git")
    }

    @Test("AddPack parses --ref option")
    func addPackRef() throws {
        let cmd = try AddPack.parse(["user/repo", "--ref", "v1.0.0"])
        #expect(cmd.ref == "v1.0.0")
    }

    @Test("AddPack parses --preview flag")
    func addPackPreview() throws {
        let cmd = try AddPack.parse(["user/repo", "--preview"])
        #expect(cmd.preview == true)
    }

    @Test("AddPack --preview sets skipLock to true")
    func addPackPreviewSkipsLock() throws {
        let cmd = try AddPack.parse(["user/repo", "--preview"])
        #expect(cmd.skipLock == true)
    }

    @Test("AddPack skipLock is false by default")
    func addPackSkipLockDefault() throws {
        let cmd = try AddPack.parse(["user/repo"])
        #expect(cmd.skipLock == false)
    }

    @Test("AddPack defaults: no ref, no preview")
    func addPackDefaults() throws {
        let cmd = try AddPack.parse(["user/repo"])
        #expect(cmd.ref == nil)
        #expect(cmd.preview == false)
    }

    @Test("AddPack parses combined --ref and --preview")
    func addPackCombined() throws {
        let cmd = try AddPack.parse(["user/repo", "--ref", "main", "--preview"])
        #expect(cmd.source == "user/repo")
        #expect(cmd.ref == "main")
        #expect(cmd.preview == true)
    }

    // MARK: - RemovePack

    @Test("RemovePack parses identifier argument")
    func removePackIdentifier() throws {
        let cmd = try RemovePack.parse(["my-pack"])
        #expect(cmd.identifier == "my-pack")
    }

    @Test("RemovePack parses --force flag")
    func removePackForce() throws {
        let cmd = try RemovePack.parse(["my-pack", "--force"])
        #expect(cmd.force == true)
    }

    @Test("RemovePack --force defaults to false")
    func removePackForceDefault() throws {
        let cmd = try RemovePack.parse(["my-pack"])
        #expect(cmd.force == false)
    }

    // MARK: - UpdatePack

    @Test("UpdatePack parses with no arguments (update all)")
    func updatePackAll() throws {
        let cmd = try UpdatePack.parse([])
        #expect(cmd.identifier == nil)
    }

    @Test("UpdatePack parses optional identifier argument")
    func updatePackIdentifier() throws {
        let cmd = try UpdatePack.parse(["my-pack"])
        #expect(cmd.identifier == "my-pack")
    }

    // MARK: - ListPacks

    @Test("ListPacks parses with no arguments")
    func listPacksNoArgs() throws {
        _ = try ListPacks.parse([])
    }

    // MARK: - PackCommand subcommands

    @Test("PackCommand registers expected subcommands")
    func subcommandTypes() {
        let subcommands = PackCommand.configuration.subcommands
        #expect(subcommands.contains { $0 == AddPack.self })
        #expect(subcommands.contains { $0 == RemovePack.self })
        #expect(subcommands.contains { $0 == UpdatePack.self })
        #expect(subcommands.contains { $0 == ListPacks.self })
        #expect(subcommands.count == 4)
    }
}

// MARK: - ListPacks Pack Status

struct ListPacksStatusTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-packstatus-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeEntry(
        identifier: String = "test-pack",
        sourceURL: String = "https://github.com/user/repo.git",
        localPath: String = "test-pack",
        isLocal: Bool? = nil
    ) -> PackRegistryFile.PackEntry {
        PackRegistryFile.PackEntry(
            identifier: identifier,
            displayName: "Test Pack",
            author: nil,
            sourceURL: sourceURL,
            ref: nil,
            commitSHA: isLocal == true ? Constants.ExternalPacks.localCommitSentinel : "abc123",
            localPath: localPath,
            addedAt: "2026-01-01T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: isLocal
        )
    }

    @Test("Returns source URL for valid git pack with manifest")
    func validGitPack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        // Create pack directory with manifest
        let packDir = env.packsDirectory.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try "identifier: test-pack".write(
            to: packDir.appendingPathComponent(Constants.ExternalPacks.manifestFilename),
            atomically: true, encoding: .utf8
        )

        let entry = makeEntry()
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "https://github.com/user/repo.git")
    }

    @Test("Returns local indicator for valid local pack")
    func validLocalPack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        // Create the local pack directory
        let packDir = tmpDir.appendingPathComponent("my-local-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let entry = makeEntry(
            sourceURL: "/path/to/source",
            localPath: packDir.path,
            isLocal: true
        )
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "/path/to/source (local)")
    }

    @Test("Returns missing checkout for git pack without directory")
    func missingGitCheckout() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        // Create packs directory but not the pack itself
        try FileManager.default.createDirectory(at: env.packsDirectory, withIntermediateDirectories: true)

        let entry = makeEntry()
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "(missing checkout)")
    }

    @Test("Returns missing path for local pack without directory")
    func missingLocalPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        let entry = makeEntry(
            localPath: "/nonexistent/path/to/pack",
            isLocal: true
        )
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status.contains("local — missing at"))
    }

    @Test("Returns invalid path for git pack with traversal in localPath")
    func invalidGitPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        let entry = makeEntry(localPath: "../../etc")
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "(invalid path — escapes packs directory)")
    }

    @Test("Returns invalid local path for local pack with empty localPath")
    func invalidLocalPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        let entry = makeEntry(localPath: "", isLocal: true)
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "(invalid local path: )")
    }

    @Test("Returns invalid when manifest file is missing")
    func missingManifest() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        // Create pack directory without manifest
        let packDir = env.packsDirectory.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let entry = makeEntry()
        let status = ListPacks().packStatus(entry: entry, env: env)
        #expect(status == "(invalid — no \(Constants.ExternalPacks.manifestFilename))")
    }
}
