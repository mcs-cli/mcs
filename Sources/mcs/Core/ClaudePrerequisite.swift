import Foundation

/// Verify that the Claude Code CLI is on PATH, printing how to install it when it is not.
///
/// mcs never installs it itself. The recommended native installer, the only install that keeps
/// itself updated, pipes a remote script into a shell, and that trust decision belongs to the user.
@discardableResult
func ensureClaudeCLI(shell: any ShellRunning, output: CLIOutput) -> Bool {
    if shell.commandExists(Constants.CLI.claudeCommand) {
        return true
    }

    output.error("Claude Code CLI not found.")
    output.plain("  mcs requires the Claude Code CLI. Install it with the native installer, which keeps it updated:")
    output.plain("    curl -fsSL https://claude.ai/install.sh | bash")
    output.plain("  Other methods (Homebrew, npm, apt, dnf): https://code.claude.com/docs/en/setup")
    return false
}
