import Foundation
@testable import mcs
import Testing

struct DerivedDoctorCheckTests {
    /// Builds a ComponentDefinition with sensible defaults for testing.
    private func makeComponent(
        id: String = "test",
        displayName: String = "Test",
        type: ComponentType = .skill,
        isRequired: Bool = false,
        installAction: ComponentInstallAction,
        supplementaryChecks: [any DoctorCheck] = []
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: id,
            displayName: displayName,
            description: "test",
            type: type,
            packIdentifier: nil,
            dependencies: [],
            isRequired: isRequired,
            installAction: installAction,
            supplementaryChecks: supplementaryChecks
        )
    }

    /// Creates a unique temporary directory, cleaned up via `defer` in the caller.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - deriveDoctorCheck() generation

    @Test("mcpServer action derives MCPServerCheck")
    func mcpServerDerivation() {
        let component = makeComponent(
            displayName: "TestServer",
            type: .mcpServer,
            installAction: .mcpServer(MCPServerConfig(
                name: "test-server", command: "cmd", args: [], env: [:]
            ))
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "TestServer")
        #expect(check?.section == "MCP Servers")
    }

    @Test("plugin action derives PluginCheck")
    func pluginDerivation() {
        let component = makeComponent(
            displayName: "test-plugin",
            type: .plugin,
            installAction: .plugin(name: "test-plugin@test-org")
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "test-plugin")
        #expect(check?.section == "Plugins")
    }

    @Test("brewInstall action derives CommandCheck")
    func brewInstallDerivation() {
        let component = makeComponent(
            displayName: "TestPkg",
            type: .brewPackage,
            installAction: .brewInstall(package: "testpkg")
        )
        let check = component.deriveDoctorCheck()
        #expect(check != nil)
        #expect(check?.name == "TestPkg")
        #expect(check?.section == "Dependencies")
    }

    @Test("shellCommand action returns nil (not derivable)")
    func shellCommandReturnsNil() {
        let component = makeComponent(
            type: .brewPackage,
            installAction: .shellCommand(command: "echo hello")
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    @Test("settingsMerge action returns nil (not derivable)")
    func settingsMergeReturnsNil() {
        let component = makeComponent(
            type: .configuration,
            isRequired: true,
            installAction: .settingsMerge(source: nil)
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    @Test("gitignoreEntries action returns nil (not derivable)")
    func gitignoreReturnsNil() {
        let component = makeComponent(
            type: .configuration,
            isRequired: true,
            installAction: .gitignoreEntries(entries: [".test"])
        )
        #expect(component.deriveDoctorCheck() == nil)
    }

    // MARK: - copyPackFile derivation

    @Test("copyPackFile without projectRoot derives FileExistsCheck with global path and no fallback")
    func copyPackFileGlobalPath() throws {
        let component = makeComponent(
            displayName: "MySkill",
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/source.md"),
                destination: "my-skill.md",
                fileType: .skill
            )
        )
        let fileCheck = try #require(component.deriveDoctorCheck() as? FileExistsCheck)
        #expect(fileCheck.path.path.hasSuffix("/.claude/skills/my-skill.md"))
        #expect(fileCheck.fallbackPath == nil)
    }

    @Test("copyPackFile with projectRoot derives FileExistsCheck with project path and global fallback")
    func copyPackFileProjectPath() throws {
        let projectRoot = URL(fileURLWithPath: "/tmp/my-project")
        let component = makeComponent(
            displayName: "MySkill",
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/source.md"),
                destination: "my-skill.md",
                fileType: .skill
            )
        )
        let fileCheck = try #require(component.deriveDoctorCheck(projectRoot: projectRoot) as? FileExistsCheck)
        #expect(fileCheck.path.path == "/tmp/my-project/.claude/skills/my-skill.md")
        let fallbackPath = try #require(fileCheck.fallbackPath)
        #expect(fallbackPath.path.hasSuffix("/.claude/skills/my-skill.md"))
        #expect(!fallbackPath.path.contains("/my-project/"))
    }

    @Test("copyPackFile projectRoot resolves correctly for all CopyFileType variants")
    func copyPackFileAllTypes() {
        let projectRoot = URL(fileURLWithPath: "/tmp/proj")
        let cases: [(CopyFileType, String)] = [
            (.skill, "/tmp/proj/.claude/skills/test.md"),
            (.hook, "/tmp/proj/.claude/hooks/test.md"),
            (.command, "/tmp/proj/.claude/commands/test.md"),
            (.agent, "/tmp/proj/.claude/agents/test.md"),
            (.generic, "/tmp/proj/.claude/test.md"),
        ]
        for (fileType, expectedPath) in cases {
            let component = makeComponent(
                id: "test.\(fileType.rawValue)",
                installAction: .copyPackFile(
                    source: URL(fileURLWithPath: "/tmp/source.md"),
                    destination: "test.md",
                    fileType: fileType
                )
            )
            let fileCheck = component.deriveDoctorCheck(projectRoot: projectRoot) as? FileExistsCheck
            #expect(fileCheck?.path.path == expectedPath, "Expected \(expectedPath) for \(fileType.rawValue)")
        }
    }

    // MARK: - FileExistsCheck fallback behavior

    @Test("FileExistsCheck passes when primary path exists")
    func fileExistsCheckPrimaryPath() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.md")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let check = FileExistsCheck(
            name: "test", section: "Skills", path: file,
            fallbackPath: URL(fileURLWithPath: "/nonexistent/fallback.md")
        )
        if case let .pass(msg) = check.check() {
            #expect(msg == "present")
        } else {
            Issue.record("Expected pass")
        }
    }

    @Test("FileExistsCheck falls back to global path when primary missing")
    func fileExistsCheckFallback() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let globalFile = tmpDir.appendingPathComponent("global.md")
        try "content".write(to: globalFile, atomically: true, encoding: .utf8)

        let check = FileExistsCheck(
            name: "test", section: "Skills",
            path: URL(fileURLWithPath: "/nonexistent/project.md"),
            fallbackPath: globalFile
        )
        if case let .pass(msg) = check.check() {
            #expect(msg == "present (global)")
        } else {
            Issue.record("Expected pass with global fallback")
        }
    }

    @Test("FileExistsCheck fails when neither primary nor fallback exist")
    func fileExistsCheckBothMissing() {
        let check = FileExistsCheck(
            name: "test", section: "Skills",
            path: URL(fileURLWithPath: "/nonexistent/project.md"),
            fallbackPath: URL(fileURLWithPath: "/nonexistent/global.md")
        )
        if case .fail = check.check() {
            // expected
        } else {
            Issue.record("Expected fail")
        }
    }

    // MARK: - MCPServerCheck project root

    @Test("mcpServer action passes projectRoot to MCPServerCheck")
    func mcpServerDerivationWithProjectRoot() {
        let projectRoot = URL(fileURLWithPath: "/tmp/my-project")
        let component = makeComponent(
            type: .mcpServer,
            installAction: .mcpServer(MCPServerConfig(
                name: "test-server", command: "cmd", args: [], env: [:]
            ))
        )
        let mcpCheck = component.deriveDoctorCheck(projectRoot: projectRoot) as? MCPServerCheck
        #expect(mcpCheck != nil)
        #expect(mcpCheck?.projectRoot?.path == "/tmp/my-project")
    }

    @Test("mcpServer action without projectRoot has nil projectRoot")
    func mcpServerDerivationWithoutProjectRoot() {
        let component = makeComponent(
            type: .mcpServer,
            installAction: .mcpServer(MCPServerConfig(
                name: "test-server", command: "cmd", args: [], env: [:]
            ))
        )
        let mcpCheck = component.deriveDoctorCheck() as? MCPServerCheck
        #expect(mcpCheck?.projectRoot == nil)
    }

    // MARK: - allDoctorChecks combines derived + supplementary

    @Test("allDoctorChecks returns derived + supplementary")
    func allDoctorChecksCombines() {
        let supplementary = CommandCheck(name: "test", section: "Dependencies", command: "test")
        let component = makeComponent(
            displayName: "TestPkg",
            type: .brewPackage,
            installAction: .brewInstall(package: "testpkg"),
            supplementaryChecks: [supplementary]
        )
        let checks = component.allDoctorChecks()
        // 1 derived (CommandCheck from brewInstall) + 1 supplementary
        #expect(checks.count == 2)
    }

    @Test("shellCommand with supplementaryChecks returns only supplementary")
    func shellCommandWithSupplementary() {
        let supplementary = CommandCheck(name: "brew", section: "Dependencies", command: "brew")
        let component = makeComponent(
            type: .brewPackage,
            installAction: .shellCommand(command: "curl ..."),
            supplementaryChecks: [supplementary]
        )
        let checks = component.allDoctorChecks()
        #expect(checks.count == 1)
        #expect(checks.first?.name == "brew")
    }
}

