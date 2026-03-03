import Foundation
@testable import mcs
import Testing

private func makeFetcher() -> PackFetcher {
    let tmpDir = FileManager.default.temporaryDirectory
    let env = Environment(home: tmpDir)
    return PackFetcher(
        shell: ShellRunner(environment: env),
        output: CLIOutput(colorsEnabled: false),
        packsDirectory: tmpDir
    )
}

@Suite("PackFetcher ref validation")
struct PackFetcherRefValidationTests {
    // MARK: - Valid refs

    @Test("Accepts valid semver tag")
    func acceptsSemverTag() throws {
        try makeFetcher().validateRef("v1.0.0")
    }

    @Test("Accepts simple branch name")
    func acceptsSimpleBranch() throws {
        try makeFetcher().validateRef("main")
    }

    @Test("Accepts branch with slash")
    func acceptsBranchWithSlash() throws {
        try makeFetcher().validateRef("feature/my-feature")
    }

    @Test("Accepts dotted pre-release tag")
    func acceptsDottedTag() throws {
        try makeFetcher().validateRef("v1.0.0-rc.1")
    }

    @Test("Accepts ref with plus")
    func acceptsRefWithPlus() throws {
        try makeFetcher().validateRef("v1+build")
    }

    @Test("Accepts commit-like hex prefix")
    func acceptsCommitPrefix() throws {
        try makeFetcher().validateRef("abc123def")
    }

    // MARK: - Rejected refs

    @Test("Rejects double-dash flag injection")
    func rejectsDoubleDashFlag() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("--upload-pack=evil")
        }
    }

    @Test("Rejects single-dash flag")
    func rejectsSingleDashFlag() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("-b")
        }
    }

    @Test("Rejects path traversal with ..")
    func rejectsPathTraversal() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("v1/../../../etc/passwd")
        }
    }

    @Test("Rejects spaces")
    func rejectsSpaces() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("main branch")
        }
    }

    @Test("Rejects backticks")
    func rejectsBackticks() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("`whoami`")
        }
    }

    @Test("Rejects dollar sign")
    func rejectsDollarSign() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("$HOME")
        }
    }

    @Test("Rejects empty string")
    func rejectsEmpty() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef("")
        }
    }
}

@Suite("PackFetcher identifier validation")
struct PackFetcherIdentifierValidationTests {
    // MARK: - Valid identifiers

    @Test("Accepts simple hyphenated name")
    func acceptsHyphenatedName() throws {
        try makeFetcher().validateIdentifier("my-pack")
    }

    @Test("Accepts dotted name")
    func acceptsDottedName() throws {
        try makeFetcher().validateIdentifier("my.pack")
    }

    @Test("Accepts alphanumeric name")
    func acceptsAlphanumericName() throws {
        try makeFetcher().validateIdentifier("pack123")
    }

    // MARK: - Rejected identifiers

    @Test("Rejects empty string")
    func rejectsEmpty() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateIdentifier("")
        }
    }

    @Test("Rejects path traversal")
    func rejectsPathTraversal() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateIdentifier("../../etc")
        }
    }

    @Test("Rejects slash")
    func rejectsSlash() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateIdentifier("foo/bar")
        }
    }

    @Test("Rejects leading dash")
    func rejectsLeadingDash() throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateIdentifier("-pack")
        }
    }
}

// MARK: - Integration Tests (git operations)

@Suite("PackFetcher operations")
struct PackFetcherOperationTests {
    private struct TestSetupError: Error {
        let message: String
    }

    /// A seeded local git repo fixture with all handles needed by tests.
    private struct SeededFixture {
        let tmpDir: URL
        let remoteDir: URL
        let packsDir: URL
        let fetcher: PackFetcher
        let commitSHA: String

