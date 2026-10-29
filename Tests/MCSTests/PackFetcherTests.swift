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

struct PackFetcherRefValidationTests {
    @Test("Accepts tags, branches and commit prefixes", arguments: [
        "v1.0.0", "main", "feature/my-feature", "v1.0.0-rc.1", "v1+build", "abc123def",
    ])
    func acceptsValidRef(ref: String) throws {
        try makeFetcher().validateRef(ref)
    }

    /// Refs reach `git` as arguments, so each case is an injection or traversal vector.
    @Test("Rejects flag injection, traversal and shell metacharacters", arguments: [
        "--upload-pack=evil", "-b", "v1/../../../etc/passwd", "main branch", "`whoami`", "$HOME", "",
    ])
    func rejectsUnsafeRef(ref: String) throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateRef(ref)
        }
    }
}

struct PackFetcherIdentifierValidationTests {
    @Test("Accepts plain pack identifiers", arguments: ["my-pack", "my.pack", "pack123"])
    func acceptsValidIdentifier(identifier: String) throws {
        try makeFetcher().validateIdentifier(identifier)
    }

    /// Identifiers become directory names under `~/.mcs/packs`, so traversal must be impossible.
    @Test("Rejects identifiers that escape or break the packs directory", arguments: [
        "", "../../etc", "foo/bar", "-pack",
    ])
    func rejectsUnsafeIdentifier(identifier: String) throws {
        #expect(throws: PackFetchError.self) {
            try makeFetcher().validateIdentifier(identifier)
        }
    }
}

// MARK: - Operation Tests (mock-based)

struct PackFetcherOperationTests {
    private func makeMockFetcher(
        home: URL,
        packsDir: URL? = nil
    ) -> (fetcher: PackFetcher, shell: MockShellRunner) {
        let packs = packsDir ?? home.appendingPathComponent("packs")
        let env = Environment(home: home)
        let shell = MockShellRunner(environment: env)
        let fetcher = PackFetcher(
            shell: shell,
            output: CLIOutput(colorsEnabled: false),
            packsDirectory: packs
        )
        return (fetcher, shell)
    }

    // MARK: - ensureGitAvailable

