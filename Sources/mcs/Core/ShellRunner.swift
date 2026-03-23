import Foundation

/// Result of running a shell command.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool {
        exitCode == 0
    }
}

/// Protocol for shell command execution, enabling test mocks to avoid real process spawning.
protocol ShellRunning: Sendable {
    /// The environment providing paths and configuration.
    var environment: Environment { get }

    /// Check if a command exists on PATH.
    func commandExists(_ command: String) -> Bool

    /// Run an executable with arguments, capturing stdout and stderr.
    @discardableResult
    func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String?,
        additionalEnvironment: [String: String]
    ) -> ShellResult

    /// Run a shell command string via /bin/bash -c.
    @discardableResult
    func shell(
        _ command: String,
        workingDirectory: String?,
        additionalEnvironment: [String: String]
    ) -> ShellResult
}

// MARK: - Default Parameter Values

extension ShellRunning {
    @discardableResult
    func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> ShellResult {
        run(executable, arguments: arguments, workingDirectory: workingDirectory, additionalEnvironment: additionalEnvironment)
    }

    @discardableResult
    func shell(
        _ command: String,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> ShellResult {
        shell(command, workingDirectory: workingDirectory, additionalEnvironment: additionalEnvironment)
    }
}

/// Runs shell commands and captures output.
struct ShellRunner: ShellRunning {
    let environment: Environment

    /// Check if a command exists on PATH.
    func commandExists(_ command: String) -> Bool {
        let result = run(Constants.CLI.which, arguments: [command])
        return result.succeeded
    }

    /// Run an executable with arguments, capturing stdout and stderr.
    @discardableResult
    func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = environment.pathWithBrew
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
        // Prevent subprocesses from blocking on stdin.
        // Without this, interactive commands (e.g. npx prompts) inherit the
        // parent's TTY and can deadlock: the child waits for stdin while
        // readDataToEndOfFile blocks waiting for stdout EOF.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock.
        // If a child process fills the pipe buffer (~64KB), waitUntilExit blocks
        // because the child can't write more, creating a circular wait.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    /// Run a shell command string via /bin/bash -c.
    @discardableResult
    func shell(
        _ command: String,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> ShellResult {
        run(
            Constants.CLI.bash,
            arguments: ["-c", command],
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment
        )
    }
}
