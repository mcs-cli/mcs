import Foundation
@testable import mcs
import Testing

struct ShellRunnerTests {
    private var shell: ShellRunner {
        ShellRunner(environment: Environment())
    }

    @Test("run captures stdout")
    func capturesStdout() {
        let result = shell.run("/bin/echo", arguments: ["hello"])
        #expect(result.succeeded)
        #expect(result.stdout == "hello")
    }

    @Test("run captures stderr")
    func capturesStderr() {
        let result = shell.shell("echo error >&2")
        #expect(result.stderr == "error")
    }

    @Test("run returns non-zero exit code for failing commands")
    func nonZeroExitCode() {
        let result = shell.run("/usr/bin/false")
        #expect(!result.succeeded)
        #expect(result.exitCode != 0)
    }

    @Test("run returns failure for nonexistent executable")
    func nonexistentExecutable() {
        let result = shell.run("/nonexistent/binary")
        #expect(!result.succeeded)
    }

    @Test("commandExists returns true for known commands")
    func commandExistsTrue() {
        #expect(shell.commandExists("echo"))
    }

    @Test("commandExists returns false for unknown commands")
    func commandExistsFalse() {
        #expect(!shell.commandExists("this-command-definitely-does-not-exist-xyz"))
    }

    @Test("stdin is redirected to /dev/null preventing subprocess hang")
    func stdinRedirectPreventsHang() {
        // `read` blocks on stdin indefinitely if stdin is a TTY.
        // With FileHandle.nullDevice, it gets immediate EOF and exits.
        // A 5-second timeout ensures we detect a hang.
        let result = shell.shell("read -t 1 line; echo done")
        #expect(result.stdout == "done")
    }

    @Test("shell runs command via bash")
    func shellRunsViaBash() {
        let result = shell.shell("echo $BASH_VERSION")
        #expect(result.succeeded)
        #expect(!result.stdout.isEmpty)
    }

    @Test("additionalEnvironment is passed to subprocess")
    func additionalEnvironment() {
        let result = shell.run(
            Constants.CLI.bash,
            arguments: ["-c", "echo $MCS_TEST_VAR"],
            additionalEnvironment: ["MCS_TEST_VAR": "test_value"]
        )
        #expect(result.stdout == "test_value")
    }
}
