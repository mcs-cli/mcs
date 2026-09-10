import Foundation
@testable import mcs
import Testing

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

    // MARK: - Hook interpreter trust

    /// A pack with one hook whose interpreter is `interpreterLine` (omitted when nil).
    private func hookPackYAML(interpreterLine: String?) -> String {
        let interpreter = interpreterLine.map { "    hookInterpreter: \($0)\n" } ?? ""
        return """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        components:
          - id: test.gate
            displayName: Gate Hook
            description: A hook
            hookEvent: PreToolUse
        \(interpreter)    hook:
              source: hooks/gate.sh
              destination: gate.sh
        """
    }

    @Test("A non-default hook interpreter is a trustable item of its own")
    func hookInterpreterIsTrustable() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try writeFile("echo gate", at: tmpDir.appendingPathComponent("hooks/gate.sh"))

        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: "sh -c"), in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        let interpreterItem = try #require(items.first { $0.type == .hookInterpreter })
        // What actually executes must be reviewable, not just the script's contents.
        #expect(interpreterItem.content == "sh -c gate.sh")
        #expect(interpreterItem.relativePath == nil)
    }

    @Test("A plain bash hook's interpreter item is marked as pre-existing behaviour")
    func defaultInterpreterIsMarkedAsDefault() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try writeFile("echo gate", at: tmpDir.appendingPathComponent("hooks/gate.sh"))

        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: nil), in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        // Emitted (so that losing an interpreter later is detectable) but flagged, so first-time
        // trust is waived and packs predating interpreter tracking are not re-prompted.
        let item = try #require(items.first { $0.type == .hookInterpreter })
        #expect(item.representsDefaultBehavior)
        #expect(item.content == "bash gate.sh")
        #expect(items.contains { $0.type == .hookFragment })
    }

    @Test("A legacy pack with a bash hook is not flagged on its first update")
    func legacyBashPackIsNotFlagged() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try writeFile("echo gate", at: tmpDir.appendingPathComponent("hooks/gate.sh"))

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: nil), in: tmpDir)
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)

        // Trusted before interpreter items existed: only the script file has a hash.
        let legacyHashes = try ["hooks/gate.sh": sha256(of: tmpDir.appendingPathComponent("hooks/gate.sh"))]
        let changed = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            against: legacyHashes,
            packPath: tmpDir
        )
        #expect(changed.isEmpty)
        #expect(items.contains { $0.type == .hookInterpreter })
    }

    @Test("Dropping a trusted interpreter back to bash forces renewed trust")
    func interpreterDowngradeIsDetected() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try writeFile("echo gate", at: tmpDir.appendingPathComponent("hooks/gate.sh"))

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        // Trusted running under node.
        let before = try loadManifest(yaml: hookPackYAML(interpreterLine: "node"), in: tmpDir)
        let trusted = try manager.computeScriptHashes(
            items: manager.analyzeScripts(manifest: before, packPath: tmpDir),
            packPath: tmpDir
        )

        // The update drops the interpreter, so the same bytes now run under bash. A polyglot
        // script reviewed as JS would begin executing its shell branch unreviewed.
        let after = try loadManifest(yaml: hookPackYAML(interpreterLine: nil), in: tmpDir)
        let changed = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: after, packPath: tmpDir),
            against: trusted,
            packPath: tmpDir
        )
        #expect(changed.contains { $0.type == .hookInterpreter })
    }

    @Test("Two hooks sharing a display name get distinct trust keys")
    func sameDisplayNameDoesNotCollide() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try writeFile("console.log(1)", at: tmpDir.appendingPathComponent("hooks/one.js"))
        try writeFile("console.log(2)", at: tmpDir.appendingPathComponent("hooks/two.js"))

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        components:
          - id: test.one
            displayName: Gate Hook
            description: First hook
            hookEvent: PreToolUse
            hook:
              source: hooks/one.js
              destination: one.js
          - id: test.two
            displayName: Gate Hook
            description: Second hook
            hookEvent: PostToolUse
            hook:
              source: hooks/two.js
              destination: two.js
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)
        let hashes = try manager.computeScriptHashes(items: items, packPath: tmpDir)

        // Both interpreter items must survive hashing; a description-only key would collapse them.
        let interpreterItems = items.filter { $0.type == .hookInterpreter }
        #expect(interpreterItems.count == 2)
        #expect(Set(interpreterItems.map(\.description)).count == 2)
        // Two file hashes plus two distinct interpreter hashes.
        #expect(hashes.count == 4)
    }

    @Test("Changing only the interpreter forces renewed trust on update")
    func interpreterChangeIsDetectedAsNewScript() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let hooksDir = tmpDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let script = hooksDir.appendingPathComponent("gate.sh")
        try writeFile("echo gate", at: script)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))

        // Trust the pack as it was: node, with the script hashed.
        let before = try loadManifest(yaml: hookPackYAML(interpreterLine: "node"), in: tmpDir)
        let trusted = try manager.computeScriptHashes(
            items: manager.analyzeScripts(manifest: before, packPath: tmpDir),
            packPath: tmpDir
        )

        // The update leaves the script byte-identical and swaps only the interpreter.
        let after = try loadManifest(yaml: hookPackYAML(interpreterLine: "sh -c"), in: tmpDir)
        let changed = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: after, packPath: tmpDir),
            against: trusted,
            packPath: tmpDir
        )

        // Without the interpreter in the trust surface this returns empty: same file hash, no
        // prompt, and `sh -c` runs on the next session unreviewed.
        #expect(changed.contains { $0.type == .hookInterpreter })
    }

    @Test("An unchanged interpreter does not re-prompt")
    func unchangedInterpreterIsNotFlagged() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let hooksDir = tmpDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try writeFile("echo gate", at: hooksDir.appendingPathComponent("gate.sh"))

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: "node"), in: tmpDir)
        let trusted = try manager.computeScriptHashes(
            items: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            packPath: tmpDir
        )
        let changed = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            against: trusted,
            packPath: tmpDir
        )
        #expect(changed.isEmpty)
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

    @Test("Two MCP servers in one pack get separate trust keys and stay trusted")
    func twoMCPServersDoNotShareATrustKey() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        version: "1.0.0"
        components:
          - id: test.first
            displayName: First
            description: A command-based MCP server
            mcp:
              name: FirstServer
              command: first-server
              args:
                - mcp
          - id: test.second
            displayName: Second
            description: An HTTP MCP server
            mcp:
              url: https://example.test/mcp
        """
        let manifest = try loadManifest(yaml: yaml, in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let items = try manager.analyzeScripts(manifest: manifest, packPath: tmpDir)
        #expect(items.count == 2)

        let hashes = try manager.computeScriptHashes(items: items, packPath: tmpDir)
        #expect(hashes.count == 2)

        // Both servers verify against the map their own approval produced — the collision made
        // one of them re-prompt on every update, no matter how often it was approved.
        let unapproved = manager.newOrChanged(in: items, against: hashes, packPath: tmpDir)
        #expect(unapproved.isEmpty)
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

    /// A pack declaring one hook at `hooks/gate.sh`, with that file written to disk.
    /// Returns the manifest and the hook's current hash.
    private func hookPack(in tmpDir: URL) throws -> (manifest: ExternalPackManifest, hash: String) {
        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: nil), in: tmpDir)
        let scriptFile = tmpDir.appendingPathComponent("hooks/gate.sh")
        try FileManager.default.createDirectory(
            at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writeFile("#!/bin/bash\necho ok", at: scriptFile)
        let hash = try sha256(of: scriptFile)
        return (manifest, hash)
    }

    @Test("verifyTrust returns empty for matching hashes")
    func verifyTrustMatchingHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try hookPack(in: tmpDir)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: ["hooks/gate.sh": pack.hash],
            packPath: tmpDir,
            manifest: pack.manifest
        )

        #expect(modified.isEmpty)
    }

    @Test("verifyTrust detects modified scripts")
    func verifyTrustDetectsModified() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try hookPack(in: tmpDir)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: ["hooks/gate.sh": "0000000000000000000000000000000000000000000000000000000000000000"],
            packPath: tmpDir,
            manifest: pack.manifest
        )

        #expect(modified == ["hooks/gate.sh": .mismatched])
    }

    @Test("verifyTrust flags a referenced file that is missing from disk")
    func verifyTrustMissingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Manifest declares hooks/gate.sh, but the file is never written.
        let manifest = try loadManifest(yaml: hookPackYAML(interpreterLine: nil), in: tmpDir)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: ["hooks/gate.sh": "abc123"],
            packPath: tmpDir,
            manifest: manifest
        )

        // A referenced file that is gone reads as mismatched, not as an unreadable-file error.
        #expect(modified == ["hooks/gate.sh": .mismatched])
    }

    @Test("verifyTrust ignores a stored key the manifest no longer references")
    func verifyTrustIgnoresOrphanedKey() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try hookPack(in: tmpDir)

        // The orphaned key is what bricked a pack that renamed all of its scripts.
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: ["hooks/gate.sh": pack.hash, "hooks/legacy.sh": "abc123"],
            packPath: tmpDir,
            manifest: pack.manifest
        )

        #expect(modified.isEmpty)
    }

    @Test("verifyTrust flags a referenced script that was never trusted")
    func verifyTrustFlagsNeverTrustedScript() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let pack = try hookPack(in: tmpDir)

        // On disk with no hash recorded — unchecked while verification walked the stored keys.
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: [:],
            packPath: tmpDir,
            manifest: pack.manifest
        )

        #expect(modified == ["hooks/gate.sh": .neverTrusted])
    }

    /// A pack whose only trustable content is one doctor `shellScript` check.
    private func doctorScriptPackYAML() -> String {
        """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        supplementaryDoctorChecks:
          - type: shellScript
            name: Check Env
            command: scripts/doctor.sh
        """
    }

    @Test("verifyTrust flags a trusted doctor script that was deleted")
    func verifyTrustFlagsDeletedDoctorScript() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptFile = tmpDir.appendingPathComponent("scripts/doctor.sh")
        try FileManager.default.createDirectory(
            at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writeFile("#!/bin/bash\necho ok", at: scriptFile)

        let manifest = try loadManifest(yaml: doctorScriptPackYAML(), in: tmpDir)
        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let trusted = try manager.computeScriptHashes(
            items: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            packPath: tmpDir
        )
        #expect(trusted["scripts/doctor.sh"] != nil)

        // Deleting the file reclassifies the declared path as an inline command.
        try FileManager.default.removeItem(at: scriptFile)

        let modified = try manager.verifyTrust(
            trustedHashes: trusted, packPath: tmpDir, manifest: manifest
        )

        #expect(modified == ["scripts/doctor.sh": .mismatched])
    }

    @Test("verifyTrust does not report a doctor script path that was never trusted as a file")
    func verifyTrustIgnoresNeverTrustedDoctorPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // A declared path with no file is a broken pack, which doctor reports at run time. It was
        // never trusted as a file, so it must not be reported here as a deleted script.
        let manifest = try loadManifest(yaml: """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        supplementaryDoctorChecks:
          - type: shellScript
            name: Check Env
            command: scripts/absent.sh
        """, in: tmpDir)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let trusted = try manager.computeScriptHashes(
            items: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            packPath: tmpDir
        )

        let modified = try manager.verifyTrust(
            trustedHashes: trusted, packPath: tmpDir, manifest: manifest
        )

        #expect(modified.isEmpty)
    }

    @Test("verifyTrust skips inline synthetic keys")
    func verifyTrustSkipsInlineKeys() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Inline items stay out of the load-time gate even with no hash recorded.
        let manifest = try loadManifest(yaml: """
        schemaVersion: 1
        identifier: test
        displayName: Test Pack
        description: A test pack
        components:
          - id: test.setup
            displayName: Setup
            description: Runs a command
            type: configuration
            installAction:
              type: shellCommand
              command: "echo hello"
        """, in: tmpDir)

        let manager = PackTrustManager(output: CLIOutput(colorsEnabled: false))
        let modified = try manager.verifyTrust(
            trustedHashes: ["inline:abc123def456": "somehash"],
            packPath: tmpDir,
            manifest: manifest
        )

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

        let newItems = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            against: ["scripts/configure.sh": hash],
            packPath: tmpDir
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
        let newItems = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            against: [:],
            packPath: tmpDir
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
        let newItems = try manager.newOrChanged(
            in: manager.analyzeScripts(manifest: manifest, packPath: tmpDir),
            against: ["scripts/configure.sh": "oldhash000000"],
            packPath: tmpDir
        )

        #expect(newItems.count == 1)
    }
}
