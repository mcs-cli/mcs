import Foundation
@testable import mcs
import Testing

struct ExternalPackLoaderTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-loader-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a minimal valid techpack.yaml content.
    private func minimalManifestYAML(
        identifier: String = "test-pack",
        minMCSVersion: String? = nil
    ) -> String {
        var yaml = """
        schemaVersion: 1
        identifier: \(identifier)
        displayName: Test Pack
        description: A test pack
        """
        if let minVer = minMCSVersion {
            yaml += "\nminMCSVersion: \"\(minVer)\""
        }
        return yaml
    }

    /// Create a manifest with a template referencing a content file.
    private func manifestWithTemplate(identifier: String = "test-pack", contentFile: String) -> String {
        """
        schemaVersion: 1
        identifier: \(identifier)
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        templates:
          - sectionIdentifier: \(identifier)
            contentFile: \(contentFile)
        """
    }

    /// Set up a minimal test environment with pack directories.
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

    private func setupTestEnv() throws -> (tmpDir: URL, env: Environment) {
        let tmpDir = try makeTmpDir()
        let env = Environment(home: tmpDir)
        try FileManager.default.createDirectory(
            at: env.packsDirectory,
            withIntermediateDirectories: true
        )
        return (tmpDir, env)
    }

    // MARK: - Validate

    @Test("Validate succeeds for a minimal valid manifest")
    func validateMinimalManifest() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("my-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try minimalManifestYAML().write(to: manifestURL, atomically: true, encoding: .utf8)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        let manifest = try loader.validate(at: packDir)
        #expect(manifest.identifier == "test-pack")
    }

    @Test("Validate throws when techpack.yaml is missing")
    func validateMissingManifest() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let emptyDir = tmpDir.appendingPathComponent("empty-pack")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.validate(at: emptyDir)
        }
    }

    @Test("Validate throws for invalid YAML content")
    func validateInvalidYAML() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("bad-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try "not: valid: yaml: [[[".write(to: manifestURL, atomically: true, encoding: .utf8)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.validate(at: packDir)
        }
    }

    @Test("Validate throws for manifest with bad schema version")
    func validateBadSchemaVersion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("bad-schema")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let yaml = """
        schemaVersion: 99
        identifier: test-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        """
        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.validate(at: packDir)
        }
    }

    // MARK: - minMCSVersion compatibility

    @Test("Validate passes when minMCSVersion is satisfied")
    func validateCompatibleVersion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("compat-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        // Use a very low version that current mcs should satisfy
        let yaml = minimalManifestYAML(minMCSVersion: "0.1.0")
        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        let manifest = try loader.validate(at: packDir)
        #expect(manifest.minMCSVersion == "0.1.0")
    }

    @Test("Validate throws when minMCSVersion is too high")
    func validateIncompatibleVersion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("future-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        // Use a very high version that current mcs cannot satisfy
        let yaml = minimalManifestYAML(minMCSVersion: "3000.0.0")
        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.validate(at: packDir)
        }
    }

    // MARK: - Referenced file validation

    @Test("Validate detects missing template content files")
    func validateMissingTemplateFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("missing-template")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let yaml = manifestWithTemplate(contentFile: "templates/section.md")
        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)
        // Do NOT create templates/section.md

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.validate(at: packDir)
        }
    }

    @Test("Validate passes when template content file exists")
    func validatePresentTemplateFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("good-template")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let yaml = manifestWithTemplate(contentFile: "templates/section.md")
        let manifestURL = packDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Create the referenced file
        let templatesDir = packDir.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try "## My Section".write(
            to: templatesDir.appendingPathComponent("section.md"),
            atomically: true,
            encoding: .utf8
        )

        let env = Environment(home: tmpDir)
        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)

        let manifest = try loader.validate(at: packDir)
        #expect(manifest.templates?.count == 1)
    }

    // MARK: - loadAll

    @Test("loadAll returns empty array when no packs registered")
    func loadAllEmpty() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.isEmpty)
    }

    @Test("loadAll loads registered pack successfully")
    func loadAllOneValid() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a pack checkout
        let packDir = env.packsDirectory.appendingPathComponent("my-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        let yaml = minimalManifestYAML(identifier: "my-pack")
        try yaml.write(
            to: packDir.appendingPathComponent("techpack.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Register it
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        registry.register(
            PackRegistryFile.PackEntry(
                identifier: "my-pack",
                displayName: "My Pack",
                author: nil,
                sourceURL: "https://github.com/user/my-pack.git",
                ref: "v1.0.0",
                commitSHA: "abc123",
                localPath: "my-pack",
                addedAt: "2026-01-01T00:00:00Z",
                trustedScriptHashes: [:],
                isLocal: nil
            ),
            in: &data
        )
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.count == 1)
        #expect(adapters[0].identifier == "my-pack")
    }

    @Test("loadAll skips packs with missing checkout")
    func loadAllSkipsMissing() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Register a pack but don't create its checkout
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        registry.register(
            PackRegistryFile.PackEntry(
                identifier: "ghost-pack",
                displayName: "Ghost",
                author: nil,
                sourceURL: "https://github.com/user/ghost.git",
                ref: nil,
                commitSHA: "def456",
                localPath: "ghost-pack",
                addedAt: "2026-01-01T00:00:00Z",
                trustedScriptHashes: [:],
                isLocal: nil
            ),
            in: &data
        )
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.isEmpty)
    }

    @Test("loadAll loads valid packs and skips invalid ones")
    func loadAllPartialSuccess() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a valid pack
        let validDir = env.packsDirectory.appendingPathComponent("valid-pack")
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        try minimalManifestYAML(identifier: "valid-pack").write(
            to: validDir.appendingPathComponent("techpack.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Create an invalid pack (bad schema)
        let invalidDir = env.packsDirectory.appendingPathComponent("invalid-pack")
        try FileManager.default.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        let badYAML = """
        schemaVersion: 99
        identifier: invalid-pack
        displayName: Invalid
        description: Bad
        version: "1.0.0"
        """
        try badYAML.write(
            to: invalidDir.appendingPathComponent("techpack.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Register both
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        for (id, localPath) in [("valid-pack", "valid-pack"), ("invalid-pack", "invalid-pack")] {
            registry.register(
                PackRegistryFile.PackEntry(
                    identifier: id,
                    displayName: id,
                    author: nil,
                    sourceURL: "https://github.com/user/\(id).git",
                    ref: nil,
                    commitSHA: "abc",
                    localPath: localPath,
                    addedAt: "2026-01-01T00:00:00Z",
                    trustedScriptHashes: [:],
                    isLocal: nil
                ),
                in: &data
            )
        }
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.count == 1)
        #expect(adapters[0].identifier == "valid-pack")
    }

    // MARK: - load(identifier:)

    @Test("load by identifier returns adapter for registered pack")
    func loadByIdentifier() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create pack checkout
        let packDir = env.packsDirectory.appendingPathComponent("target-pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try minimalManifestYAML(identifier: "target-pack").write(
            to: packDir.appendingPathComponent("techpack.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Register
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        registry.register(
            PackRegistryFile.PackEntry(
                identifier: "target-pack",
                displayName: "Target",
                author: nil,
                sourceURL: "https://github.com/user/target.git",
                ref: nil,
                commitSHA: "abc",
                localPath: "target-pack",
                addedAt: "2026-01-01T00:00:00Z",
                trustedScriptHashes: [:],
                isLocal: nil
            ),
            in: &data
        )
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapter = try loader.load(identifier: "target-pack", output: output)
        #expect(adapter.identifier == "target-pack")
    }

    // MARK: - Local pack loading

    @Test("loadAll loads local pack from absolute path")
    func loadAllLocalPack() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create pack outside ~/.mcs/packs/ (simulating a local dev directory)
        let localPackDir = tmpDir.appendingPathComponent("dev-packs/my-local-pack")
        try FileManager.default.createDirectory(at: localPackDir, withIntermediateDirectories: true)
        try minimalManifestYAML(identifier: "my-local-pack").write(
            to: localPackDir.appendingPathComponent("techpack.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Register as local pack
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        registry.register(
            sampleLocalEntry(identifier: "my-local-pack", localPath: localPackDir.path),
            in: &data
        )
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.count == 1)
        #expect(adapters[0].identifier == "my-local-pack")
    }

    @Test("loadAll skips local pack with missing directory")
    func loadAllLocalPackMissing() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Register a local pack pointing to a nonexistent directory
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        registry.register(
            sampleLocalEntry(identifier: "missing-local", localPath: "/nonexistent/path/missing-local"),
            in: &data
        )
        try registry.save(data)

        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        let adapters = loader.loadAll(output: output)
        #expect(adapters.isEmpty)
    }

    @Test("load by identifier throws for unregistered pack")
    func loadByIdentifierUnregistered() throws {
        let (tmpDir, env) = try setupTestEnv()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = PackRegistryFile(path: env.packsRegistry)
        let loader = ExternalPackLoader(environment: env, registry: registry)
        let output = CLIOutput(colorsEnabled: false)

        #expect(throws: ExternalPackLoader.LoadError.self) {
            try loader.load(identifier: "nonexistent", output: output)
        }
    }

    // MARK: - VersionCompare

    @Test("VersionCompare.isCompatible with equal versions")
    func versionCompareEqual() {
        #expect(VersionCompare.isCompatible(current: "2.0.1", required: "2.0.1"))
    }

    @Test("VersionCompare.isCompatible with current higher patch")
    func versionCompareHigherPatch() {
        #expect(VersionCompare.isCompatible(current: "2.0.2", required: "2.0.1"))
    }

    @Test("VersionCompare.isCompatible with current higher minor")
    func versionCompareHigherMinor() {
        #expect(VersionCompare.isCompatible(current: "2.1.0", required: "2.0.1"))
    }

    @Test("VersionCompare.isCompatible with current higher major")
    func versionCompareHigherMajor() {
        #expect(VersionCompare.isCompatible(current: "3.0.0", required: "2.0.1"))
    }

    @Test("VersionCompare.isCompatible returns false when current is lower")
    func versionCompareIncompatible() {
        #expect(!VersionCompare.isCompatible(current: "1.9.9", required: "2.0.0"))
    }

    @Test("VersionCompare.isCompatible returns false when current patch is lower")
    func versionCompareLowerPatch() {
        #expect(!VersionCompare.isCompatible(current: "2.0.0", required: "2.0.1"))
    }

    @Test("VersionCompare.parse extracts components correctly")
    func versionCompareParse() {
        let v = VersionCompare.parse("3.14.159")
        #expect(v != nil)
        #expect(v?.major == 3)
        #expect(v?.minor == 14)
        #expect(v?.patch == 159)
    }

    @Test("VersionCompare.parse handles invalid input gracefully")
    func versionCompareParseInvalid() {
        let v = VersionCompare.parse("invalid")
        #expect(v == nil)
    }

    @Test("VersionCompare.parse strips pre-release suffix")
    func versionCompareParsePreRelease() {
        let v = VersionCompare.parse("2.1.0-alpha")
        #expect(v != nil)
        #expect(v?.major == 2)
        #expect(v?.minor == 1)
        #expect(v?.patch == 0)
    }

    @Test("VersionCompare.isCompatible with pre-release current version")
    func versionComparePreReleaseCompatible() {
        #expect(VersionCompare.isCompatible(current: "2.1.0-alpha", required: "2.1.0"))
        #expect(VersionCompare.isCompatible(current: "2.1.0-alpha", required: "2.0.0"))
        #expect(!VersionCompare.isCompatible(current: "2.1.0-alpha", required: "2.2.0"))
    }

    @Test("VersionCompare.isCompatible with pre-release required version")
    func versionComparePreReleaseRequired() {
        #expect(VersionCompare.isCompatible(current: "2.1.0", required: "2.1.0-beta"))
    }
}
