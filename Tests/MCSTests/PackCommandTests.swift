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
        let cmd = try ListPacks.parse([])
        #expect(cmd.json == false)
    }

    @Test("ListPacks parses --json flag")
    func listPacksJSON() throws {
        let cmd = try ListPacks.parse(["--json"])
        #expect(cmd.json == true)
    }

    // MARK: - PackCommand subcommands

    @Test("PackCommand registers expected subcommands")
    func subcommandTypes() {
        let subcommands = PackCommand.configuration.subcommands
        #expect(subcommands.contains { $0 == AddPack.self })
        #expect(subcommands.contains { $0 == RemovePack.self })
        #expect(subcommands.contains { $0 == UpdatePack.self })
        #expect(subcommands.contains { $0 == ListPacks.self })
        #expect(subcommands.contains { $0 == ValidatePack.self })
        #expect(subcommands.count == 5)
    }
}

// MARK: - ListPacks Pack Status

struct ListPacksStatusTests {
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

// MARK: - ListPacks JSON

struct ListPacksJSONTests {
    private func installGitPack(_ identifier: String, home: URL) throws {
        try preparePackDir(home: home, identifier: identifier)
        let packDir = Environment(home: home).packsDirectory.appendingPathComponent(identifier)
        try "identifier: \(identifier)".write(
            to: packDir.appendingPathComponent(Constants.ExternalPacks.manifestFilename),
            atomically: true, encoding: .utf8
        )
    }

    private func indexEntry(_ path: String, packs: [String]) -> ProjectIndex.ProjectEntry {
        ProjectIndex.ProjectEntry(path: path, packs: packs, lastSynced: "2026-01-01T00:00:00Z")
    }

    @Test("Empty registry produces no entries")
    func emptyRegistry() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)

        let entries = ListPacks().jsonEntries(
            registry: PackRegistryFile.RegistryData(),
            index: ProjectIndex.IndexData(),
            env: env
        )
        #expect(entries.isEmpty)
    }

    @Test("Git pack maps registry fields and reports ok")
    func gitPackFields() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        try installGitPack("test-pack", home: tmpDir)

        let registry = PackRegistryFile.RegistryData(packs: [makeRegistryEntry(identifier: "test-pack", ref: "v1.0")])
        let entries = ListPacks().jsonEntries(registry: registry, index: ProjectIndex.IndexData(), env: env)

        #expect(entries == [ListPacks.JSONEntry(
            identifier: "test-pack",
            source: "https://example.com/test-pack.git",
            ref: "v1.0",
            commitSHA: "abc123def456",
            isLocal: false,
            status: .ok,
            scopes: []
        )])
    }

    @Test("Local pack reports local sentinel and nil ref")
    func localPackFields() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        let packDir = tmpDir.appendingPathComponent("local-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let registry = PackRegistryFile.RegistryData(packs: [makeLocalRegistryEntry(identifier: "local-pack", localPath: packDir.path)])
        let entry = try #require(
            ListPacks().jsonEntries(registry: registry, index: ProjectIndex.IndexData(), env: env).first
        )

        #expect(entry.commitSHA == Constants.ExternalPacks.localCommitSentinel)
        #expect(entry.ref == nil)
        #expect(entry.isLocal == true)
        #expect(entry.status == .ok)
    }

    @Test("Local pack reports nil ref and local sentinel even when the registry was hand-edited")
    func localPackFieldsNormalized() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        let packDir = tmpDir.appendingPathComponent("local-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        var edited = makeLocalRegistryEntry(identifier: "local-pack", localPath: packDir.path)
        edited.ref = "v1.0"
        edited.commitSHA = "abc123def456"
        let entry = try #require(
            ListPacks().jsonEntries(
                registry: PackRegistryFile.RegistryData(packs: [edited]),
                index: ProjectIndex.IndexData(),
                env: env
            ).first
        )

        #expect(entry.ref == nil)
        #expect(entry.commitSHA == Constants.ExternalPacks.localCommitSentinel)
    }

    @Test("Status maps missing checkout, bad path, and missing manifest")
    func statusMapping() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        try preparePackDir(home: tmpDir, identifier: "no-manifest")

        let registry = PackRegistryFile.RegistryData(packs: [
            makeRegistryEntry(identifier: "missing"),
            makeRegistryEntry(identifier: "../../etc"),
            makeRegistryEntry(identifier: "no-manifest"),
        ])
        let statuses = ListPacks()
            .jsonEntries(registry: registry, index: ProjectIndex.IndexData(), env: env)
            .map(\.status)

        #expect(statuses == [.missing, .invalid, .invalid])
    }

    @Test("Scopes list global first, then existing project paths sorted; stale paths dropped")
    func scopes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        try installGitPack("test-pack", home: tmpDir)
        let projectB = tmpDir.appendingPathComponent("b-project")
        let projectA = tmpDir.appendingPathComponent("a-project")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let stale = tmpDir.appendingPathComponent("deleted-project").path

        let index = ProjectIndex.IndexData(projects: [
            indexEntry(projectB.path, packs: ["test-pack"]),
            indexEntry(stale, packs: ["test-pack"]),
            indexEntry(ProjectIndex.globalSentinel, packs: ["test-pack"]),
            indexEntry(projectA.path, packs: ["test-pack", "other"]),
            indexEntry(tmpDir.path, packs: ["other"]),
        ])
        let registry = PackRegistryFile.RegistryData(packs: [makeRegistryEntry(identifier: "test-pack")])
        let entry = try #require(ListPacks().jsonEntries(registry: registry, index: index, env: env).first)

        #expect(entry.scopes == ["global", projectA.path, projectB.path])
    }

    @Test("Empty list renders as a literal []")
    func renderEmpty() throws {
        #expect(try ListPacks.renderJSON([]) == "[]")
    }

    @Test("Non-empty list renders pretty-printed with sorted keys")
    func renderNonEmpty() throws {
        let entry = ListPacks.JSONEntry(
            identifier: "test-pack",
            source: "https://example.com/test-pack.git",
            ref: nil,
            commitSHA: "abc123def456",
            isLocal: false,
            status: .ok,
            scopes: []
        )
        let rendered = try ListPacks.renderJSON([entry])

        #expect(rendered.hasPrefix("[\n"))
        let commitRange = try #require(rendered.range(of: "\"commitSHA\""))
        let statusRange = try #require(rendered.range(of: "\"status\""))
        #expect(commitRange.lowerBound < statusRange.lowerBound)
    }

    @Test("Encoded entry carries exactly the documented keys, with null ref")
    func encodedKeys() throws {
        let entry = ListPacks.JSONEntry(
            identifier: "test-pack",
            source: "/path/to/pack",
            ref: nil,
            commitSHA: Constants.ExternalPacks.localCommitSentinel,
            isLocal: true,
            status: .missing,
            scopes: ["global"]
        )
        let data = try JSONEncoder().encode([entry])
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try #require(decoded.first)

        #expect(Set(object.keys) == ["identifier", "source", "ref", "commitSHA", "isLocal", "status", "scopes"])
        #expect(object["ref"] is NSNull)
        #expect(object["status"] as? String == "missing")
    }
}