        func cleanup() {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-packfetcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFetcher(packsDir: URL, home: URL) -> PackFetcher {
        let env = Environment(home: home)
        return PackFetcher(
            shell: ShellRunner(environment: env),
            output: CLIOutput(colorsEnabled: false),
            packsDirectory: packsDir
        )
    }

    /// Run a git command and throw if it fails.
    private func git(
        _ shell: ShellRunner, _ arguments: [String],
        context: String
    ) throws {
        let result = shell.run(shell.environment.gitPath, arguments: arguments)
        guard result.succeeded else {
            throw TestSetupError(message: "\(context): \(result.stderr)")
        }
    }

    /// Create a bare repo, seed it with an initial commit, and return a fixture.
    private func makeSeededFixture() throws -> SeededFixture {
        let tmpDir = try makeTmpDir()
        let remoteDir = tmpDir.appendingPathComponent("remote.git")
        let workDir = tmpDir.appendingPathComponent("work")
        let packsDir = tmpDir.appendingPathComponent("packs")
        let shell = ShellRunner(environment: Environment(home: tmpDir))

        // Init bare repo
        try git(shell, ["init", "--bare", remoteDir.path],
                context: "git init --bare")

        // Clone, configure, commit, push
        try git(shell, ["clone", remoteDir.path, workDir.path],
                context: "git clone")
        try git(shell, ["-C", workDir.path, "config", "user.email", "test@mcs.dev"],
                context: "git config user.email")
        try git(shell, ["-C", workDir.path, "config", "user.name", "MCS Test"],
                context: "git config user.name")

        let readme = workDir.appendingPathComponent("README.md")
        try "initial".write(to: readme, atomically: true, encoding: .utf8)
        try git(shell, ["-C", workDir.path, "add", "."],
                context: "git add")
        try git(shell, ["-C", workDir.path, "commit", "-m", "initial"],
                context: "git commit")
        try git(shell, ["-C", workDir.path, "push"],
                context: "git push")

        let shaResult = shell.run(
            shell.environment.gitPath,
            arguments: ["-C", workDir.path, "rev-parse", "HEAD"]
        )
        guard shaResult.succeeded, !shaResult.stdout.isEmpty else {
            throw TestSetupError(message: "rev-parse HEAD: \(shaResult.stderr)")
        }

        let fetcher = makeFetcher(packsDir: packsDir, home: tmpDir)
        return SeededFixture(
            tmpDir: tmpDir,
            remoteDir: remoteDir,
            packsDir: packsDir,
            fetcher: fetcher,
            commitSHA: shaResult.stdout
        )
    }

    // MARK: - fetch tests

    @Test("fetch throws cloneFailed for invalid URL")
    func fetchCloneFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packsDir = tmpDir.appendingPathComponent("packs")
        let fetcher = makeFetcher(packsDir: packsDir, home: tmpDir)

        #expect(throws: PackFetchError.self) {
            try fetcher.fetch(
                url: "file:///nonexistent/repo.git",
                identifier: "test-pack",
                ref: nil
            )
        }
    }

    @Test("fetch removes existing directory before cloning")
    func fetchCleansExistingDirectory() throws {
        let fix = try makeSeededFixture()
        defer { fix.cleanup() }

        // Pre-create a directory with a stale file where the pack would be cloned
        let packPath = fix.packsDir.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: packPath, withIntermediateDirectories: true)
        try "leftover".write(
            to: packPath.appendingPathComponent("stale.txt"),
            atomically: true, encoding: .utf8
        )

        let result = try fix.fetcher.fetch(
            url: fix.remoteDir.path, identifier: "test-pack", ref: nil
        )

        #expect(!result.commitSHA.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: packPath.appendingPathComponent("README.md").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: packPath.appendingPathComponent("stale.txt").path
        ))
    }

    @Test("fetch clones repo and returns valid FetchResult")
    func fetchHappyPath() throws {
        let fix = try makeSeededFixture()
        defer { fix.cleanup() }

        let result = try fix.fetcher.fetch(
            url: fix.remoteDir.path, identifier: "my-pack", ref: nil
        )

        #expect(result.commitSHA == fix.commitSHA)
        #expect(result.ref == nil)
        #expect(result.localPath.lastPathComponent == "my-pack")
    }

    // MARK: - update tests

    @Test("update returns nil when already at latest")
    func updateAlreadyAtLatest() throws {
        let fix = try makeSeededFixture()
        defer { fix.cleanup() }

        let fetchResult = try fix.fetcher.fetch(
            url: fix.remoteDir.path, identifier: "test-pack", ref: nil
        )

        let updateResult = try fix.fetcher.update(
            packPath: fetchResult.localPath, ref: nil
        )
        #expect(updateResult == nil)
    }

    @Test("update throws refNotFound for nonexistent ref")
    func updateRefNotFound() throws {
        let fix = try makeSeededFixture()
        defer { fix.cleanup() }

        let fetchResult = try fix.fetcher.fetch(
            url: fix.remoteDir.path, identifier: "test-pack", ref: nil
        )

        #expect(throws: PackFetchError.self) {
            try fix.fetcher.update(
                packPath: fetchResult.localPath, ref: "nonexistent-tag-xyz"
            )
        }
    }

    @Test("update throws fetchFailed when remote is unreachable")
    func updateFetchFailed() throws {
        let fix = try makeSeededFixture()
        defer { fix.cleanup() }

        let fetchResult = try fix.fetcher.fetch(
            url: fix.remoteDir.path, identifier: "test-pack", ref: nil
        )

        // Break the remote by renaming the bare repo
        try FileManager.default.moveItem(
            at: fix.remoteDir,
            to: fix.tmpDir.appendingPathComponent("broken.git")
        )

        #expect(throws: PackFetchError.self) {
            try fix.fetcher.update(packPath: fetchResult.localPath, ref: nil)
        }
    }

    // MARK: - currentCommit tests

    @Test("currentCommit throws commitResolutionFailed for non-git directory")
    func currentCommitNonGitDir() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let plainDir = tmpDir.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(
            at: plainDir, withIntermediateDirectories: true
        )

        let fetcher = makeFetcher(packsDir: tmpDir, home: tmpDir)
        #expect(throws: PackFetchError.self) {
            try fetcher.currentCommit(at: plainDir)
        }
    }
}
