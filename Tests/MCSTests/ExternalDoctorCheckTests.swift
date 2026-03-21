import Foundation
@testable import mcs
import Testing

struct ExternalDoctorCheckTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-extdoc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeScriptRunner() -> ScriptRunner {
        let env = Environment()
        let shell = ShellRunner(environment: env)
        let output = CLIOutput(colorsEnabled: false)
        return ScriptRunner(shell: shell, output: output)
    }

    // MARK: - ExternalCommandExistsCheck

    @Test("Command exists check passes for known command")
    func commandExistsKnown() {
        let check = ExternalCommandExistsCheck(
            name: "ls",
            section: "Dependencies",
            command: "/bin/ls",
            args: [],
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Command exists check fails when args fail even if command is on PATH")
    func commandExistsWithFailingArgs() {
        let check = ExternalCommandExistsCheck(
            name: "bogus subcommand",
            section: "Dependencies",
            command: "/bin/ls",
            args: ["--nonexistent-flag-xyz"],
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case .fail = result {
            // expected — args failed, PATH fallback should NOT rescue it
        } else {
            Issue.record("Expected .fail when args fail, got \(result)")
        }
    }

    @Test("Command exists check fails for unknown command")
    func commandExistsUnknown() {
        let check = ExternalCommandExistsCheck(
            name: "nonexistent-tool",
            section: "Dependencies",
            command: "nonexistent-tool-xyz-12345",
            args: [],
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("Command exists fix returns notFixable when no fix command")
    func commandExistsNoFix() {
        let check = ExternalCommandExistsCheck(
            name: "test",
            section: "Dependencies",
            command: "nonexistent",
            args: [],
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.fix()
        if case .notFixable = result {
            // expected
        } else {
            Issue.record("Expected .notFixable, got \(result)")
        }
    }

    // MARK: - ExternalFileExistsCheck

    @Test("File exists check passes for existing file")
    func fileExistsPass() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileExistsCheck(
            name: "test file",
            section: "Files",
            path: file.path,
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("File exists check fails for missing file")
    func fileExistsFail() {
        let check = ExternalFileExistsCheck(
            name: "missing file",
            section: "Files",
            path: "/tmp/nonexistent-\(UUID().uuidString).txt",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("File exists check skips for project scope without project root")
    func fileExistsSkipNoProject() {
        let check = ExternalFileExistsCheck(
            name: "project file",
            section: "Files",
            path: "some-file.txt",
            scope: .project,
            projectRoot: nil
        )
        let result = check.check()
        if case .skip = result {
            // expected
        } else {
            Issue.record("Expected .skip, got \(result)")
        }
    }

    @Test("File exists check resolves project-scoped path")
    func fileExistsProjectScope() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("config.yml")
        try "key: value".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileExistsCheck(
            name: "config",
            section: "Files",
            path: "config.yml",
            scope: .project,
            projectRoot: tmpDir
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    // MARK: - ExternalDirectoryExistsCheck

    @Test("Directory exists check passes for existing directory")
    func directoryExistsPass() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ExternalDirectoryExistsCheck(
            name: "tmp dir",
            section: "Files",
            path: tmpDir.path,
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Directory exists check fails for missing directory")
    func directoryExistsFail() {
        let check = ExternalDirectoryExistsCheck(
            name: "missing dir",
            section: "Files",
            path: "/tmp/nonexistent-dir-\(UUID().uuidString)",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    // MARK: - ExternalFileContainsCheck

    @Test("File contains check passes when pattern is present")
    func fileContainsPass() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("config.txt")
        try "enable_feature=true\nmode=production".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileContainsCheck(
            name: "feature flag",
            section: "Configuration",
            path: file.path,
            pattern: "enable_feature=true",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("File contains check fails when pattern is absent")
    func fileContainsFail() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("config.txt")
        try "enable_feature=false".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileContainsCheck(
            name: "feature flag",
            section: "Configuration",
            path: file.path,
            pattern: "enable_feature=true",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    // MARK: - ExternalFileNotContainsCheck

    @Test("File not contains check passes when pattern is absent")
    func fileNotContainsPass() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("clean.txt")
        try "safe content here".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileNotContainsCheck(
            name: "no secrets",
            section: "Security",
            path: file.path,
            pattern: "SECRET_KEY=",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("File not contains check fails when pattern is present")
    func fileNotContainsFail() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("bad.txt")
        try "SECRET_KEY=hunter2".write(to: file, atomically: true, encoding: .utf8)

        let check = ExternalFileNotContainsCheck(
            name: "no secrets",
            section: "Security",
            path: file.path,
            pattern: "SECRET_KEY=",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("File not contains check passes when file does not exist")
    func fileNotContainsMissingFile() {
        let check = ExternalFileNotContainsCheck(
            name: "no secrets",
            section: "Security",
            path: "/tmp/nonexistent-\(UUID().uuidString).txt",
            pattern: "SECRET_KEY=",
            scope: .global,
            projectRoot: nil
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    // MARK: - ExternalShellScriptCheck

    @Test("Shell script check passes with exit code 0")
    func shellScriptPass() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let script = tmpDir.appendingPathComponent("check.sh")
        try "#!/bin/bash\necho 'all good'\nexit 0".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let check = ExternalShellScriptCheck(
            name: "custom check",
            section: "Custom",
            scriptPath: script,
            packPath: tmpDir,
            fixScriptPath: nil,
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case let .pass(msg) = result {
            #expect(msg == "all good")
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("Shell script check fails with exit code 1")
    func shellScriptFail() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let script = tmpDir.appendingPathComponent("check.sh")
        try "#!/bin/bash\necho 'something wrong'\nexit 1".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let check = ExternalShellScriptCheck(
            name: "custom check",
            section: "Custom",
            scriptPath: script,
            packPath: tmpDir,
            fixScriptPath: nil,
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg == "something wrong")
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("Shell script check warns with exit code 2")
    func shellScriptWarn() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let script = tmpDir.appendingPathComponent("check.sh")
        try "#!/bin/bash\necho 'heads up'\nexit 2".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let check = ExternalShellScriptCheck(
            name: "custom check",
            section: "Custom",
            scriptPath: script,
            packPath: tmpDir,
            fixScriptPath: nil,
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg == "heads up")
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("Shell script check skips with exit code 3")
    func shellScriptSkip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let script = tmpDir.appendingPathComponent("check.sh")
        try "#!/bin/bash\necho 'not applicable'\nexit 3".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let check = ExternalShellScriptCheck(
            name: "custom check",
            section: "Custom",
            scriptPath: script,
            packPath: tmpDir,
            fixScriptPath: nil,
            fixCommand: nil,
            scriptRunner: makeScriptRunner()
        )
        let result = check.check()
        if case let .skip(msg) = result {
            #expect(msg == "not applicable")
        } else {
            Issue.record("Expected .skip, got \(result)")
        }
    }

    // MARK: - Factory

    @Test("Factory creates correct check type from definition")
    func factoryCreatesCorrectType() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .commandExists,
            name: "git check",
            section: "Dependencies",
            command: "git",
            args: ["--version"],
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: nil,
            expectedValue: nil,
            isOptional: nil
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check.name == "git check")
        #expect(check.section == "Dependencies")
    }

    @Test("Factory defaults section to 'External Pack' when nil")
    func factoryDefaultsSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .fileExists,
            name: "config file",
            section: nil,
            command: nil,
            args: nil,
            path: "/tmp/test.txt",
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: nil,
            expectedValue: nil,
            isOptional: nil
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check.section == "External Pack")
    }

    @Test("Factory creates hookEventExists check from definition")
    func factoryCreatesHookEventExistsCheck() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .hookEventExists,
            name: "SessionStart hook",
            section: "Hooks",
            command: nil,
            args: nil,
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: "SessionStart",
            keyPath: nil,
            expectedValue: nil,
            isOptional: false
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check is ExternalHookEventExistsCheck)
        #expect(check.name == "SessionStart hook")
        #expect(check.section == "Hooks")
    }

    @Test("Factory creates settingsKeyEquals check from definition")
    func factoryCreatesSettingsKeyEqualsCheck() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .settingsKeyEquals,
            name: "Plan mode",
            section: "Settings",
            command: nil,
            args: nil,
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: "permissions.defaultMode",
            expectedValue: "plan",
            isOptional: nil
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check is ExternalSettingsKeyEqualsCheck)
        #expect(check.name == "Plan mode")
        #expect(check.section == "Settings")
    }

    @Test("Factory returns misconfigured for hookEventExists without event")
    func factoryHookEventExistsMisconfigured() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .hookEventExists,
            name: "Bad hook check",
            section: nil,
            command: nil,
            args: nil,
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: nil,
            expectedValue: nil,
            isOptional: nil
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check is MisconfiguredDoctorCheck)
    }

    @Test("Factory returns misconfigured for settingsKeyEquals without keyPath")
    func factorySettingsKeyEqualsMisconfigured() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let definition = ExternalDoctorCheckDefinition(
            type: .settingsKeyEquals,
            name: "Bad settings check",
            section: nil,
            command: nil,
            args: nil,
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: nil,
            expectedValue: nil,
            isOptional: nil
        )

        let check = ExternalDoctorCheckFactory.makeCheck(
            from: definition,
            packPath: tmpDir,
            projectRoot: nil,
            scriptRunner: makeScriptRunner()
        )

        #expect(check is MisconfiguredDoctorCheck)
    }

    // MARK: - ScopedPathCheck Path Traversal

    @Test("Project-scoped file check blocks ../ path traversal")
    func fileExistsProjectScopeTraversal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectDir = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create a secret file outside the project
        try "secret".write(to: tmpDir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let check = ExternalFileExistsCheck(
            name: "traversal attempt",
            section: "Test",
            path: "../secret.txt",
            scope: .project,
            projectRoot: projectDir
        )
        let result = check.check()
        // Should NOT pass — path escapes project root
        if case .pass = result {
            Issue.record("Expected path traversal to be blocked, but check passed")
        }
    }

    @Test("Project-scoped file check blocks symlink escaping project root")
    func fileExistsProjectScopeSymlinkEscape() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectDir = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create secret file outside project
        let outsideFile = tmpDir.appendingPathComponent("secret.txt")
        try "secret data".write(to: outsideFile, atomically: true, encoding: .utf8)

        // Create symlink inside project pointing outside
        try FileManager.default.createSymbolicLink(
            at: projectDir.appendingPathComponent("link.txt"),
            withDestinationURL: outsideFile
        )

        let check = ExternalFileExistsCheck(
            name: "symlink escape",
            section: "Test",
            path: "link.txt",
            scope: .project,
            projectRoot: projectDir
        )
        let result = check.check()
        // Symlink resolves outside project root — should be blocked
        if case .pass = result {
            Issue.record("Expected symlink escape to be blocked, but check passed")
        }
    }

    @Test("Project-scoped directory check blocks symlink escaping project root")
    func dirExistsProjectScopeSymlinkEscape() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectDir = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Create directory outside project
        let outsideDir = tmpDir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        // Symlink from inside project to outside directory
        try FileManager.default.createSymbolicLink(
            at: projectDir.appendingPathComponent("link-dir"),
            withDestinationURL: outsideDir
        )

        let check = ExternalDirectoryExistsCheck(
            name: "symlink dir escape",
            section: "Test",
            path: "link-dir",
            scope: .project,
            projectRoot: projectDir
        )
        let result = check.check()
        if case .pass = result {
            Issue.record("Expected symlink directory escape to be blocked, but check passed")
        }
    }

    @Test("Project-scoped fileContains check blocks symlink escape")
    func fileContainsProjectScopeSymlinkEscape() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectDir = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Secret file with known pattern outside project
        let outsideFile = tmpDir.appendingPathComponent("config.txt")
        try "API_KEY=secret123".write(to: outsideFile, atomically: true, encoding: .utf8)

        // Symlink inside project
        try FileManager.default.createSymbolicLink(
            at: projectDir.appendingPathComponent("config.txt"),
            withDestinationURL: outsideFile
        )

        let check = ExternalFileContainsCheck(
            name: "symlink config escape",
            section: "Test",
            path: "config.txt",
            pattern: "API_KEY",
            scope: .project,
            projectRoot: projectDir
        )
        let result = check.check()
        if case .pass = result {
            Issue.record("Expected symlink escape to be blocked for fileContains, but check passed")
        }
    }
}
