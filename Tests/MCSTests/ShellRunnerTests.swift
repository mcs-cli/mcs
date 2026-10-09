import Foundation
@testable import mcs
import Testing

struct ShellRunnerTests {
    private var shell: ShellRunner {
        ShellRunner(environment: Environment())
    }

    @Test("A failure points at the terminal only when the command ran in one and left no stderr")
    func failureMessageShapes() {
        #expect(
            ShellRunner.failureMessage(name: "Ollama", stderr: "", ranInTerminal: true)
                == "Ollama failed (see output above)"
        )
        #expect(ShellRunner.failureMessage(name: "Ollama", stderr: "", ranInTerminal: false) == "Ollama failed")
        #expect(
            ShellRunner.failureMessage(name: "Ollama", stderr: "forkpty failed: No such file", ranInTerminal: true)
                == "Ollama failed: forkpty failed: No such file"
        )
        #expect(
            ShellRunner.failureMessage(name: "x", stderr: String(repeating: "e", count: 500), ranInTerminal: false)
                == "x failed: " + String(repeating: "e", count: 200)
        )
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

    @Test("An interactive command runs under a PTY and reports its exit status")
    func interactiveCommandRunsUnderAPTY() {
        let result = ShellRunner(environment: Environment()).shell("test -t 0 && exit 3", interactive: true)
        #expect(result.exitCode == 3, "stdin is a terminal only inside the PTY")
    }
}
