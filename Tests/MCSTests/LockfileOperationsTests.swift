import ArgumentParser
import Foundation
@testable import mcs
import Testing

struct LockfileOperationsTests {
    // MARK: - Helpers

    /// Create an Environment rooted at a temp directory, plus the LockfileOperations instance.
    private func makeOperations(home: URL, shell: (any ShellRunning)? = nil) -> LockfileOperations {
        let env = Environment(home: home)
        return LockfileOperations(
            environment: env,
            output: CLIOutput(colorsEnabled: false),
            shell: shell ?? ShellRunner(environment: env)
        )
    }

    /// Write a registry file at the expected path under `home`.
    private func writeRegistry(
        _ entries: [PackRegistryFile.PackEntry],
        home: URL
    ) throws {
        let env = Environment(home: home)
        let registryFile = PackRegistryFile(path: env.packsRegistry)
        try registryFile.save(PackRegistryFile.RegistryData(packs: entries))
    }

    /// Create a project state with configured packs at `projectPath`.
    private func writeProjectState(
        packs: [String],
        at projectPath: URL
    ) throws {
        var state = try ProjectState(projectRoot: projectPath)
        for pack in packs {
            state.recordPack(pack)
        }
        try state.save()
    }

    // MARK: - writeLockfile

    @Test("writeLockfile generates lockfile from registry and project state")
    func writeLockfileBasic() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let entries = [
            makeRegistryEntry(identifier: "ios", commitSHA: "aabbccdd"),
            makeRegistryEntry(identifier: "web", commitSHA: "11223344"),
        ]
        try writeRegistry(entries, home: home)
        try writeProjectState(packs: ["ios", "web"], at: project)

        let ops = makeOperations(home: home)
        try ops.writeLockfile(at: project)

