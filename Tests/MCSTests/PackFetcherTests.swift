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

    /// Set up a pack directory suitable for update tests, returning the dirs, fetcher, and mock shell.
    private func makeUpdateFixture() throws -> (tmpDir: URL, packPath: URL, fetcher: PackFetcher, shell: MockShellRunner) {
        let tmpDir = try makeTmpDir()
        let packsDir = tmpDir.appendingPathComponent("packs")
        let packPath = packsDir.appendingPathComponent("test-pack")
        try FileManager.default.createDirectory(at: packPath, withIntermediateDirectories: true)
        let (fetcher, shell) = makeMockFetcher(home: tmpDir, packsDir: packsDir)
        return (tmpDir, packPath, fetcher, shell)
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

    @Test("fetch without a ref checks out the remote's default branch at depth 1")
    func fetchCallsClone() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let packsDir = tmpDir.appendingPathComponent("packs")
        let (fetcher, shell) = makeMockFetcher(home: tmpDir, packsDir: packsDir)

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "abc123def456", stderr: ""),
        ]

        let result = try fetcher.fetch(
            url: "https://github.com/org/repo.git", identifier: "my-pack", ref: nil
        )

        let remoteCall = try #require(shell.runCalls.first { $0.arguments.starts(with: ["remote", "add"]) })
        #expect(remoteCall.arguments.contains("https://github.com/org/repo.git"))
        let fetchCall = try #require(shell.runCalls.first { $0.arguments.first == "fetch" })
        #expect(fetchCall.arguments == ["fetch", "--depth", "1", "origin", "HEAD"])
        #expect(shell.runCalls.contains { $0.arguments == ["checkout", "--quiet", "FETCH_HEAD"] })

        #expect(result.commitSHA == "abc123def456")
        #expect(result.ref == nil)
        #expect(result.localPath.lastPathComponent == "my-pack")
    }

    @Test("fetch with a ref fetches that ref")
    func fetchWithRefAddsBranch() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (fetcher, shell) = makeMockFetcher(home: tmpDir)

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "sha123", stderr: ""),
        ]

        let result = try fetcher.fetch(
            url: "https://github.com/org/repo.git", identifier: "test-pack", ref: "v1.0.0"
        )

        let fetchCall = try #require(shell.runCalls.first { $0.arguments.first == "fetch" })
        #expect(fetchCall.arguments == ["fetch", "--depth", "1", "origin", "v1.0.0"])
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
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
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

    // MARK: - update tests

    @Test("update calls fetch and reset for default branch")
    func updateCallsFetchAndReset() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "new-sha", stderr: ""),
        ]

        let result = try fetcher.update(packPath: packPath, ref: nil)

        #expect(result != nil)
        #expect(result?.commitSHA == "new-sha")

        let fetchCall = try #require(shell.runCalls.first { $0.arguments.contains("fetch") })
        #expect(fetchCall.arguments == ["fetch", "--depth", "1", "origin", "HEAD"])
        let resetCall = try #require(shell.runCalls.first { $0.arguments.contains("reset") })
        #expect(resetCall.arguments.contains("FETCH_HEAD"))
    }

    @Test("update returns nil when SHA is unchanged")
    func updateReturnsNilWhenUnchanged() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "same-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "same-sha", stderr: ""),
        ]

        let result = try fetcher.update(packPath: packPath, ref: nil)
        #expect(result == nil)
    }

    @Test("update throws fetchFailed on error")
    func updateThrowsOnFetchFailure() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "fatal: remote not found"),
        ]

        #expect(throws: PackFetchError.self) {
            try fetcher.update(packPath: packPath, ref: nil)
        }
    }

    @Test("update with tag ref fetches the ref and resets to FETCH_HEAD")
    func updateWithRefFetchesAndResets() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "new-sha", stderr: ""),
        ]

        let result = try fetcher.update(packPath: packPath, ref: "v2.0.0")

        #expect(result?.commitSHA == "new-sha")

        let fetchCall = try #require(shell.runCalls.first { $0.arguments.contains("fetch") })
        #expect(fetchCall.arguments.contains("v2.0.0"))

        let resetCall = try #require(shell.runCalls.first { $0.arguments.contains("reset") })
        #expect(resetCall.arguments.contains("FETCH_HEAD"))

        #expect(!shell.runCalls.contains { $0.arguments.contains("checkout") })
    }

    @Test("update with branch ref advances the checked-out commit SHA")
    func updateWithBranchRefAdvancesCheckedOutCommit() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "new-sha", stderr: ""),
        ]

        let result = try fetcher.update(packPath: packPath, ref: "main")

        #expect(result != nil)
        #expect(result?.commitSHA == "new-sha")

        let fetchCall = try #require(shell.runCalls.first { $0.arguments.contains("fetch") })
        #expect(fetchCall.arguments.contains("main"))

        let resetCall = try #require(shell.runCalls.first { $0.arguments.contains("reset") })
        #expect(resetCall.arguments.contains("FETCH_HEAD"))
    }

    @Test("update throws fetchFailed when ref fetch fails")
    func updateWithRefThrowsFetchFailed() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 128, stdout: "", stderr: "fatal: couldn't find remote ref refs/heads/nonexistent"),
        ]

        do {
            _ = try fetcher.update(packPath: packPath, ref: "nonexistent-tag")
            Issue.record("Expected fetchFailed to be thrown")
        } catch let error as PackFetchError {
            guard case .fetchFailed = error else {
                Issue.record("Expected .fetchFailed, got \(error)")
                return
            }
        }
    }

    @Test("update throws updateFailed when reset fails")
    func updateThrowsWhenResetFails() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // rev-parse, fetch succeeds, reset fails
        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "fatal: could not reset"),
        ]

        #expect(throws: PackFetchError.self) {
            try fetcher.update(packPath: packPath, ref: nil)
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

