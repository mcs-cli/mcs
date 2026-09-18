import Foundation
@testable import mcs
import Testing

private func makeContext(home: URL) -> PackCommandContext {
    let env = Environment(home: home)
    return PackCommandContext(
        env: env,
        output: CLIOutput(colorsEnabled: false),
        shell: ShellRunner(environment: env),
        registry: PackRegistryFile(path: env.packsRegistry)
    )
}

/// Bootstrap depends on `PackAdder.DuplicatePolicy.autoAccept` short-circuiting the
/// duplicate-identifier and artifact-collision prompts so `mcs bootstrap` stays
/// non-interactive. Any regression that flips either branch back to `askYesNo`
/// would deadlock CI, so these tests pin the policy branches directly.
struct PackAdderPolicyTests {
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

/// `mcs bootstrap --trust-all` exists so an unattended run can add a pack it has never
/// seen. Proving the flag works means driving the real add pipeline against a real repo to
/// `.installed` — a unit test of `promptForTrust` alone would not catch the policy being
/// dropped somewhere between `Options` and `PackTrustManager`.
///
/// Be aware of what failure looks like: a dropped policy reaches `askYesNo`, which fails
/// cleanly in CI but **blocks on `readLine()`** for anyone running the suite from a terminal,
/// because `swift test > file 2>&1` redirects stdout while stdin stays a TTY. This suite and
/// two in `PackUpdaterTests` are the deliberate exceptions to "no new test reaches the prompt".
struct PackAdderTrustPolicyTests {
    private struct TestSetupError: Error {
        let message: String
    }

    private struct Fixture {
        let tmpDir: URL
        let remoteDir: URL
        let ctx: PackCommandContext

        func cleanup() {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    private func git(_ shell: ShellRunner, _ arguments: [String], context: String) throws {
        let result = shell.run(shell.environment.gitPath, arguments: arguments)
        guard result.succeeded else {
            throw TestSetupError(message: "\(context): \(result.stderr)")
        }
    }

    /// A bare repo holding a pack whose only component is a hook file. A hook is
    /// trustable, so the add pipeline genuinely reaches the trust decision instead of
    /// taking `promptForTrust`'s `items.isEmpty` shortcut.
    private func makeFixture() throws -> Fixture {
        let tmpDir = try makeTmpDir(label: "packadder-trust")
        let remoteDir = tmpDir.appendingPathComponent("remote.git")
        let workDir = tmpDir.appendingPathComponent("work")
        let env = Environment(home: tmpDir)
        let shell = ShellRunner(environment: env)

        try git(shell, ["init", "--bare", remoteDir.path], context: "git init --bare")
        try git(shell, ["clone", remoteDir.path, workDir.path], context: "git clone")
        try git(shell, ["-C", workDir.path, "config", "user.email", "test@mcs.dev"], context: "git config email")
        try git(shell, ["-C", workDir.path, "config", "user.name", "MCS Test"], context: "git config name")
        try git(shell, ["-C", workDir.path, "config", "commit.gpgsign", "false"], context: "git config gpgsign")

        try FileManager.default.createDirectory(
            at: workDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )
        try "echo gate\n".write(
            to: workDir.appendingPathComponent("hooks/gate.sh"),
            atomically: true, encoding: .utf8
        )
        try """
        schemaVersion: 1
        identifier: trust-pack
        displayName: Trust Pack
        description: A pack whose hook requires trust review
        components:
          - id: gate
            displayName: Gate Hook
            description: A hook
            hookEvent: PreToolUse
            hook:
              source: hooks/gate.sh
              destination: gate.sh
        """.write(
            to: workDir.appendingPathComponent("techpack.yaml"),
            atomically: true, encoding: .utf8
        )

        try git(shell, ["-C", workDir.path, "add", "."], context: "git add")
        try git(shell, ["-C", workDir.path, "commit", "-m", "initial"], context: "git commit")
        try git(shell, ["-C", workDir.path, "push"], context: "git push")

        return Fixture(tmpDir: tmpDir, remoteDir: remoteDir, ctx: makeContext(home: tmpDir))
    }

    @Test("autoAccept installs a fresh pack with trustable content and records its hashes")
    func autoAcceptInstallsFreshPack() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let adder = PackAdder(ctx: fix.ctx)
        let outcome = try adder.add(
            source: .gitURL(fix.remoteDir.path),
            ref: nil,
            options: PackAdder.Options(
                duplicatePolicy: .autoAccept,
                showNextSteps: false,
                trustPolicy: .autoAccept
            )
        )

        guard case let .installed(entry) = outcome else {
            Issue.record("Expected .installed, got \(outcome)")
            return
        }
        #expect(entry.identifier == "trust-pack")
        // Auto-accept must still record what it approved: an empty map would leave
        // `mcs pack update` unable to tell a later edit from the trusted original.
        #expect(entry.trustedScriptHashes["hooks/gate.sh"] != nil)

        let persisted = try fix.ctx.loadRegistry().packs
        #expect(persisted.count == 1)
        #expect(persisted.first?.trustedScriptHashes["hooks/gate.sh"] != nil)
    }

    @Test("Options defaults trustPolicy to .prompt")
    func optionsDefaultsToPrompt() {
        #expect(PackAdder.Options().trustPolicy == .prompt)
    }
}
