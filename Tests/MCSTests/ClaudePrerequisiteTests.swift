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

        #expect(ensureClaudeCLI(shell: shell, output: silentOutput()))
        #expect(shell.commandExistsCalls.contains(Constants.CLI.claudeCommand))
        #expect(shell.runCalls.isEmpty)
    }

    @Test("A missing claude is reported and mcs installs nothing itself")
    func missingCLIIsNeverInstalled() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false

        #expect(!ensureClaudeCLI(shell: shell, output: silentOutput()))
        #expect(shell.runCalls.isEmpty)
    }
}
