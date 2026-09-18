import Foundation
@testable import mcs
import Testing

/// Bootstrap depends on `PackAdder.DuplicatePolicy.autoAccept` short-circuiting the
/// duplicate-identifier and artifact-collision prompts so `mcs bootstrap` stays
/// non-interactive. Any regression that flips either branch back to `askYesNo`
/// would deadlock CI, so these tests pin the policy branches directly.
struct PackAdderPolicyTests {
    private func makeContext(home: URL) -> PackCommandContext {
        let env = Environment(home: home)
        return PackCommandContext(
            env: env,
            output: CLIOutput(colorsEnabled: false),
            shell: ShellRunner(environment: env),
            registry: PackRegistryFile(path: env.packsRegistry)
        )
    }

    private func makeManifest(identifier: String) -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1,
            identifier: identifier,
            displayName: identifier,
            description: "test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
    }

    @Test("autoAccept short-circuits when identifier is already registered from a different source")
    func autoAcceptDuplicateDifferentSource() throws {
        let home = try makeTmpDir(label: "packadder-dup")
        defer { try? FileManager.default.removeItem(at: home) }

        let ctx = makeContext(home: home)
        let adder = PackAdder(ctx: ctx)
        let registry = PackRegistryFile.RegistryData(packs: [
            makeRegistryEntry(identifier: "foo", sourceURL: "https://example.com/original.git"),
        ])

        let proceed = adder.resolveDuplicate(
            manifest: makeManifest(identifier: "foo"),
            sourceURL: "https://example.com/replacement.git",
            registryData: registry,
            policy: .autoAccept
        )
        #expect(proceed)
    }

    @Test("autoAccept short-circuits when identifier is registered from the same source")
    func autoAcceptDuplicateSameSource() throws {
        let home = try makeTmpDir(label: "packadder-dup-same")
        defer { try? FileManager.default.removeItem(at: home) }

        let ctx = makeContext(home: home)
        let adder = PackAdder(ctx: ctx)
        let registry = PackRegistryFile.RegistryData(packs: [
            makeRegistryEntry(identifier: "foo", sourceURL: "https://example.com/foo.git"),
        ])

        let proceed = adder.resolveDuplicate(
            manifest: makeManifest(identifier: "foo"),
            sourceURL: "https://example.com/foo.git",
            registryData: registry,
            policy: .autoAccept
        )
        #expect(proceed)
    }

    @Test("resolveDuplicate returns true when no duplicate exists regardless of policy")
    func noDuplicateAlwaysProceeds() throws {
        let home = try makeTmpDir(label: "packadder-fresh")
        defer { try? FileManager.default.removeItem(at: home) }

        let ctx = makeContext(home: home)
        let adder = PackAdder(ctx: ctx)
        let registry = PackRegistryFile.RegistryData(packs: [])

        #expect(adder.resolveDuplicate(
            manifest: makeManifest(identifier: "foo"),
            sourceURL: "https://example.com/foo.git",
            registryData: registry,
            policy: .autoAccept
        ))
        #expect(adder.resolveDuplicate(
            manifest: makeManifest(identifier: "foo"),
            sourceURL: "https://example.com/foo.git",
            registryData: registry,
            policy: .prompt
        ))
    }

    @Test("acceptCollisions returns true under .autoAccept without prompting")
    func acceptCollisionsAutoAccept() throws {
        let home = try makeTmpDir(label: "packadder-coll")
        defer { try? FileManager.default.removeItem(at: home) }

        let ctx = makeContext(home: home)
        let adder = PackAdder(ctx: ctx)
        #expect(adder.acceptCollisions(policy: .autoAccept))
    }
}
