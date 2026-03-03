import ArgumentParser
import Foundation

struct DoctorCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check installation health and diagnose issues"
    )

    @Flag(name: .long, help: "Attempt to automatically fix issues")
    var fix = false

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt before applying fixes")
    var yes = false

    @Option(name: .long, help: "Only check a specific tech pack (e.g. ios)")
    var pack: String?

    @Flag(name: .long, help: "Check globally-configured packs only")
    var global = false

    var skipLock: Bool {
        !fix
    }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )
        var runner = DoctorRunner(
            fixMode: fix,
            skipConfirmation: yes,
            packFilter: pack,
            globalOnly: global,
            registry: registry
        )
        try runner.run()
    }
}
