import Foundation
@testable import mcs
import Testing

struct ClaudePrerequisiteTests {
    private func silentOutput() -> CLIOutput {
        CLIOutput(colorsEnabled: false)
    }

    @Test("A claude already on PATH is accepted without spawning anything")
    func acceptsInstalledCLI() {
        let shell = MockShellRunner()
        shell.commandExistsResult = true

        #expect(ensureClaudeCLI(shell: shell, environment: shell.environment, output: silentOutput()))
        #expect(shell.commandExistsCalls.contains(Constants.CLI.claudeCommand))
        #expect(shell.runCalls.isEmpty)
    }

    @Test("A missing claude is reported, and brew is never asked to install it without brew")
    func missingCLIWithoutHomebrew() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false
        let environment = shell.environment

        #if canImport(Darwin)
        // macOS offers the Homebrew cask when brew is there, and that offer is a prompt — calling
        // it here would read real stdin under swift-testing's parallel runner. So on a machine that
        // does have brew, assert instead what makes the guard safe to evaluate: it is a filesystem
        // check, not a subprocess, which is why gating on it costs nothing.
        guard !Homebrew(shell: shell, environment: environment).isInstalled else {
            #expect(shell.runCalls.isEmpty)
            return
        }
        #endif

        // Without brew — always on Linux, where `claude-code` is a cask Linuxbrew does not have —
        // the answer is the same on both platforms: report it and do not try to install anything.
        #expect(!ensureClaudeCLI(shell: shell, environment: environment, output: silentOutput()))
        #expect(shell.runCalls.isEmpty, "mcs must not attempt an install it cannot perform")
    }
}