        let lockfile = try Lockfile.load(projectRoot: project)
        #expect(lockfile != nil)
        #expect(lockfile?.packs.count == 2)
        #expect(lockfile?.packs[0].identifier == "ios")
        #expect(lockfile?.packs[0].commitSHA == "aabbccdd")
        #expect(lockfile?.packs[1].identifier == "web")
        #expect(lockfile?.packs[1].commitSHA == "11223344")
    }

    @Test("writeLockfile filters to only configured packs")
    func writeLockfileFilters() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let entries = [
            makeRegistryEntry(identifier: "ios", commitSHA: "aabbccdd"),
            makeRegistryEntry(identifier: "web", commitSHA: "11223344"),
            makeRegistryEntry(identifier: "unused", commitSHA: "deadbeef"),
        ]
        try writeRegistry(entries, home: home)
        try writeProjectState(packs: ["ios"], at: project)

        let ops = makeOperations(home: home)
        try ops.writeLockfile(at: project)

        let lockfile = try Lockfile.load(projectRoot: project)
        #expect(lockfile?.packs.count == 1)
        #expect(lockfile?.packs[0].identifier == "ios")
    }

    @Test("writeLockfile is no-op when no configured packs")
    func writeLockfileNoPacks() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        try writeRegistry([], home: home)
        // Create .claude dir so ProjectState can load (empty = no configured packs)
        let claudeDir = project.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let ops = makeOperations(home: home)
        try ops.writeLockfile(at: project)

        let lockfile = try Lockfile.load(projectRoot: project)
        #expect(lockfile == nil)
    }

    @Test("writeLockfile overwrites existing lockfile")
    func writeLockfileOverwrites() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        // Write initial lockfile
        let oldLockfile = Lockfile.generate(
            registryEntries: [makeRegistryEntry(identifier: "ios", commitSHA: "oldsha")],
            selectedPackIDs: ["ios"]
        )
        try oldLockfile.save(projectRoot: project)

        // Now update registry with new SHA and write again
        let entries = [makeRegistryEntry(identifier: "ios", commitSHA: "newsha")]
        try writeRegistry(entries, home: home)
        try writeProjectState(packs: ["ios"], at: project)

        let ops = makeOperations(home: home)
        try ops.writeLockfile(at: project)

        let lockfile = try Lockfile.load(projectRoot: project)
        #expect(lockfile?.packs[0].commitSHA == "newsha")
    }

    // MARK: - checkoutLockedCommits: Missing lockfile

    @Test("checkoutLockedCommits throws when no lockfile exists")
    func checkoutMissingLockfile() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    // MARK: - checkoutLockedCommits: SHA validation

    @Test("Rejects SHA shorter than 7 characters")
    func checkoutRejectsShortSHA() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: "abcdef")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    @Test("Rejects SHA longer than 64 characters")
    func checkoutRejectsLongSHA() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let longSHA = String(repeating: "a", count: 65)
        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: longSHA)]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    @Test("Accepts valid 7-character abbreviated SHA")
    func checkoutAccepts7CharSHA() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        // Valid SHA but pack directory missing — should fail at the fileExists guard, not the SHA guard
        let env = Environment(home: home)
        let packsDir = env.packsDirectory
        try FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: "abcdef0")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        // Throws because pack dir doesn't exist, but passes SHA validation
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    @Test("Accepts valid 40-character full SHA-1")
    func checkoutAccepts40CharSHA() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let env = Environment(home: home)
        try FileManager.default.createDirectory(at: env.packsDirectory, withIntermediateDirectories: true)

        let fullSHA = String(repeating: "a", count: 40)
        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: fullSHA)]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        // Throws because pack dir doesn't exist, not because of SHA validation
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    @Test("Rejects uppercase hex in SHA")
    func checkoutRejectsUppercaseSHA() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: "ABCDEF0123")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    @Test("Rejects flag injection attempts in SHA field")
    func checkoutRejectsFlagInjection() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let maliciousSHAs = [
            "--upload-pack=evil",
            "-c core.sshCommand=evil",
            "HEAD~1",
            "origin/main",
            "abc123; rm -rf /",
        ]

        for malicious in maliciousSHAs {
            let lockfile = Lockfile(
                lockVersion: 1, generatedAt: "now", mcsVersion: "test",
                packs: [.init(identifier: "ios", sourceURL: "https://example.com", commitSHA: malicious)]
            )
            try lockfile.save(projectRoot: project)

            let ops = makeOperations(home: home)
            #expect(throws: ExitCode.self) {
                try ops.checkoutLockedCommits(at: project)
            }
        }
    }

    // MARK: - checkoutLockedCommits: Local pack skipping

    @Test("Local packs are skipped during checkout")
    func checkoutSkipsLocalPacks() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        // Lockfile with only a local pack — should succeed since locals are skipped
        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "my-local", sourceURL: "/path/to/local", commitSHA: "local")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        // Should NOT throw — the only pack is local and gets skipped
        try ops.checkoutLockedCommits(at: project)
    }

    // MARK: - checkoutLockedCommits: Path containment

    @Test("Rejects identifier with path traversal")
    func checkoutRejectsPathTraversal() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let env = Environment(home: home)
        try FileManager.default.createDirectory(at: env.packsDirectory, withIntermediateDirectories: true)

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "../evil", sourceURL: "https://example.com", commitSHA: "abcdef0123")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    // MARK: - checkoutLockedCommits: Missing pack directory

    @Test("Throws when pack directory does not exist on disk")
    func checkoutMissingPackDirectory() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let env = Environment(home: home)
        try FileManager.default.createDirectory(at: env.packsDirectory, withIntermediateDirectories: true)
        // Don't create the actual pack subdirectory

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com/ios.git", commitSHA: "abcdef0123")]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    // MARK: - checkoutLockedCommits: Mixed valid and invalid

    @Test("Failure in one pack fails entire checkout even if local packs succeed")
    func checkoutMixedPacksFails() throws {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [
                // Local pack — will be skipped
                .init(identifier: "my-local", sourceURL: "/path/to/local", commitSHA: "local"),
                // Invalid SHA — will fail
                .init(identifier: "bad-pack", sourceURL: "https://example.com", commitSHA: "INVALID!"),
            ]
        )
        try lockfile.save(projectRoot: project)

        let ops = makeOperations(home: home)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }

    // MARK: - updatePacks: Empty registry

    @Test("updatePacks returns early when no packs registered")
    func updatePacksEmptyRegistry() throws {
        let home = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: home) }

        try writeRegistry([], home: home)

        let ops = makeOperations(home: home)
        // Should not throw — early return for empty registry
        try ops.updatePacks()
    }

    // MARK: - checkoutLockedCommits: Git operations (mock-based)

    /// Set up a locked pack with a real pack directory and lockfile, returning
    /// the dirs and mock shell for further configuration.
    private func makeLockedPackFixture() throws -> (home: URL, project: URL, shell: MockShellRunner) {
        let home = try makeTmpDir()
        let project = try makeTmpDir()
        let env = Environment(home: home)
        let packPath = env.packsDirectory.appendingPathComponent("ios")
        try FileManager.default.createDirectory(at: packPath, withIntermediateDirectories: true)

        let lockfile = Lockfile(
            lockVersion: 1, generatedAt: "now", mcsVersion: "test",
            packs: [.init(identifier: "ios", sourceURL: "https://example.com/ios.git", commitSHA: "abcdef0123")]
        )
        try lockfile.save(projectRoot: project)
        return (home, project, MockShellRunner(environment: env))
    }

    @Test("checkout calls git checkout with correct SHA")
    func checkoutCallsGitCheckout() throws {
        let (home, project, mockShell) = try makeLockedPackFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        let ops = makeOperations(home: home, shell: mockShell)
        try ops.checkoutLockedCommits(at: project)

        #expect(mockShell.runCalls.count == 1)
        let call = mockShell.runCalls[0]
        #expect(call.arguments.contains("checkout"))
        #expect(call.arguments.contains("abcdef0123"))
        #expect(call.arguments.contains("-C"))
    }

    @Test("checkout retries with fetch on initial failure")
    func checkoutRetriesWithFetch() throws {
        let (home, project, mockShell) = try makeLockedPackFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        mockShell.runResults = [
            ShellResult(exitCode: 1, stdout: "", stderr: "error: pathspec"),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
        ]

        let ops = makeOperations(home: home, shell: mockShell)
        try ops.checkoutLockedCommits(at: project)

        #expect(mockShell.runCalls.count == 3)
        #expect(mockShell.runCalls[0].arguments.contains("checkout"))
        #expect(mockShell.runCalls[1].arguments.contains("fetch"))
        #expect(mockShell.runCalls[2].arguments.contains("checkout"))
    }

    @Test("checkout fails when retry also fails")
    func checkoutFailsWhenRetryFails() throws {
        let (home, project, mockShell) = try makeLockedPackFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: project)
        }

        mockShell.result = ShellResult(exitCode: 1, stdout: "", stderr: "error: pathspec")

        let ops = makeOperations(home: home, shell: mockShell)
        #expect(throws: ExitCode.self) {
            try ops.checkoutLockedCommits(at: project)
        }
    }
}
