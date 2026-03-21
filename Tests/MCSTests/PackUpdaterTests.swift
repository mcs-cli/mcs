import Foundation
@testable import mcs
import Testing

struct PackUpdaterTests {
    private struct TestSetupError: Error {
        let message: String
    }

    private struct Fixture {
        let tmpDir: URL
        let remoteDir: URL
        let packsDir: URL
        let fetcher: PackFetcher
        let updater: PackUpdater
        let registry: PackRegistryFile
        let initialSHA: String

        func cleanup() {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    // MARK: - Helpers

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-packupdater-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func git(
        _ shell: ShellRunner, _ arguments: [String],
        context: String
    ) throws {
        let result = shell.run(shell.environment.gitPath, arguments: arguments)
        guard result.succeeded else {
            throw TestSetupError(message: "\(context): \(result.stderr)")
        }
    }

    /// Create a bare repo seeded with a minimal techpack.yaml, clone it into packs/,
    /// and return a fixture with a PackUpdater ready to test.
    private func makeFixture() throws -> Fixture {
        let tmpDir = try makeTmpDir()
        let remoteDir = tmpDir.appendingPathComponent("remote.git")
        let workDir = tmpDir.appendingPathComponent("work")
        let packsDir = tmpDir.appendingPathComponent("packs")
        let env = Environment(home: tmpDir)
        let shell = ShellRunner(environment: env)
        let output = CLIOutput(colorsEnabled: false)

        // Init bare repo
        try git(shell, ["init", "--bare", remoteDir.path], context: "git init --bare")

        // Clone, configure, seed with techpack.yaml, push
        try git(shell, ["clone", remoteDir.path, workDir.path], context: "git clone")
        try git(shell, ["-C", workDir.path, "config", "user.email", "test@mcs.dev"],
                context: "git config email")
        try git(shell, ["-C", workDir.path, "config", "user.name", "MCS Test"],
                context: "git config name")

        let manifest = """
        schemaVersion: 1
        identifier: test-pack
        displayName: Test Pack
        description: A test pack with no scripts
        """
        try manifest.write(
            to: workDir.appendingPathComponent("techpack.yaml"),
            atomically: true, encoding: .utf8
        )
        try git(shell, ["-C", workDir.path, "add", "."], context: "git add")
        try git(shell, ["-C", workDir.path, "commit", "-m", "initial"], context: "git commit")
        try git(shell, ["-C", workDir.path, "push"], context: "git push")

        // Clone into packs/ (simulating what mcs pack add does)
        let fetcher = PackFetcher(shell: shell, output: output, packsDirectory: packsDir)
        let fetchResult = try fetcher.fetch(url: remoteDir.path, identifier: "test-pack", ref: nil)
        let initialSHA = fetchResult.commitSHA

        let registryPath = tmpDir.appendingPathComponent("registry.yaml")
        let registry = PackRegistryFile(path: registryPath)

        let trustManager = PackTrustManager(output: output)
        let updater = PackUpdater(
            fetcher: fetcher, trustManager: trustManager,
            environment: env, output: output
        )

        return Fixture(
            tmpDir: tmpDir, remoteDir: remoteDir, packsDir: packsDir,
            fetcher: fetcher, updater: updater, registry: registry,
            initialSHA: initialSHA
        )
    }

    private func makeEntry(
        commitSHA: String,
        trustedScriptHashes: [String: String] = [:]
    ) -> PackRegistryFile.PackEntry {
        PackRegistryFile.PackEntry(
            identifier: "test-pack",
            displayName: "Test Pack",
            author: nil,
            sourceURL: "file:///fake/remote.git",
            ref: nil,
            commitSHA: commitSHA,
            localPath: "test-pack",
            addedAt: "2026-03-21T00:00:00Z",
            trustedScriptHashes: trustedScriptHashes,
            isLocal: nil
        )
    }

    /// Push a new commit to the remote and return its SHA.
    private func pushNewCommit(fixture: Fixture) throws -> String {
        let workDir = fixture.tmpDir.appendingPathComponent("work")
        let shell = ShellRunner(environment: Environment(home: fixture.tmpDir))

        try "updated-\(UUID().uuidString)".write(
            to: workDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        try git(shell, ["-C", workDir.path, "add", "."], context: "git add")
        try git(shell, ["-C", workDir.path, "commit", "-m", "update"], context: "git commit")
        try git(shell, ["-C", workDir.path, "push"], context: "git push")

        let shaResult = shell.run(
            shell.environment.gitPath, arguments: ["-C", workDir.path, "rev-parse", "HEAD"]
        )
        guard shaResult.succeeded, !shaResult.stdout.isEmpty else {
            throw TestSetupError(message: "rev-parse HEAD: \(shaResult.stderr)")
        }
        return shaResult.stdout
    }

    // MARK: - Tests

    @Test("returns alreadyUpToDate when disk SHA matches registry SHA")
    func trulyUpToDate() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let entry = makeEntry(commitSHA: fix.initialSHA)
        let packPath = fix.packsDir.appendingPathComponent("test-pack")

        let result = fix.updater.updateGitPack(
            entry: entry, packPath: packPath, registry: fix.registry
        )

        guard case .alreadyUpToDate = result else {
            Issue.record("Expected .alreadyUpToDate, got \(result)")
            return
        }
    }

    @Test("returns updated when remote has a new commit (no new scripts)")
    func normalUpdateNoScripts() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let entry = makeEntry(commitSHA: fix.initialSHA)
        let packPath = fix.packsDir.appendingPathComponent("test-pack")

        let newSHA = try pushNewCommit(fixture: fix)

        let result = fix.updater.updateGitPack(
            entry: entry, packPath: packPath, registry: fix.registry
        )

        guard case let .updated(updatedEntry) = result else {
            Issue.record("Expected .updated, got \(result)")
            return
        }
        #expect(updatedEntry.commitSHA == newSHA)
        #expect(updatedEntry.identifier == "test-pack")
    }

    @Test("recovers from stale registry when disk SHA differs from registry SHA")
    func staleRegistryRecovery() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let packPath = fix.packsDir.appendingPathComponent("test-pack")

        // Push a new commit and advance the local checkout (simulating a previous
        // update where trust was denied — disk is at new commit, registry is stale)
        let newSHA = try pushNewCommit(fixture: fix)
        _ = try fix.fetcher.update(packPath: packPath, ref: nil)

        // Registry entry still points to the OLD SHA
        let staleEntry = makeEntry(commitSHA: fix.initialSHA)

        // Now call updateGitPack — fetcher returns nil (already at latest),
        // but disk SHA != registry SHA, so it should detect the mismatch and re-trust
        let result = fix.updater.updateGitPack(
            entry: staleEntry, packPath: packPath, registry: fix.registry
        )

        guard case let .updated(updatedEntry) = result else {
            Issue.record("Expected .updated (stale recovery), got \(result)")
            return
        }
        #expect(updatedEntry.commitSHA == newSHA)
        #expect(updatedEntry.identifier == "test-pack")
    }

    @Test("returns skipped when fetch fails")
    func fetchFailure() throws {
        let fix = try makeFixture()
        defer { fix.cleanup() }

        let entry = makeEntry(commitSHA: fix.initialSHA)

        // Point at a nonexistent path so git fetch fails
        let brokenPath = fix.tmpDir.appendingPathComponent("nonexistent-pack")

        let result = fix.updater.updateGitPack(
            entry: entry, packPath: brokenPath, registry: fix.registry
        )

        guard case .skipped = result else {
            Issue.record("Expected .skipped, got \(result)")
            return
        }
    }
}