    @Test("fetch throws gitNotInstalled when git is missing")
    func fetchThrowsWhenGitMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)
        shell.commandExistsResult = false

        #expect(throws: PackFetchError.self) {
            try fetcher.fetch(url: "https://github.com/org/repo.git", identifier: "test-pack", ref: nil)
        }
        #expect(shell.commandExistsCalls == ["git"])
    }

    // MARK: - fetch tests

    @Test("fetch calls git clone with correct arguments")
    func fetchCallsClone() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let packsDir = tmpDir.appendingPathComponent("packs")
        let (fetcher, shell) = makeMockFetcher(home: tmpDir, packsDir: packsDir)

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "abc123def456", stderr: ""),
        ]

        let result = try fetcher.fetch(
            url: "https://github.com/org/repo.git", identifier: "my-pack", ref: nil
        )

        let cloneCall = try #require(shell.runCalls.first { $0.arguments.contains("clone") })
        #expect(cloneCall.arguments.contains("--depth"))
        #expect(cloneCall.arguments.contains("1"))
        #expect(cloneCall.arguments.contains("https://github.com/org/repo.git"))
        #expect(!cloneCall.arguments.contains("--branch"))

        #expect(result.commitSHA == "abc123def456")
        #expect(result.ref == nil)
        #expect(result.localPath.lastPathComponent == "my-pack")
    }

    @Test("fetch with ref adds --branch flag")
    func fetchWithRefAddsBranch() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "sha123", stderr: ""),
        ]

        let result = try fetcher.fetch(
            url: "https://github.com/org/repo.git", identifier: "test-pack", ref: "v1.0.0"
        )

        let cloneCall = try #require(shell.runCalls.first { $0.arguments.contains("clone") })
        #expect(cloneCall.arguments.contains("--branch"))
        #expect(cloneCall.arguments.contains("v1.0.0"))
        #expect(result.ref == "v1.0.0")
    }

    @Test("fetch throws cloneFailed on non-zero exit")
    func fetchThrowsOnCloneFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)

        shell.result = ShellResult(exitCode: 128, stdout: "", stderr: "fatal: repository not found")

        #expect(throws: PackFetchError.self) {
            try fetcher.fetch(
                url: "https://github.com/org/nonexistent.git", identifier: "test-pack", ref: nil
            )
        }
    }

    @Test("fetch removes existing directory before cloning")
    func fetchRemovesExistingDir() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let packsDir = tmpDir.appendingPathComponent("packs")
        let (fetcher, shell) = makeMockFetcher(home: tmpDir, packsDir: packsDir)

        // Pre-create a stale directory
        let packPath = packsDir.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: packPath, withIntermediateDirectories: true)
        try "leftover".write(
            to: packPath.appendingPathComponent("stale.txt"),
            atomically: true, encoding: .utf8
        )

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "sha456", stderr: ""),
        ]

        _ = try fetcher.fetch(
            url: "https://github.com/org/repo.git", identifier: "test-pack", ref: nil
        )

        #expect(!FileManager.default.fileExists(
            atPath: packPath.appendingPathComponent("stale.txt").path
        ))
    }

    @Test("clone refuses the packs directory itself and paths outside it, leaving them intact")
    func cloneRejectsNonChildPaths() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let packsDir = tmpDir.appendingPathComponent("packs")
        let installed = packsDir.appendingPathComponent("other-pack")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let (fetcher, shell) = makeMockFetcher(home: tmpDir, packsDir: packsDir)

        for target in [packsDir, tmpDir.appendingPathComponent("outside")] {
            #expect(throws: PackFetchError.self) {
                try fetcher.clone(url: "https://github.com/org/repo.git", into: target, ref: nil)
            }
        }
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(shell.runCalls.isEmpty)
    }

    // MARK: - fetchTarget tests

    /// A bare remote with one commit, cloned into `packs/test-pack` the way `pack add` does.
    private func makeRemoteFixture() throws -> (tmpDir: URL, work: URL, packPath: URL, fetcher: PackFetcher, git: ([String]) throws -> String) {
        let tmpDir = try makeTmpDir()
        let env = Environment(home: tmpDir)
        let shell = ShellRunner(environment: env)
        let git = { (arguments: [String]) throws -> String in try runGit(arguments, in: tmpDir) }
        let remote = tmpDir.appendingPathComponent("remote.git")
        let work = tmpDir.appendingPathComponent("work")
        _ = try git(["init", "-q", "--bare", remote.path])
        _ = try git(["clone", "-q", remote.path, work.path])
        try "v1".write(to: work.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try git(["-C", work.path, "add", "."])
        _ = try git(["-C", work.path, "-c", "user.email=t@mcs.dev", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "v1"])
        _ = try git(["-C", work.path, "push", "-q"])
        let fetcher = PackFetcher(shell: shell, output: CLIOutput(colorsEnabled: false), packsDirectory: tmpDir.appendingPathComponent("packs"))
        let packPath = try fetcher.fetch(url: remote.path, identifier: "test-pack", ref: nil).localPath
        return (tmpDir, work, packPath, fetcher, git)
    }

    @Test("fetchTarget returns the remote's new commit without moving the checkout")
    func fetchTargetLeavesCheckout() throws {
        let fix = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(at: fix.tmpDir) }
        let before = try fix.fetcher.currentCommit(at: fix.packPath)
        try "v2".write(to: fix.work.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try fix.git(["-C", fix.work.path, "-c", "user.email=t@mcs.dev", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qam", "v2"])
        _ = try fix.git(["-C", fix.work.path, "push", "-q"])

        let target = try fix.fetcher.fetchTarget(packPath: fix.packPath, ref: nil)

        #expect(try target == (fix.git(["-C", fix.work.path, "rev-parse", "HEAD"])))
        #expect(try fix.fetcher.currentCommit(at: fix.packPath) == before)
    }

    @Test("fetchTarget resolves an annotated tag to its commit, so an unchanged pin is not a change")
    func fetchTargetPeelsAnnotatedTag() throws {
        let fix = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(at: fix.tmpDir) }
        _ = try fix.git(["-C", fix.work.path, "-c", "user.email=t@mcs.dev", "-c", "user.name=t", "tag", "-a", "v1.0.0", "-m", "release"])
        _ = try fix.git(["-C", fix.work.path, "push", "-q", "origin", "v1.0.0"])

        let target = try fix.fetcher.fetchTarget(packPath: fix.packPath, ref: "v1.0.0")

        #expect(try target == (fix.fetcher.currentCommit(at: fix.packPath)))
    }

    @Test("fetchTarget throws fetchFailed for a ref the remote doesn't have")
    func fetchTargetMissingRef() throws {
        let fix = try makeRemoteFixture()
        defer { try? FileManager.default.removeItem(at: fix.tmpDir) }

        #expect {
            try fix.fetcher.fetchTarget(packPath: fix.packPath, ref: "nonexistent-tag")
        } throws: { error in
            guard case PackFetchError.fetchFailed = error else { return false }
            return true
        }
    }

    // MARK: - currentCommit tests

    @Test("currentCommit throws on failure")
    func currentCommitThrowsOnFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)

        shell.result = ShellResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository")

        #expect(throws: PackFetchError.self) {
            try fetcher.currentCommit(at: tmpDir)
        }
    }

    @Test("currentCommit returns SHA on success")
    func currentCommitReturnsCorrectSHA() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)

        shell.result = ShellResult(exitCode: 0, stdout: "abc123def456789", stderr: "")

        let sha = try fetcher.currentCommit(at: tmpDir)
        #expect(sha == "abc123def456789")
    }
}
