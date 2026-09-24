import Foundation
@testable import mcs
import Testing

struct BootstrapUnmatchedSeedKeysTests {
    @Test("Only keys matching neither a prompt nor a placeholder are unmatched")
    func reportsOnlyTypoKeys() {
        let pack = MockPromptTechPack(
            identifier: "seed-pack",
            displayName: "Seed Pack",
            prompts: [PromptDefinition(
                key: "LABEL_PREFIX", type: .input,
                label: nil, defaultValue: nil, options: nil,
                detectPatterns: nil, scriptCommand: nil
            )],
            components: [ComponentDefinition(
                id: "seed-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "seed-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test", command: "npx", args: [], env: ["TOKEN": "__API_TOKEN__"]
                ))
            )]
        )
        let file = BootstrapFile(schemaVersion: 1, packs: [
            .init(source: "org/seed-pack", values: [
                "LABEL_PREFIX": "scope:",
                "API_TOKEN": "secret",
                "API_TOKNE": "secret",
            ]),
        ])
        let context = ProjectConfigContext(
            projectPath: FileManager.default.temporaryDirectory,
            repoName: "",
            output: CLIOutput(colorsEnabled: false)
        )

        let unmatched = BootstrapCommand.unmatchedSeedKeys(
            file: file, packs: [pack], context: context, includeTemplates: true
        )

        #expect(unmatched == ["API_TOKNE"])
    }
}

/// Bootstrap's same-ref short-circuit is what #403 broke: it must not vouch for a checkout
/// that is gone. `perform()` reads the real `~/.mcs`, so the reconcile step is driven directly.
struct BootstrapReconcileMissingCheckoutTests {
    private struct TestSetupError: Error {
        let message: String
    }

    private struct Fixture {
        let tmpDir: URL
        let remoteDir: URL
        let ctx: PackCommandContext
        let taggedSHA: String
        let tipSHA: String
        let entry: PackRegistryFile.PackEntry

        var packPath: URL {
            ctx.env.packsDirectory.appendingPathComponent("boot-pack")
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    private func git(_ shell: ShellRunner, _ arguments: [String], context: String) throws -> String {
        let result = shell.run(shell.environment.gitPath, arguments: arguments)
        guard result.succeeded else {
            throw TestSetupError(message: "\(context): \(result.stderr)")
        }
        return result.stdout
    }

    /// A remote with tag `v1` on the first commit and one commit past it, registered at `v1`'s
    /// commit with no checkout on disk.
    private func makeFixture() throws -> Fixture {
        let tmpDir = try makeTmpDir(label: "bootstrap-reconcile")
        let remoteDir = tmpDir.appendingPathComponent("remote.git")
        let workDir = tmpDir.appendingPathComponent("work")
        let env = Environment(home: tmpDir)
        let shell = ShellRunner(environment: env)

        _ = try git(shell, ["init", "--bare", remoteDir.path], context: "git init --bare")
        _ = try git(shell, ["clone", remoteDir.path, workDir.path], context: "git clone")
        for (key, value) in [("user.email", "test@mcs.dev"), ("user.name", "MCS Test"), ("commit.gpgsign", "false")] {
            _ = try git(shell, ["-C", workDir.path, "config", key, value], context: "git config \(key)")
        }

        try """
        schemaVersion: 1
        identifier: boot-pack
        displayName: Boot Pack
        description: A pack with no trustable content
        """.write(to: workDir.appendingPathComponent("techpack.yaml"), atomically: true, encoding: .utf8)
        _ = try git(shell, ["-C", workDir.path, "add", "."], context: "git add")
        _ = try git(shell, ["-C", workDir.path, "commit", "-m", "initial"], context: "git commit")
        _ = try git(shell, ["-C", workDir.path, "tag", "v1"], context: "git tag")
        let taggedSHA = try git(shell, ["-C", workDir.path, "rev-parse", "HEAD"], context: "rev-parse")

        try "next".write(to: workDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try git(shell, ["-C", workDir.path, "add", "."], context: "git add")
        _ = try git(shell, ["-C", workDir.path, "commit", "-m", "next"], context: "git commit")
        _ = try git(shell, ["-C", workDir.path, "push", "origin", "HEAD", "v1"], context: "git push")
        let tipSHA = try git(shell, ["-C", workDir.path, "rev-parse", "HEAD"], context: "rev-parse")

        let ctx = PackCommandContext(
            env: env,
            output: CLIOutput(colorsEnabled: false),
            shell: shell,
            registry: PackRegistryFile(path: env.packsRegistry)
        )
        let entry = PackRegistryFile.PackEntry(
            identifier: "boot-pack",
            displayName: "Boot Pack",
            author: nil,
            sourceURL: remoteDir.path,
            ref: "v1",
            commitSHA: taggedSHA,
            localPath: "boot-pack",
            addedAt: "2026-09-24T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: nil
        )
        try ctx.registry.save(PackRegistryFile.RegistryData(packs: [entry]))

        return Fixture(
            tmpDir: tmpDir, remoteDir: remoteDir, ctx: ctx,
            taggedSHA: taggedSHA, tipSHA: tipSHA, entry: entry
        )
    }

    @Test("same-ref entry with a deleted checkout is re-cloned and persisted")
    func sameRefMissingCheckoutReclones() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let reconciled = try BootstrapCommand.parse([]).reconcileExistingGitPack(
            existing: fix.entry,
            pack: BootstrapFile.PackRef(source: fix.remoteDir.path, ref: "v1"),
            ctx: fix.ctx
        )

        #expect(reconciled.commitSHA == fix.taggedSHA)
        #expect(!PackRegistryFile.PackEntry.isCheckoutMissing(at: fix.packPath))
        let persisted = try fix.ctx.loadRegistry().packs
        #expect(persisted.count == 1)
        #expect(persisted.first?.ref == "v1")
    }

    @Test("changed ref with a deleted checkout is re-cloned at the declared ref")
    func changedRefMissingCheckoutReclonesAtDeclaredRef() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let reconciled = try BootstrapCommand.parse([]).reconcileExistingGitPack(
            existing: fix.entry,
            pack: BootstrapFile.PackRef(source: fix.remoteDir.path, ref: nil),
            ctx: fix.ctx
        )

        #expect(reconciled.commitSHA == fix.tipSHA)
        #expect(reconciled.ref == nil)
        let persisted = try fix.ctx.loadRegistry().packs
        #expect(persisted.first?.commitSHA == fix.tipSHA)
        #expect(persisted.first?.ref == nil)
    }
}
