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
        #expect(fetchCall.arguments.contains("--depth"))
        let resetCall = try #require(shell.runCalls.first { $0.arguments.contains("reset") })
        #expect(resetCall.arguments.contains("origin/HEAD"))
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

    @Test("update with ref calls checkout with retry on tag fetch")
    func updateWithRefCallsCheckout() throws {
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
        let checkoutCall = try #require(shell.runCalls.first { $0.arguments.contains("checkout") })
        #expect(checkoutCall.arguments.contains("v2.0.0"))
    }

    @Test("update with ref retries checkout after tag fetch on initial failure")
    func updateWithRefRetriesCheckout() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "error: pathspec"),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "new-sha", stderr: ""),
        ]

        let result = try fetcher.update(packPath: packPath, ref: "v2.0.0")
        #expect(result?.commitSHA == "new-sha")

        // Tag fetch is distinct from the initial fetch — it includes "tag" in the arguments
        let tagFetchCall = try #require(shell.runCalls.first { $0.arguments.contains("tag") })
        #expect(tagFetchCall.arguments.contains("v2.0.0"))
    }

    @Test("update throws refNotFound when both checkout and tag fetch fail")
    func updateWithRefThrowsWhenTagFetchFails() throws {
        let (tmpDir, packPath, fetcher, shell) = try makeUpdateFixture()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // rev-parse, fetch, checkout fails, tag fetch fails
        shell.runResults = [
            ShellResult(exitCode: 0, stdout: "old-sha", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 1, stdout: "", stderr: "error: pathspec"),
            ShellResult(exitCode: 1, stdout: "", stderr: "fatal: couldn't find remote ref"),
        ]

        #expect(throws: PackFetchError.self) {
            try fetcher.update(packPath: packPath, ref: "nonexistent-tag")
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
