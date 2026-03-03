import Foundation
import os

/// Higher-level wrapper around `ShellRunner` for executing scripts from external packs.
/// Adds pack-specific concerns: path containment validation, standard environment
/// variables, timeout enforcement, and executable permission enforcement (auto-chmod).
struct ScriptRunner: Sendable {
    let shell: ShellRunner
    let output: CLIOutput

    /// Result of running an external pack script.
    struct ScriptResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool {
            exitCode == 0
        }
    }

    /// Errors specific to script execution.
    enum ScriptError: Error, Equatable, Sendable, LocalizedError {
        case pathTraversal(script: String, packPath: String)
        case scriptNotFound(String)
        case timeout(TimeInterval)

        var errorDescription: String? {
            switch self {
            case let .pathTraversal(script, packPath):
                "Script '\(script)' escapes pack directory '\(packPath)'"
            case let .scriptNotFound(path):
                "Script not found: '\(path)'"
            case let .timeout(seconds):
                "Script timed out after \(Int(seconds)) seconds"
            }
        }
    }

    // MARK: - Script Execution

    /// Run a script file from a pack with environment variables and timeout.
    ///
    /// - Parameters:
    ///   - script: URL of the script to execute
    ///   - packPath: Root directory of the pack (for path containment check)
    ///   - environmentVars: Additional env vars (e.g., resolved prompt values)
    ///   - workingDirectory: Working directory for the script
    ///   - timeout: Maximum execution time in seconds (default 30)
    /// - Returns: Script execution result
    /// - Throws: `ScriptError` for path traversal, missing script, or timeout
    func run(
        script: URL,
        packPath: URL,
        environmentVars: [String: String] = [:],
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> ScriptResult {
        // 1. Path containment: resolve symlinks and verify script is within packPath
        let resolvedScript = script.resolvingSymlinksInPath().path
        let resolvedPack = packPath.resolvingSymlinksInPath().path

        guard PathContainment.isContained(path: resolvedScript, within: resolvedPack) else {
            throw ScriptError.pathTraversal(script: resolvedScript, packPath: resolvedPack)
        }

        // 2. Verify script exists (using resolved path)
        guard FileManager.default.fileExists(atPath: resolvedScript) else {
            throw ScriptError.scriptNotFound(resolvedScript)
        }

        // 3. Ensure executable permission
        ensureExecutable(at: resolvedScript)

        // 4. Build environment variables
        var env = environmentVars
        env["MCS_VERSION"] = MCSVersion.current
        env["MCS_PACK_PATH"] = resolvedPack

        // 5. Execute with timeout
        return try executeWithTimeout(
            executable: resolvedScript,
            arguments: [],
            workingDirectory: workingDirectory,
            additionalEnvironment: env,
            timeout: timeout
        )
    }

    /// Run a single command string (for fixCommand in doctor checks).
    /// This method executes via `/bin/bash -c` **without** path containment.
    ///
    /// - Parameters:
    ///   - command: Shell command to execute via `/bin/bash -c`
    ///   - timeout: Maximum execution time in seconds (default 10)
    /// - Returns: Script execution result
    func runCommand(
        _ command: String,
        timeout: TimeInterval = 10
    ) -> ScriptResult {
        do {
            return try executeWithTimeout(
                executable: Constants.CLI.bash,
                arguments: ["-c", command],
                workingDirectory: nil,
                additionalEnvironment: ["MCS_VERSION": MCSVersion.current],
                timeout: timeout
            )
        } catch let error as ScriptError {
            return ScriptResult(
                exitCode: 1,
                stdout: "",
                stderr: error.errorDescription ?? error.localizedDescription
            )
        } catch {
            return ScriptResult(
                exitCode: 1,
                stdout: "",
                stderr: "[launch error] \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Internal Helpers

    /// Ensure the file at the given path has executable permission.
    private func ensureExecutable(at path: String) {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: path) {
            do {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            } catch {
                output.warn("Could not set executable permission on '\(path)': \(error.localizedDescription)")
            }
        }
    }

    /// Execute a process with a timeout, killing it if it exceeds the limit.
    private func executeWithTimeout(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        additionalEnvironment: [String: String],
        timeout: TimeInterval
    ) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shell.environment.pathWithBrew
        for (key, value) in additionalEnvironment {
            env[key] = value
        }
        process.environment = env

        if let cwd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ScriptError.scriptNotFound("\(executable) (launch failed: \(error.localizedDescription))")
        }

        // Schedule timeout on a background queue
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let workItem = DispatchWorkItem { [process] in
            if process.isRunning {
                timedOut.withLock { $0 = true }
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout,
            execute: workItem
        )

        // Read output before waiting (prevents deadlock on full pipe buffer)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Cancel timeout if process finished in time
        workItem.cancel()

        if timedOut.withLock({ $0 }) {
            throw ScriptError.timeout(timeout)
        }

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""

        return ScriptResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}
