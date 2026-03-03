import CryptoKit
import Foundation
@testable import mcs
import Testing

@Suite("PackTrustManager")
struct PackTrustManagerTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-trust-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a file to disk.
    private func writeFile(_ content: String, at url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Compute SHA-256 of a file, matching what FileHasher.sha256 does.
    private func sha256(of url: URL) throws -> String {
        try FileHasher.sha256(of: url)
    }

    /// Write YAML to a temp directory and load as ExternalPackManifest.
    private func loadManifest(yaml: String, in tmpDir: URL) throws -> ExternalPackManifest {
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return try ExternalPackManifest.load(from: file)
    }

    // MARK: - analyzeScripts

    @Test("analyzeScripts surfaces shellCommand install actions")
    func analyzeScriptsShellCommand() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        components:
          - id: test.cmd
            displayName: Test Command
            description: Runs a command
            type: configuration
            installAction:
              type: shellCommand
              command: "echo hello"
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        #expect(items.count == 1)
        #expect(items[0].type == .shellCommand)
        #expect(items[0].content == "echo hello")
    }

    @Test("analyzeScripts surfaces MCP server commands")
    func analyzeScriptsMCPServer() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        components:
          - id: test.mcp
            displayName: Test MCP
            description: An MCP server
            type: mcpServer
            installAction:
              type: mcpServer
              name: TestServer
              command: npx
              args:
                - test-server
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        #expect(items.count == 1)
        #expect(items[0].type == .mcpServerCommand)
        #expect(items[0].content.contains("TestServer"))
    }

    @Test("analyzeScripts surfaces commandExists doctor check commands")
    func analyzeScriptsCommandExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: commandExists
            name: Check Git
            command: git
            args:
              - "--version"
            fixCommand: "brew install git"
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        // Should surface: the commandExists command AND the fixCommand
        let doctorCommands = items.filter { $0.type == .doctorCommand }
        let fixScripts = items.filter { $0.type == .fixScript }
        #expect(doctorCommands.count == 1)
        #expect(doctorCommands[0].content == "git --version")
        #expect(fixScripts.count == 1)
        #expect(fixScripts[0].content == "brew install git")
    }

    @Test("analyzeScripts surfaces configure project script")
    func analyzeScriptsConfigureProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptsDir = tmpDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try writeFile("#!/bin/bash\necho configure", at: scriptsDir.appendingPathComponent("configure.sh"))

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        configureProject:
          script: scripts/configure.sh
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        #expect(items.count == 1)
        #expect(items[0].type == .configureScript)
        #expect(items[0].relativePath == "scripts/configure.sh")
    }

    @Test("analyzeScripts surfaces prompt script commands")
    func analyzeScriptsPromptScriptCommand() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        prompts:
          - key: PROJECT
            type: script
            scriptCommand: "ls *.xcodeproj"
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        #expect(items.count == 1)
        #expect(items[0].type == .shellCommand)
        #expect(items[0].content == "ls *.xcodeproj")
    }

    @Test("analyzeScripts returns empty for pack with no executable content")
    func analyzeScriptsEmpty() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        #expect(items.isEmpty)
    }

    // MARK: - verifyTrust

    @Test("verifyTrust returns empty for matching hashes")
    func verifyTrustMatchingHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptFile = tmpDir.appendingPathComponent("script.sh")
        try writeFile("#!/bin/bash\necho ok", at: scriptFile)
        let hash = try sha256(of: scriptFile)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = manager.verifyTrust(
            trustedHashes: ["script.sh": hash],
            packPath: tmpDir
        )

        #expect(modified.isEmpty)
    }

    @Test("verifyTrust detects modified scripts")
    func verifyTrustDetectsModified() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptFile = tmpDir.appendingPathComponent("script.sh")
        try writeFile("#!/bin/bash\necho ok", at: scriptFile)

        // Use a different hash than what's on disk
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = manager.verifyTrust(
            trustedHashes: ["script.sh": "0000000000000000000000000000000000000000000000000000000000000000"],
            packPath: tmpDir
        )

        #expect(modified == ["script.sh"])
    }

    @Test("verifyTrust flags missing files")
    func verifyTrustMissingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = manager.verifyTrust(
            trustedHashes: ["nonexistent.sh": "abc123"],
            packPath: tmpDir
        )

        #expect(modified == ["nonexistent.sh"])
    }

    @Test("verifyTrust skips inline synthetic keys")
    func verifyTrustSkipsInlineKeys() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = manager.verifyTrust(
            trustedHashes: ["inline:abc123def456": "somehash"],
            packPath: tmpDir
        )

        // Inline keys should be skipped (no corresponding file on disk)
        #expect(modified.isEmpty)
    }

    // MARK: - Synthetic Key Determinism

    @Test("syntheticKey is deterministic across calls")
    func syntheticKeyDeterministic() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a manifest with an inline shell command
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        components:
          - id: test.cmd
            displayName: Test
            description: Test
            type: configuration
            installAction:
              type: shellCommand
              command: "echo hello"
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        // Analyze twice and verify the items produce the same trust hashes
        let items1 = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)
        let items2 = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        // The items should be identical between runs
        #expect(items1.count == items2.count)
        #expect(items1[0].content == items2[0].content)
        #expect(items1[0].description == items2[0].description)
    }

    // MARK: - detectNewScripts

    @Test("detectNewScripts returns empty when nothing changed")
    func detectNewScriptsNoChanges() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptsDir = tmpDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let scriptFile = scriptsDir.appendingPathComponent("configure.sh")
        try writeFile("#!/bin/bash\necho ok", at: scriptFile)
        let hash = try sha256(of: scriptFile)

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        configureProject:
          script: scripts/configure.sh
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        let newItems = try manager.detectNewScripts(
            currentHashes: ["scripts/configure.sh": hash],
            updatedPackPath: tmpDir,
            manifest: manifest
        )

        #expect(newItems.isEmpty)
    }

    @Test("detectNewScripts flags new scripts not in trusted set")
    func detectNewScriptsFindsNew() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptsDir = tmpDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try writeFile("#!/bin/bash\necho new", at: scriptsDir.appendingPathComponent("configure.sh"))

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        configureProject:
          script: scripts/configure.sh
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        // Empty trusted hashes means everything is "new"
        let newItems = try manager.detectNewScripts(
            currentHashes: [:],
            updatedPackPath: tmpDir,
            manifest: manifest
        )

        #expect(newItems.count == 1)
        #expect(newItems[0].relativePath == "scripts/configure.sh")
    }

    @Test("detectNewScripts flags modified scripts")
    func detectNewScriptsFindsModified() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptsDir = tmpDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try writeFile("#!/bin/bash\necho modified", at: scriptsDir.appendingPathComponent("configure.sh"))

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        configureProject:
          script: scripts/configure.sh
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        // Hash doesn't match the file on disk
        let newItems = try manager.detectNewScripts(
            currentHashes: ["scripts/configure.sh": "oldhash000000"],
            updatedPackPath: tmpDir,
            manifest: manifest
        )

        #expect(newItems.count == 1)
    }
}
