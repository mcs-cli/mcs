import Foundation

/// Verify that the Claude Code CLI is available, offering to install via Homebrew if missing.
///
/// Returns `true` if Claude CLI is available (either already installed or successfully installed).
/// Returns `false` if the user declines installation or installation fails.
@discardableResult
func ensureClaudeCLI(
    shell: ShellRunner,
    environment: Environment,
    output: CLIOutput
) -> Bool {
    if shell.commandExists(Constants.CLI.claudeCommand) {
        return true
    }

    output.error("Claude Code CLI not found.")
    output.plain("  mcs requires the Claude Code CLI to function.")

    let brew = Homebrew(shell: shell, environment: environment)
    guard brew.isInstalled else {
        output.plain("  Install it manually: https://docs.anthropic.com/en/docs/claude-code")
        return false
    }

    guard output.askYesNo("Install Claude Code via Homebrew?", default: true) else {
        output.plain("  Install it manually: https://docs.anthropic.com/en/docs/claude-code")
        return false
    }

    output.dimmed("Installing Claude Code...")
    let result = brew.install("claude-code")
    if result.succeeded, shell.commandExists(Constants.CLI.claudeCommand) {
        output.success("Claude Code installed")
        return true
    }

    output.error("Failed to install Claude Code.")
    if !result.stderr.isEmpty {
        output.dimmed(String(result.stderr.prefix(200)))
    }
    output.plain("  Install it manually: https://docs.anthropic.com/en/docs/claude-code")
    return false
}
