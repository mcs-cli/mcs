import Foundation
@testable import mcs
import Testing

@Suite("ScriptRunner")
struct ScriptRunnerTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-script-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a runner with default configuration.
    private func makeRunner() -> ScriptRunner {
        ScriptRunner(
            shell: ShellRunner(environment: Environment()),
            output: CLIOutput(colorsEnabled: false)
        )
    }

    /// Write a script file to disk.
    private func writeScript(_ content: String, at url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Path Containment

    @Test("Rejects path traversal with ../")
    func pathTraversalRejected() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        // Script outside the pack directory
        let outsideScript = tmpDir.appendingPathComponent("evil.sh")
        try writeScript("#!/bin/bash\necho hacked", at: outsideScript)

        // Reference it via path traversal from within pack
        let traversalPath = packDir.appendingPathComponent("../evil.sh")

        let runner = makeRunner()
        #expect(throws: ScriptRunner.ScriptError.self) {
            try runner.run(
                script: traversalPath,
                packPath: packDir
            )
        }
    }

    @Test("Rejects script outside pack directory")
    func scriptOutsidePackRejected() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        let otherDir = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let script = otherDir.appendingPathComponent("script.sh")
        try writeScript("#!/bin/bash\necho outside", at: script)

        let runner = makeRunner()
        #expect(throws: ScriptRunner.ScriptError.self) {
            try runner.run(
                script: script,
                packPath: packDir
            )
        }
    }

    @Test("Accepts script inside pack directory")
    func scriptInsidePackAccepted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("run.sh")
        try writeScript("#!/bin/bash\necho inside", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir
        )
        #expect(result.succeeded)
        #expect(result.stdout == "inside")
    }

    @Test("Accepts script in subdirectory of pack")
    func scriptInSubdirectoryAccepted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        let scriptsDir = packDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)

        let script = scriptsDir.appendingPathComponent("configure.sh")
        try writeScript("#!/bin/bash\necho subdir", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir
        )
        #expect(result.succeeded)
        #expect(result.stdout == "subdir")
    }

    // MARK: - Script Not Found

    @Test("Throws for missing script")
    func missingScript() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let missing = packDir.appendingPathComponent("nope.sh")

        let runner = makeRunner()
        #expect(throws: ScriptRunner.ScriptError.scriptNotFound(missing.standardizedFileURL.path)) {
            try runner.run(
                script: missing,
                packPath: packDir
            )
        }
    }

    // MARK: - Environment Variables

    @Test("Standard MCS environment variables are passed to scripts")
    func standardEnvironmentVars() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("env.sh")
        try writeScript("#!/bin/bash\necho \"$MCS_VERSION|$MCS_PACK_PATH\"", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir
        )

        #expect(result.succeeded)
        let parts = result.stdout.split(separator: "|")
        #expect(parts.count == 2)
        #expect(parts[0] == Substring(MCSVersion.current))
        #expect(parts[1] == Substring(packDir.standardizedFileURL.path))
    }

    @Test("Custom environment variables are passed through")
    func customEnvironmentVars() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("custom.sh")
        try writeScript("#!/bin/bash\necho \"$MY_CUSTOM_VAR\"", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir,
            environmentVars: ["MY_CUSTOM_VAR": "hello-world"]
        )

        #expect(result.succeeded)
        #expect(result.stdout == "hello-world")
    }

    // MARK: - Executable Permission

    @Test("Automatically makes non-executable script executable")
    func autoChmod() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("noperm.sh")
        // Write without setting executable permission
        try "#!/bin/bash\necho fixed".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir
        )

        #expect(result.succeeded)
        #expect(result.stdout == "fixed")
    }

    // MARK: - Timeout

    @Test("Script is terminated when exceeding timeout")
    func timeoutKillsScript() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("slow.sh")
        try writeScript("#!/bin/bash\nsleep 30\necho done", at: script)

        let runner = makeRunner()
        #expect(throws: ScriptRunner.ScriptError.timeout(1)) {
            try runner.run(
                script: script,
                packPath: packDir,
                timeout: 1
            )
        }
    }

    // MARK: - Exit Code

    @Test("Non-zero exit code captured in result")
    func nonZeroExitCode() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let script = packDir.appendingPathComponent("fail.sh")
        try writeScript("#!/bin/bash\necho oops >&2\nexit 42", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir
        )

        #expect(!result.succeeded)
        #expect(result.exitCode == 42)
        #expect(result.stderr == "oops")
    }

    // MARK: - runCommand

    @Test("runCommand executes a shell command string")
    func runCommandBasic() {
        let runner = makeRunner()
        let result = runner.runCommand("echo hello-cmd")

        #expect(result.succeeded)
        #expect(result.stdout == "hello-cmd")
    }

    @Test("runCommand captures non-zero exit code")
    func runCommandFailure() {
        let runner = makeRunner()
        let result = runner.runCommand("exit 7")

        #expect(!result.succeeded)
        #expect(result.exitCode == 7)
    }

    // MARK: - Working Directory

    @Test("Script runs in specified working directory")
    func workingDirectory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        let workDir = tmpDir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Create a marker file in workDir
        try "marker".write(
            to: workDir.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )

        let script = packDir.appendingPathComponent("check-wd.sh")
        try writeScript("#!/bin/bash\ncat marker.txt", at: script)

        let runner = makeRunner()
        let result = try runner.run(
            script: script,
            packPath: packDir,
            workingDirectory: workDir.path
        )

        #expect(result.succeeded)
        #expect(result.stdout == "marker")
    }
}
