import Foundation
@testable import mcs
import Testing

@Suite("Homebrew")
struct HomebrewTests {
    // MARK: - bareName

    @Test("bareName strips a tap qualifier and nothing else", arguments: [
        (package: "getsentry/xcodebuildmcp/xcodebuildmcp", expected: "xcodebuildmcp"),
        (package: "node", expected: "node"),
        (package: "node@22", expected: "node@22"),
    ])
    func bareName(package: String, expected: String) {
        #expect(Homebrew.bareName(of: package) == expected)
    }

    // MARK: - provides

    @Test("provides takes the PATH fast path without spawning brew")
    func providesUsesPath() {
        let shell = MockShellRunner()
        shell.commandExistsResult = true

        #expect(Homebrew(shell: shell, environment: shell.environment).provides("node"))
        #expect(shell.runCalls.isEmpty)
    }

    @Test("provides probes PATH under the bare name, not the tap-qualified one")
    func providesProbesBareName() {
        let shell = MockShellRunner()
        shell.commandExistsResult = true

        _ = Homebrew(shell: shell, environment: shell.environment)
            .provides("getsentry/xcodebuildmcp/xcodebuildmcp")

        #expect(shell.commandExistsCalls == ["xcodebuildmcp"])
    }

    /// The `ripgrep` → `rg` case: installed, but under a name PATH will never match.
    @Test("provides falls back to brew when the command is not on PATH")
    func providesFallsBackToBrew() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false
        shell.result = ShellResult(exitCode: 0, stdout: "", stderr: "")

        #expect(Homebrew(shell: shell, environment: shell.environment).provides("ripgrep"))
        #expect(shell.runCalls.last?.arguments == ["list", "ripgrep"])
    }

    @Test("provides asks brew about the tap-qualified name, which is the only one it knows")
    func providesQueriesBrewWithFullName() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false
        shell.result = ShellResult(exitCode: 0, stdout: "", stderr: "")

        _ = Homebrew(shell: shell, environment: shell.environment)
            .provides("getsentry/xcodebuildmcp/xcodebuildmcp")

        #expect(shell.runCalls.last?.arguments == ["list", "getsentry/xcodebuildmcp/xcodebuildmcp"])
    }

    @Test("provides is false when neither PATH nor brew has the package")
    func providesFalseWhenAbsent() {
        let shell = MockShellRunner()
        shell.commandExistsResult = false
        shell.result = ShellResult(exitCode: 1, stdout: "", stderr: "")

        #expect(!Homebrew(shell: shell, environment: shell.environment).provides("nope"))
    }
}
