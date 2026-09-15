import Foundation

/// Verify that the Claude Code CLI is available, offering an install where mcs can perform one.
///
/// Returns `true` if Claude CLI is available (either already installed or successfully installed).
/// Returns `false` if the user declines installation or installation fails.
@discardableResult
func ensureClaudeCLI(
    shell: any ShellRunning,
    environment: Environment,
    output: CLIOutput
) -> Bool {
    if shell.commandExists(Constants.CLI.claudeCommand) {
        return true
    }

    output.error("Claude Code CLI not found.")
    output.plain("  mcs requires the Claude Code CLI to function.")

    #if canImport(Darwin)
    let brew = Homebrew(shell: shell, environment: environment)
    guard brew.isInstalled else {
        printManualClaudeInstallInstructions(output)
        return false
    }

    guard output.askYesNo("Install Claude Code via Homebrew?", default: true) else {
        printManualClaudeInstallInstructions(output)
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
    printManualClaudeInstallInstructions(output)
    return false
    #else
    // `claude-code` is a Homebrew *cask*, and Linuxbrew has no casks, so offering the brew install
    // would fail on exactly the machines that have brew. Print what does work instead.
    printManualClaudeInstallInstructions(output)
    return false
    #endif
}

/// How to install Claude Code by hand. mcs never runs these itself — piping an installer into a
/// shell, or writing into npm's global prefix, is a trust decision that belongs to the user.
private func printManualClaudeInstallInstructions(_ output: CLIOutput) {
    output.plain("  Install it manually: https://docs.anthropic.com/en/docs/claude-code")
    #if canImport(Darwin)
    // macOS has already been offered the Homebrew cask, so the docs link is the whole answer.
    #else
    output.plain("    curl -fsSL https://claude.ai/install.sh | bash")
    output.plain("    npm install -g @anthropic-ai/claude-code")
    #endif
}
