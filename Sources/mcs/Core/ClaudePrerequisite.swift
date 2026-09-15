import Foundation

/// Verify that the Claude Code CLI is available, offering an install where mcs can perform one.
///
/// Returns `true` if Claude CLI is available (either already installed or successfully installed).
/// Returns `false` if the user declines installation or installation fails.
///
/// `brewInstalled` and `confirmInstall` default to the real filesystem check and the real prompt;
/// tests pass both so every macOS branch runs without a Homebrew on the host or a terminal on
/// stdin.
@discardableResult
func ensureClaudeCLI(
    shell: any ShellRunning,
    environment: Environment,
    output: CLIOutput,
    brewInstalled: Bool? = nil,
    confirmInstall: (() -> Bool)? = nil
) -> Bool {
    if shell.commandExists(Constants.CLI.claudeCommand) {
        return true
    }

    output.error("Claude Code CLI not found.")
    output.plain("  mcs requires the Claude Code CLI to function.")

    #if canImport(Darwin)
    let brew = Homebrew(shell: shell, environment: environment)
    guard brewInstalled ?? brew.isInstalled else {
        printManualClaudeInstallInstructions(output)
        return false
    }

    let confirm = confirmInstall ?? { output.askYesNo("Install Claude Code via Homebrew?", default: true) }
    guard confirm() else {
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
    #if !canImport(Darwin)
    // On macOS the caller owns the Homebrew route; here the manual ones are all there is.
    output.plain("    curl -fsSL https://claude.ai/install.sh | bash")
    output.plain("    npm install -g @anthropic-ai/claude-code")
    #endif
}