struct PackFetcherCommitRefTests {
    private struct TestSetupError: Error {
        let message: String
    }

    private func git(_ arguments: [String], in dir: URL, shell: ShellRunner) throws -> String {
        let result = shell.run(
            shell.environment.gitPath,
            arguments: ["-c", "user.email=test@example.com", "-c", "user.name=Test"] + arguments,
            workingDirectory: dir.path
        )
        guard result.succeeded else {
            throw TestSetupError(message: "git \(arguments.joined(separator: " ")): \(result.stderr)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Recognizes only a full 40-hex SHA as a commit ref", arguments: [
        ("0123456789abcdef0123456789abcdef01234567", true),
        ("0123456", false),
        ("v1.0.0", false),
        ("0123456789abcdef0123456789abcdef0123456g", false),
    ])
    func commitSHAShape(ref: String, expected: Bool) {
        #expect(PackFetcher.isCommitSHA(ref) == expected)
    }

    @Test("A pack fetched at a commit SHA stays there, then follows the default branch once unpinned")
    func fetchAtCommitSHA() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let env = Environment(home: tmpDir)
        let shell = ShellRunner(environment: env)
        let remote = tmpDir.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try git(["init", "--quiet"], in: remote, shell: shell)
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "first"], in: remote, shell: shell)
        let pinned = try git(["rev-parse", "HEAD"], in: remote, shell: shell)
        _ = try git(["commit", "--quiet", "--allow-empty", "-m", "second"], in: remote, shell: shell)
        let tip = try git(["rev-parse", "HEAD"], in: remote, shell: shell)

        let fetcher = PackFetcher(
            shell: shell,
            output: CLIOutput(colorsEnabled: false),
            packsDirectory: tmpDir.appendingPathComponent("packs")
        )
        let result = try fetcher.fetch(url: remote.path, identifier: "pinned", ref: pinned)
        #expect(result.commitSHA == pinned)

        #expect(try fetcher.update(packPath: result.localPath, ref: pinned) == nil)

        // Dropping the pin must reach the default branch even though a ref-first checkout has
        // no `origin/HEAD`.
        let unpinned = try fetcher.update(packPath: result.localPath, ref: nil)
        #expect(unpinned?.commitSHA == tip)
    }
}
