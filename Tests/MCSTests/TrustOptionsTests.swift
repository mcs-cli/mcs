@testable import mcs
import Testing

struct TrustOptionsTests {
    @Test("--trust-all is the only thing that selects .autoAccept")
    func trustAllFlagSelectsAutoAccept() throws {
        // Pins the flag's spelling and the direction of the mapping on every command that
        // includes it. Without this, a renamed flag, an inverted ternary or a dropped
        // `@OptionGroup` would ship green — every other trust test constructs the policy directly.
        #expect(try BootstrapCommand.parse([]).trust.policy == .prompt)
        #expect(try BootstrapCommand.parse(["--trust-all"]).trust.policy == .autoAccept)
        #expect(try BootstrapCommand.parse(["--prune", "--yes"]).trust.policy == .prompt)
        #expect(try UpdateCommand.parse(["--all-projects"]).trust.policy == .prompt)
        #expect(try UpdateCommand.parse(["--trust-all"]).trust.policy == .autoAccept)
        #expect(try UpdatePack.parse(["some-pack"]).trust.policy == .prompt)
        #expect(try UpdatePack.parse(["--trust-all"]).trust.policy == .autoAccept)
    }
}
