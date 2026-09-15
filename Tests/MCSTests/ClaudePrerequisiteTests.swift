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

    @Test("A missing claude without brew is reported and nothing is installed")
    func missingCLIWithoutHomebrew() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false

        // The same on both platforms: on Linux `claude-code` is a cask Linuxbrew does not have.
        #expect(!ensureClaudeCLI(
            shell: shell, environment: shell.environment, output: silentOutput(),
            brewInstalled: false, confirmInstall: { Issue.record("no prompt without brew"); return true }
        ))
        #expect(shell.runCalls.isEmpty, "mcs must not attempt an install it cannot perform")
    }

    #if canImport(Darwin)
    @Test("Declining the Homebrew offer installs nothing")
    func declinedHomebrewInstall() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false

        #expect(!ensureClaudeCLI(
            shell: shell, environment: shell.environment, output: silentOutput(),
            brewInstalled: true, confirmInstall: { false }
        ))
        #expect(shell.runCalls.isEmpty)
    }

    @Test("Accepting the Homebrew offer runs brew install, then re-probes for claude")
    func acceptedHomebrewInstall() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false

        // The install "succeeds" but claude still is not on PATH, so the outcome is a failure —
        // the assertion that matters is which command was run.
        #expect(!ensureClaudeCLI(
            shell: shell, environment: shell.environment, output: silentOutput(),
            brewInstalled: true, confirmInstall: { true }
        ))
        #expect(shell.runCalls.map(\.arguments) == [["install", "claude-code"]])
        #expect(shell.runCalls.first?.executable == shell.environment.brewPath)
    }
    #else
    @Test("Linux never offers the Homebrew cask, even with brew present and a willing user")
    func linuxNeverOffersHomebrew() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false

        #expect(!ensureClaudeCLI(
            shell: shell, environment: shell.environment, output: silentOutput(),
            brewInstalled: true, confirmInstall: { Issue.record("no prompt on Linux"); return true }
        ))
        #expect(shell.runCalls.isEmpty)
    }
    #endif
}
