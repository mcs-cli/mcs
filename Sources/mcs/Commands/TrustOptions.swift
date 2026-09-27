import ArgumentParser

struct TrustOptions: ParsableArguments {
    @Flag(name: .long, help: "Trust pack scripts without prompting (no TTY required)")
    var trustAll: Bool = false

    var policy: PackTrustManager.TrustPolicy {
        trustAll ? .autoAccept : .prompt
    }
}
