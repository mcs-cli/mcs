import ArgumentParser

struct TrustOptions: ParsableArguments {
    @Flag(name: .long, help: "Trust pack executable content without prompting (no TTY required)")
    var trustAll: Bool = false

    var policy: PackTrustManager.TrustPolicy {
        trustAll ? .autoAccept : .prompt
    }

    /// Off a TTY the trust prompt takes its `false` default, so a decline reads as "the user
    /// said no" when it may mean there was nobody to ask. Redirected stdin carrying a real "n"
    /// is equally off-TTY, though, so the hint offers the possibility rather than asserting it.
    func hintIfUnattended(output: CLIOutput, subject: String) {
        guard !trustAll, !output.hasInteractiveStdin else { return }
        output.plain("  If no terminal was available to answer the trust prompt, pass")
        output.plain("  --trust-all to approve \(subject) without review.")
    }
}