// MARK: - FileHasher directory hashing

struct FileHasherDirectoryHashingTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-dirhash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("directoryFileHashes enumerates files recursively")
    func recursiveEnumeration() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create nested structure
        let subDir = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "file1".write(to: tmpDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "file2".write(to: subDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        let paths = hashes.map(\.relativePath)

        #expect(paths.contains("a.txt"))
        #expect(paths.contains("sub/b.txt"))
        #expect(hashes.count == 2)
    }

    @Test("directoryFileHashes returns sorted results")
    func sortedResults() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "c".write(to: tmpDir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: tmpDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: tmpDir.appendingPathComponent("m.txt"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        let paths = hashes.map(\.relativePath)

        #expect(paths == ["a.txt", "m.txt", "z.txt"])
    }

    @Test("directoryFileHashes skips hidden files")
    func skipsHidden() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "visible".write(to: tmpDir.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: tmpDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let hashes = try FileHasher.directoryFileHashes(at: tmpDir)
        #expect(hashes.count == 1)
        #expect(hashes.first?.relativePath == "visible.txt")
    }
}

// MARK: - FileContentCheck

struct FileContentCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Passes when file content matches expected hash")
    func matchingHash() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("hook.sh")
        try "#!/bin/bash\necho hello".write(to: file, atomically: true, encoding: .utf8)
        let hash = try FileHasher.sha256(of: file)

        let check = FileContentCheck(
            name: "hook.sh",
            section: "Installed Files",
            path: file,
            expectedHash: hash
        )
        if case .pass = check.check() {} else {
            Issue.record("Expected .pass but got \(check.check())")
        }
    }

    @Test("Warns when file content differs from expected hash")
    func driftedContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("hook.sh")
        try "#!/bin/bash\necho hello".write(to: file, atomically: true, encoding: .utf8)
        let originalHash = try FileHasher.sha256(of: file)

        // Modify the file
        try "#!/bin/bash\necho modified".write(to: file, atomically: true, encoding: .utf8)

        let check = FileContentCheck(
            name: "hook.sh",
            section: "Installed Files",
            path: file,
            expectedHash: originalHash
        )
        if case .warn = check.check() {} else {
            Issue.record("Expected .warn but got \(check.check())")
        }
    }

    @Test("Skips when file is missing (existence checked separately)")
    func missingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("nonexistent.sh")

        let check = FileContentCheck(
            name: "nonexistent.sh",
            section: "Installed Files",
            path: file,
            expectedHash: "abc123"
        )
        if case .skip = check.check() {} else {
            Issue.record("Expected .skip but got \(check.check())")
        }
    }

    @Test("Fix returns notFixable")
    func fixNotFixable() {
        let check = FileContentCheck(
            name: "test",
            section: "Installed Files",
            path: URL(fileURLWithPath: "/tmp/test"),
            expectedHash: "abc"
        )
        if case .notFixable = check.fix() {} else {
            Issue.record("Expected .notFixable")
        }
    }
}
