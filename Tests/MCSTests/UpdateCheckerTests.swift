import Foundation
@testable import mcs
import Testing

// MARK: - Cache Tests

struct UpdateCheckerCacheTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-updatechecker-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeChecker(home: URL) -> UpdateChecker {
        let env = Environment(home: home)
        let shell = ShellRunner(environment: env)
        return UpdateChecker(environment: env, shell: shell)
    }

    private func writeCacheFile(at env: Environment, timestamp: Date, result: UpdateChecker.CheckResult) throws {
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: timestamp),
            result: result,
            perPackIgnoreHash: nil
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: env.updateCheckCacheFile, options: .atomic)
    }

    private var emptyResult: UpdateChecker.CheckResult {
        UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil)
    }

    @Test("loadCache returns nil when file does not exist")
    func cacheNilWhenMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let checker = makeChecker(home: tmpDir)
        #expect(checker.loadCache() == nil)
    }

    @Test("loadCache returns cached result when file is valid")
    func cacheLoadsValidFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        try writeCacheFile(at: env, timestamp: Date().addingTimeInterval(-3600), result: emptyResult)

        let checker = makeChecker(home: tmpDir)
        let cached = checker.loadCache()
        #expect(cached != nil)
        #expect(cached?.result.isEmpty == true)
    }

    @Test("loadCache returns nil when file content is corrupt")
    func cacheNilWhenCorrupt() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let mcsDir = tmpDir.appendingPathComponent(".mcs")
        try FileManager.default.createDirectory(at: mcsDir, withIntermediateDirectories: true)
        try "not-json".write(to: env.updateCheckCacheFile, atomically: true, encoding: .utf8)

        let checker = makeChecker(home: tmpDir)
        #expect(checker.loadCache() == nil)
    }

    @Test("saveCache writes a decodable cache file")
    func saveCacheRoundtrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let checker = makeChecker(home: tmpDir)
        let result = UpdateChecker.CheckResult(
            packUpdates: [UpdateChecker.PackUpdate(
                identifier: "test", displayName: "Test", localSHA: "aaa", remoteSHA: "bbb"
            )],
            cliUpdate: nil
        )
        checker.saveCache(result)

        let cached = checker.loadCache()
        #expect(cached != nil)
        #expect(cached?.result.packUpdates.count == 1)
        #expect(cached?.result.packUpdates.first?.identifier == "test")
    }

    @Test("loadCache returns nil when CLI version changed")
    func cacheInvalidatedOnCLIUpgrade() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let staleResult = UpdateChecker.CheckResult(
            packUpdates: [],
            cliUpdate: UpdateChecker.CLIUpdate(currentVersion: "1999.1.1", latestVersion: "2000.1.1")
        )
        try writeCacheFile(at: env, timestamp: Date(), result: staleResult)

        let checker = makeChecker(home: tmpDir)
        #expect(checker.loadCache() == nil)
    }

    @Test("invalidateCache deletes the cache file")
    func invalidateCache() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let checker = makeChecker(home: tmpDir)
        checker.saveCache(emptyResult)

        let env = Environment(home: tmpDir)
        #expect(FileManager.default.fileExists(atPath: env.updateCheckCacheFile.path))

        #expect(UpdateChecker.invalidateCache(environment: env))
        #expect(!FileManager.default.fileExists(atPath: env.updateCheckCacheFile.path))
    }
}

// MARK: - performCheck Tests

struct UpdateCheckerPerformCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-performcheck-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeChecker(home: URL) -> UpdateChecker {
        let env = Environment(home: home)
        let shell = ShellRunner(environment: env)
        return UpdateChecker(environment: env, shell: shell)
    }

    private func writeFreshCache(at env: Environment, result: UpdateChecker.CheckResult) throws {
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: result,
            perPackIgnoreHash: nil
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: env.updateCheckCacheFile, options: .atomic)
    }

    @Test("Returns cached result when cache is fresh")
    func cachedResultReturnedByDefault() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cachedResult = UpdateChecker.CheckResult(
            packUpdates: [UpdateChecker.PackUpdate(
                identifier: "cached-pack", displayName: "Cached", localSHA: "aaa", remoteSHA: "bbb"
            )],
            cliUpdate: nil
        )
        try writeFreshCache(at: env, result: cachedResult)

        let checker = makeChecker(home: tmpDir)
        let result = checker.performCheck(entries: [], checkPacks: true, checkCLI: false)

        // Should return cached result, not do network calls (entries is empty so network would return nothing)
        #expect(result.packUpdates.count == 1)
        #expect(result.packUpdates.first?.identifier == "cached-pack")
    }

    @Test("forceRefresh bypasses cache and does fresh check")
    func forceRefreshBypassesCache() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cachedResult = UpdateChecker.CheckResult(
            packUpdates: [UpdateChecker.PackUpdate(
                identifier: "stale", displayName: "Stale", localSHA: "aaa", remoteSHA: "bbb"
            )],
            cliUpdate: nil
        )
        try writeFreshCache(at: env, result: cachedResult)

        let checker = makeChecker(home: tmpDir)
        let result = checker.performCheck(entries: [], forceRefresh: true, checkPacks: true, checkCLI: false)

        // Should NOT return cached "stale" pack — should do fresh check with empty entries
        #expect(result.packUpdates.isEmpty)
    }

    @Test("Stale cache triggers fresh check")
    func staleCacheTriggersFreshCheck() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let staleResult = UpdateChecker.CheckResult(
            packUpdates: [UpdateChecker.PackUpdate(
                identifier: "old-pack", displayName: "Old", localSHA: "aaa", remoteSHA: "bbb"
            )],
            cliUpdate: nil
        )
        // Write cache with timestamp older than 24 hours
        let staleTimestamp = Date().addingTimeInterval(-90000)
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: staleTimestamp),
            result: staleResult,
            perPackIgnoreHash: nil
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: env.updateCheckCacheFile, options: .atomic)

        let checker = makeChecker(home: tmpDir)
        let result = checker.performCheck(entries: [], checkPacks: true, checkCLI: false)

        // Cache is stale (>24h), so should do fresh check with empty entries → empty result
        #expect(result.packUpdates.isEmpty)
    }

    @Test("performCheck saves cache after network check")
    func savesCache() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        #expect(!FileManager.default.fileExists(atPath: env.updateCheckCacheFile.path))

        let checker = makeChecker(home: tmpDir)
        _ = checker.performCheck(entries: [], checkPacks: true, checkCLI: false)

        #expect(FileManager.default.fileExists(atPath: env.updateCheckCacheFile.path))
    }
}

// MARK: - Noise Filter Tests (issue #338)

struct UpdateCheckerClassifyDiffPathsTests {
    @Test("Empty diff → suppressed")
    func emptyIsSuppressed() {
        #expect(UpdateChecker.classifyDiffPaths([]) == .suppressed)
        #expect(UpdateChecker.classifyDiffPaths(["", "  "]) == .suppressed)
    }

    @Test("README-only diff → suppressed")
    func readmeOnlySuppressed() {
        #expect(UpdateChecker.classifyDiffPaths(["README.md"]) == .suppressed)
    }

    @Test("All-infra root files → suppressed")
    func infraFilesSuppressed() {
        let paths = ["README.md", "LICENSE", "CHANGELOG.md", ".gitignore", "Makefile"]
        #expect(UpdateChecker.classifyDiffPaths(paths) == .suppressed)
    }

    @Test("techpack.yaml change → always material (supply-chain invariant)")
    func manifestAlwaysMaterial() {
        #expect(UpdateChecker.classifyDiffPaths(["techpack.yaml"])
            == .material(["techpack.yaml"]))
        // Even mixed with noise, manifest short-circuits to material.
        #expect(UpdateChecker.classifyDiffPaths(["README.md", "techpack.yaml"])
            == .material(["techpack.yaml"]))
    }

    @Test("Ignored-dir leading segment → suppressed")
    func ignoredDirsSuppressed() {
        #expect(UpdateChecker.classifyDiffPaths([".github/workflows/ci.yml"]) == .suppressed)
        #expect(UpdateChecker.classifyDiffPaths(["node_modules/foo/bar.js"]) == .suppressed)
        #expect(UpdateChecker.classifyDiffPaths([".build/debug/output"]) == .suppressed)
    }

    @Test("Hook script change → material")
    func hookScriptMaterial() {
        let result = UpdateChecker.classifyDiffPaths(["hooks/session-start.sh"])
        #expect(result == .material(["hooks/session-start.sh"]))
    }

    @Test("Mixed material + noise → material (only material paths)")
    func mixedReturnsMaterialOnly() {
        let result = UpdateChecker.classifyDiffPaths([
            "README.md", "hooks/session-start.sh", ".github/workflows/ci.yml",
        ])
        #expect(result == .material(["hooks/session-start.sh"]))
    }

    @Test("Infra basename inside subdir → material (basename match only applies to root)")
    func nonRootInfraNotSuppressed() {
        // `hooks/README.md` is NOT suppressed — only the pack-root README is.
        let result = UpdateChecker.classifyDiffPaths(["hooks/README.md"])
        #expect(result == .material(["hooks/README.md"]))
    }

    @Test("Unknown root dir (docs/) → material (Phase 1 has no author ignore: yet)")
    func unknownDirMaterial() {
        let result = UpdateChecker.classifyDiffPaths(["docs/guide.md"])
        #expect(result == .material(["docs/guide.md"]))
    }

    @Test("Whitespace and empty lines are stripped")
    func whitespaceStripped() {
        let result = UpdateChecker.classifyDiffPaths([
            "  README.md  ", "", "   ", "LICENSE",
        ])
        #expect(result == .suppressed)
    }

    @Test("CRLF line endings: trailing `\\r` is stripped before deny-list match")
    func crlfStrippedBeforeMatch() {
        // git with `core.autocrlf=true` can emit `path\r\n`. After splitting on `\n`,
        // each path keeps a trailing `\r`. Without `.whitespacesAndNewlines` trimming,
        // `README.md\r` would miss the deny-list and surface as material.
        let result = UpdateChecker.classifyDiffPaths([
            "README.md\r", ".github/workflows/ci.yml\r",
        ])
        #expect(result == .suppressed)
    }
}

struct UpdateCheckerOrchestratorTests {
    private func makeEntry(
        identifier: String = "pack-a",
        commitSHA: String = "old123",
        ref: String? = nil,
        localPath: String? = nil
    ) -> PackRegistryFile.PackEntry {
        PackRegistryFile.PackEntry(
            identifier: identifier,
            displayName: identifier,
            author: nil,
            sourceURL: "https://example.com/\(identifier).git",
            ref: ref,
            commitSHA: commitSHA,
            localPath: localPath ?? identifier,
            addedAt: "2026-01-01T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: nil
        )
    }

    private func makeChecker(home: URL, mock: MockShellRunner) -> UpdateChecker {
        UpdateChecker(environment: Environment(home: home), shell: mock)
    }

    @Test("nil ref: fetch without ref arg, diff against origin/HEAD (mirrors PackFetcher.update)")
    func nilRefUsesOriginHEAD() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\nLICENSE\n", stderr: ""),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: makeEntry())

        #expect(result == .suppressed)
        #expect(mock.runCalls.count == 2)

        let expectedWorkDir = Environment(home: tmpDir).packsDirectory
            .appendingPathComponent("pack-a").path
        #expect(mock.runCalls[0].arguments == ["fetch", "--depth", "1", "origin"])
        #expect(mock.runCalls[0].workingDirectory == expectedWorkDir)
        // Diffed from the registry baseline, not HEAD — see `classifyUpstreamChange`.
        #expect(mock.runCalls[1].arguments == ["diff", "--name-only", "old123", "origin/HEAD"])
        #expect(mock.runCalls[1].workingDirectory == expectedWorkDir)
    }

    @Test("fetch + diff succeed with material → material")
    func fetchDiffMaterial() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "hooks/session-start.sh\n", stderr: ""),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: makeEntry())

        #expect(result == .material(["hooks/session-start.sh"]))
    }

    @Test("Custom entry.ref propagates through fetch + diff against FETCH_HEAD")
    func customRefPropagates() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        _ = checker.classifyUpstreamChange(entry: makeEntry(ref: "v2.0"))

        #expect(mock.runCalls[0].arguments == ["fetch", "--depth", "1", "origin", "v2.0"])
        #expect(mock.runCalls[1].arguments == ["diff", "--name-only", "old123", "FETCH_HEAD"])
    }

    @Test("Invalid entry.ref (argument injection) → .unknown(.fetchFailed); no git invocation")
    func invalidRefRejected() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: makeEntry(ref: "-rf"))

        #expect(result == .unknown(.fetchFailed))
        #expect(mock.runCalls.isEmpty, "Refs starting with `-` must never reach git")
    }

    @Test("resolvedPath nil (containment escape) → .unknown(.missingClone)")
    func missingCloneReturnsUnknown() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // localPath that escapes packsDirectory → PathContainment.safePath returns nil.
        let entry = makeEntry(identifier: "pack-a", localPath: "../escape")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: entry)

        #expect(result == .unknown(.missingClone))
        #expect(mock.runCalls.isEmpty, "No git invocation when the clone path can't be resolved")
    }

    @Test("Clone directory absent on disk → .unknown(.missingClone), no git invoked")
    func deletedCloneReturnsMissingClone() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Registry says the pack is at `~/.mcs/packs/pack-a/`, but the directory was deleted.
        // `preparePackDir` is intentionally NOT called here.
        let entry = makeEntry(identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: entry)

        #expect(result == .unknown(.missingClone))
        #expect(mock.runCalls.isEmpty, "No git invocation when the clone is missing on disk")
    }

    @Test("fetch fails → .unknown(.fetchFailed); diff is not called")
    func fetchFailsNeverHide() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 128, stdout: "", stderr: "fatal: unable to access"),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: makeEntry())

        #expect(result == .unknown(.fetchFailed))
        #expect(mock.runCalls.count == 1)
    }

    @Test("diff fails → .unknown(.diffFailed)")
    func diffFailsNeverHide() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 128, stdout: "", stderr: "fatal: bad revision"),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        let result = checker.classifyUpstreamChange(entry: makeEntry())

        #expect(result == .unknown(.diffFailed))
    }

    @Test("git commands pass GIT_TERMINAL_PROMPT=0 to avoid credential prompts")
    func credentialSuppression() throws {
        let tmpDir = try makeTmpDir(label: "classify")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let mock = MockShellRunner(environment: Environment(home: tmpDir))
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]

        let checker = makeChecker(home: tmpDir, mock: mock)
        _ = checker.classifyUpstreamChange(entry: makeEntry())

        for call in mock.runCalls {
            #expect(call.additionalEnvironment["GIT_TERMINAL_PROMPT"] == "0")
        }
    }
}

struct UpdateCheckerPackUpdatesTests {
    private func writeRegistry(at env: Environment, entries: [PackRegistryFile.PackEntry]) throws {
        let registry = PackRegistryFile(path: env.packsRegistry)
        var data = PackRegistryFile.RegistryData()
        for entry in entries {
            registry.register(entry, in: &data)
        }
        try registry.save(data)
    }

    @Test("Noise-only upstream commit → no PackUpdate, registry commitSHA advances")
    func noiseSuppressedAndBaselineAdvances() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "old123")
        try writeRegistry(at: env, entries: [entry])

        let mock = MockShellRunner(environment: env)
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [entry])

        #expect(updates.isEmpty, "Noise-only upstream commit must not produce a notification")

        let registry = PackRegistryFile(path: env.packsRegistry)
        let data = try registry.load()
        #expect(registry.pack(identifier: "pack-a", in: data)?.commitSHA == "new456")
    }

    @Test("Material upstream commit → PackUpdate emitted, registry NOT advanced")
    func materialEmitsUpdateAndPreservesBaseline() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "old123")
        try writeRegistry(at: env, entries: [entry])

        let mock = MockShellRunner(environment: env)
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "hooks/session-start.sh\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [entry])

        #expect(updates.count == 1)
        #expect(updates.first?.identifier == "pack-a")
        #expect(updates.first?.remoteSHA == "new456")

        // Registry preserved at the old SHA — `mcs pack update` is responsible for advancing it.
        let registry = PackRegistryFile(path: env.packsRegistry)
        let data = try registry.load()
        #expect(registry.pack(identifier: "pack-a", in: data)?.commitSHA == "old123")
    }

    @Test("fetch failure during classification → never-hide (PackUpdate emitted)")
    func fetchFailureSurfaces() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "old123")
        try writeRegistry(at: env, entries: [entry])

        let mock = MockShellRunner(environment: env)
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
            ShellResult(exitCode: 128, stdout: "", stderr: "fatal: unable to access"),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [entry])

        #expect(updates.count == 1, "fetch failure must never hide a real upstream change")
    }

    @Test("ls-remote SHA matches local → no classifier invocation, no update")
    func noChangeSkipsClassifier() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "same789")
        try writeRegistry(at: env, entries: [entry])

        let mock = MockShellRunner(environment: env)
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "same789\tHEAD\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [entry])

        #expect(updates.isEmpty)
        #expect(mock.runCalls.count == 1)
    }

    @Test("Invalid registry ref → pack silently skipped (no ls-remote, no notification)")
    func invalidRegistryRefSkipped() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        // ref = "-rf" simulates registry corruption — would be argument injection if passed to git.
        let entry = PackRegistryFile.PackEntry(
            identifier: "pack-a",
            displayName: "pack-a",
            author: nil,
            sourceURL: "https://example.com/pack-a.git",
            ref: "-rf",
            commitSHA: "old123",
            localPath: "pack-a",
            addedAt: "2026-01-01T00:00:00Z",
            trustedScriptHashes: [:],
            isLocal: nil
        )
        try writeRegistry(at: env, entries: [entry])

        let mock = MockShellRunner(environment: env)
        let updates = UpdateChecker(environment: env, shell: mock).checkPackUpdates(entries: [entry])

        #expect(updates.isEmpty)
        #expect(mock.runCalls.isEmpty, "Invalid ref must never invoke git, even ls-remote")
    }

    @Test("Local packs are filtered out before any git invocation")
    func localPacksSkippedFromGitChecks() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "git-pack")

        let env = Environment(home: tmpDir)
        let gitEntry = makeRegistryEntry(identifier: "git-pack", commitSHA: "old999")
        let localEntry = makeLocalRegistryEntry(identifier: "local-pack", localPath: "/tmp/local-pack")
        try writeRegistry(at: env, entries: [gitEntry, localEntry])

        let mock = MockShellRunner(environment: env)
        mock.runResultsByFirstArg = [
            "ls-remote": ShellResult(exitCode: 0, stdout: "old999\tHEAD\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [gitEntry, localEntry])

        #expect(updates.isEmpty)
        // Exactly one ls-remote call (for the git pack) — the local pack is filtered out.
        #expect(mock.runCalls.count == 1)
        #expect(mock.runCalls[0].arguments == ["ls-remote", gitEntry.sourceURL, "HEAD"])
    }

    @Test("Multi-pack parallel run: each pack classified independently with the right SHA write")
    func multiPackParallelClassification() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let identifiers = ["pack-a", "pack-b", "pack-c"]
        for id in identifiers {
            try preparePackDir(home: tmpDir, identifier: id)
        }

        let env = Environment(home: tmpDir)
        let entries = identifiers.map { id in
            makeRegistryEntry(identifier: id, commitSHA: "old-\(id)")
        }
        try writeRegistry(at: env, entries: entries)

        let mock = MockShellRunner(environment: env)
        mock.runResultsByFirstArg = [
            "ls-remote": ShellResult(exitCode: 0, stdout: "shared-new-sha\tHEAD\n", stderr: ""),
            "fetch": ShellResult(exitCode: 0, stdout: "", stderr: ""),
            "diff": ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: entries)

        #expect(updates.isEmpty, "All three packs noise-only → no notifications")
        #expect(mock.runCalls.count == 9, "3 packs × (ls-remote + fetch + diff)")

        // Each pack's registry SHA was advanced independently in the post-loop write.
        let registry = PackRegistryFile(path: env.packsRegistry)
        let data = try registry.load()
        for id in identifiers {
            #expect(registry.pack(identifier: id, in: data)?.commitSHA == "shared-new-sha")
        }
    }

    @Test("Registry-write failure: suppression sticks for this run, baseline does not advance")
    func registryWriteFailureContract() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        let mcsDir = tmpDir.appendingPathComponent(".mcs")
        defer {
            // Restore writability before cleanup — read-only parent prevents removal otherwise.
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: mcsDir.path
            )
            try? FileManager.default.removeItem(at: tmpDir)
        }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "old123")
        try writeRegistry(at: env, entries: [entry])

        // Lock down the `.mcs/` directory so atomic write-and-rename can't create a temp file.
        // File-level chmod 0444 is bypassed because `YAMLFile.save` writes-then-renames.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: mcsDir.path
        )

        let mock = MockShellRunner(environment: env)
        mock.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]

        let checker = UpdateChecker(environment: env, shell: mock)
        let updates = checker.checkPackUpdates(entries: [entry])

        // Suppression still happens this run — no notification is emitted.
        #expect(updates.isEmpty, "Suppression is independent of the write outcome")

        // But the registry SHA did NOT advance, so the next check will re-classify.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: mcsDir.path
        )
        let registry = PackRegistryFile(path: env.packsRegistry)
        let data = try registry.load()
        #expect(registry.pack(identifier: "pack-a", in: data)?.commitSHA == "old123")
    }

    @Test("Cross-invocation persistence: advance from run 1 is honored in run 2")
    func crossInvocationPersistence() throws {
        let tmpDir = try makeTmpDir(label: "checkPackUpdates")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try preparePackDir(home: tmpDir, identifier: "pack-a")

        let env = Environment(home: tmpDir)
        let entry = makeRegistryEntry(identifier: "pack-a", commitSHA: "old123")
        try writeRegistry(at: env, entries: [entry])

        // Run 1: noise commit, suppress + advance to "new456".
        let mock1 = MockShellRunner(environment: env)
        mock1.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
            ShellResult(exitCode: 0, stdout: "", stderr: ""),
            ShellResult(exitCode: 0, stdout: "README.md\n", stderr: ""),
        ]
        let updates1 = UpdateChecker(environment: env, shell: mock1)
            .checkPackUpdates(entries: [entry])
        #expect(updates1.isEmpty)

        // Reload entry from registry to pick up the advanced SHA.
        let registry = PackRegistryFile(path: env.packsRegistry)
        let advancedEntry = try #require(registry.pack(identifier: "pack-a", in: registry.load()))
        #expect(advancedEntry.commitSHA == "new456")

        // Run 2: ls-remote returns the same SHA — no upstream change relative to the advanced
        // baseline → classifier is not invoked, no notification.
        let mock2 = MockShellRunner(environment: env)
        mock2.runResults = [
            ShellResult(exitCode: 0, stdout: "new456\tHEAD\n", stderr: ""),
        ]
        let updates2 = UpdateChecker(environment: env, shell: mock2)
            .checkPackUpdates(entries: [advancedEntry])

        #expect(updates2.isEmpty)
        #expect(mock2.runCalls.count == 1, "Only ls-remote — no fetch/diff after baseline caught up")
    }
}

// MARK: - Manifest ignore: integration (issue #338 Phase 2)

struct UpdateCheckerIgnoreFieldTests {
    private func ignoreManifest(_ ignore: [String]?) -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1,
            identifier: "p",
            displayName: "P",
            description: "x",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: ignore
        )
    }

    @Test("classifyDiffPaths suppresses paths matched by manifest ignore:")
    func ignoreSuppressesAuthorPaths() {
        let manifest = ignoreManifest(["docs/", "examples/"])
        // docs/guide.md isn't in the built-in deny-list (built-in covers `.github/`, etc.)
        // so without the manifest it would be material; with it, suppressed.
        #expect(UpdateChecker.classifyDiffPaths(["docs/guide.md"]) ==
            .material(["docs/guide.md"]))
        #expect(UpdateChecker.classifyDiffPaths(["docs/guide.md"], manifest: manifest) ==
            .suppressed)
        #expect(UpdateChecker.classifyDiffPaths(["examples/sample.md"], manifest: manifest) ==
            .suppressed)
    }

    @Test("classifyDiffPaths still surfaces material paths even with broad ignore:")
    func ignoreDoesNotHideMaterial() {
        let manifest = ignoreManifest(["docs/"])
        let result = UpdateChecker.classifyDiffPaths(
            ["docs/guide.md", "hooks/handler.sh"],
            manifest: manifest
        )
        #expect(result == .material(["hooks/handler.sh"]))
    }

    @Test("ignore: cannot override the techpack.yaml-always-material invariant")
    func ignoreCannotSilenceManifest() {
        // Even if an author tried to silence techpack.yaml, the supply-chain invariant wins.
        let manifest = ignoreManifest(["techpack.yaml"])
        #expect(UpdateChecker.classifyDiffPaths(["techpack.yaml"], manifest: manifest) ==
            .material(["techpack.yaml"]))
    }

    @Test("ignoreHash differs when ignore: list changes")
    func ignoreHashSensitivity() {
        let a = ignoreManifest(["docs/"])
        let b = ignoreManifest(["docs/", "examples/"])
        let c = ignoreManifest(nil)

        #expect(UpdateChecker.ignoreHash(manifest: a) != UpdateChecker.ignoreHash(manifest: b))
        #expect(UpdateChecker.ignoreHash(manifest: a) != UpdateChecker.ignoreHash(manifest: c))
    }

    @Test("ignoreHash is order-independent (sorted internally)")
    func ignoreHashOrderIndependent() {
        let a = ignoreManifest(["docs/", "examples/"])
        let b = ignoreManifest(["examples/", "docs/"])
        #expect(UpdateChecker.ignoreHash(manifest: a) == UpdateChecker.ignoreHash(manifest: b))
    }

    @Test("loadCache returns nil when current ignore-hash differs from cached")
    func cacheInvalidatedOnIgnoreHashMismatch() throws {
        let tmpDir = try makeTmpDir(label: "ignore-cache")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil),
            perPackIgnoreHash: ["pack-a": "hash-old"]
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(cached)
        try data.write(to: env.updateCheckCacheFile, options: .atomic)

        let checker = UpdateChecker(environment: env, shell: ShellRunner(environment: env))

        // Same hashes → cache hit
        #expect(checker.loadCache(currentIgnoreHashes: ["pack-a": "hash-old"]) != nil)
        // Different hash → cache miss
        #expect(checker.loadCache(currentIgnoreHashes: ["pack-a": "hash-new"]) == nil)
        // No-arg call ignores hashes → still hit
        #expect(checker.loadCache() != nil)
    }

    @Test("loadCache invalidates when a pack appears in current but not in cached (pack added)")
    func cacheInvalidatedOnPackAdded() throws {
        let tmpDir = try makeTmpDir(label: "ignore-cache-add")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil),
            perPackIgnoreHash: ["pack-a": "hash-a"]
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(cached).write(to: env.updateCheckCacheFile, options: .atomic)

        let checker = UpdateChecker(environment: env, shell: ShellRunner(environment: env))

        // pack-b just got added; cached set is missing it → invalidate
        #expect(checker.loadCache(currentIgnoreHashes: ["pack-a": "hash-a", "pack-b": "hash-b"]) == nil)
    }

    @Test("loadCache invalidates when a pack disappears from current (manifest unreadable / removed)")
    func cacheInvalidatedOnPackDropped() throws {
        let tmpDir = try makeTmpDir(label: "ignore-cache-drop")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil),
            perPackIgnoreHash: ["pack-a": "hash-a", "pack-b": "hash-b"]
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(cached).write(to: env.updateCheckCacheFile, options: .atomic)

        let checker = UpdateChecker(environment: env, shell: ShellRunner(environment: env))

        // pack-b's manifest is now unreadable → it dropped out of currentIgnoreHashes.
        // Without bidirectional check, the cache would still serve stale suppression for pack-b.
        #expect(checker.loadCache(currentIgnoreHashes: ["pack-a": "hash-a"]) == nil)
    }

    @Test("loadCache without currentIgnoreHashes ignores pack-hash drift (CLI-only check)")
    func cacheNotInvalidatedWhenIgnoreHashesNotProvided() throws {
        let tmpDir = try makeTmpDir(label: "ignore-cache-nil")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let cached = UpdateChecker.CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil),
            perPackIgnoreHash: ["pack-a": "hash-a", "pack-b": "hash-b"]
        )
        let dir = env.updateCheckCacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(cached).write(to: env.updateCheckCacheFile, options: .atomic)

        let checker = UpdateChecker(environment: env, shell: ShellRunner(environment: env))

        // checkPacks=false path passes nil → cooldown for the CLI check is preserved even when
        // the cache holds prior pack-hashes.
        #expect(checker.loadCache(currentIgnoreHashes: nil) != nil)
    }
}

// MARK: - Parsing Tests

struct UpdateCheckerParsingTests {
    @Test("parseRemoteSHA extracts SHA from valid ls-remote output")
    func parseValidSHA() {
        let output = "abc123def456789\tHEAD\n"
        let sha = UpdateChecker.parseRemoteSHA(from: output)
        #expect(sha == "abc123def456789")
    }

    @Test("parseRemoteSHA returns nil for empty output")
    func parseEmptyOutput() {
        #expect(UpdateChecker.parseRemoteSHA(from: "") == nil)
        #expect(UpdateChecker.parseRemoteSHA(from: "   ") == nil)
    }

    @Test("parseRemoteSHA handles multi-line output (takes first line)")
    func parseMultiLine() {
        let output = """
        abc123\trefs/heads/main
        def456\trefs/heads/develop
        """
        let sha = UpdateChecker.parseRemoteSHA(from: output)
        #expect(sha == "abc123")
    }

    @Test("parseRemoteSHA prefers the peeled ^{} commit for annotated tags")
    func parsePrefersPeeledTag() {
        // Annotated tag: first line is the tag-object SHA, second is the peeled commit.
        // The peeled commit is what `rev-parse HEAD` would resolve to after a checkout —
        // writing the tag-object SHA into registry.yaml would desync the registry.
        let output = """
        tagobj11111111\trefs/tags/v1.0
        commit22222222\trefs/tags/v1.0^{}
        """
        #expect(UpdateChecker.parseRemoteSHA(from: output) == "commit22222222")
    }

    @Test("parseRemoteSHA returns first SHA when no peeled line is present (lightweight tag / branch)")
    func parseFirstSHAWhenNoPeeled() {
        let output = "abc123def\trefs/heads/main"
        #expect(UpdateChecker.parseRemoteSHA(from: output) == "abc123def")
    }

    @Test("parseLatestTag finds the highest CalVer tag")
    func parseLatestTagMultiple() {
        let output = """
        aaa\trefs/tags/2026.1.1
        bbb\trefs/tags/2026.3.22
        ccc\trefs/tags/2026.2.15
        ddd\trefs/tags/2025.12.1
        """
        let latest = UpdateChecker.parseLatestTag(from: output)
        #expect(latest == "2026.3.22")
    }

    @Test("parseLatestTag returns nil for empty output")
    func parseLatestTagEmpty() {
        #expect(UpdateChecker.parseLatestTag(from: "") == nil)
    }

    @Test("parseLatestTag skips non-CalVer tags")
    func parseLatestTagSkipsNonCalVer() {
        let output = """
        aaa\trefs/tags/v1.0
        bbb\trefs/tags/2026.3.22
        ccc\trefs/tags/beta
        """
        let latest = UpdateChecker.parseLatestTag(from: output)
        #expect(latest == "2026.3.22")
    }

    @Test("parseLatestTag returns nil when no CalVer tags exist")
    func parseLatestTagNoCalVer() {
        let output = """
        aaa\trefs/tags/v1.0
        bbb\trefs/tags/release-candidate
        """
        #expect(UpdateChecker.parseLatestTag(from: output) == nil)
    }
}

// MARK: - Version Comparison Tests

struct UpdateCheckerVersionTests {
    @Test("isNewer detects newer version")
    func newerVersion() {
        #expect(VersionCompare.isNewer(candidate: "2026.4.1", than: "2026.3.22"))
        #expect(VersionCompare.isNewer(candidate: "2027.1.1", than: "2026.12.31"))
        #expect(VersionCompare.isNewer(candidate: "2026.3.23", than: "2026.3.22"))
    }

    @Test("isNewer returns false for same version")
    func sameVersion() {
        #expect(!VersionCompare.isNewer(candidate: "2026.3.22", than: "2026.3.22"))
    }

    @Test("isNewer returns false for older version")
    func olderVersion() {
        #expect(!VersionCompare.isNewer(candidate: "2026.3.21", than: "2026.3.22"))
        #expect(!VersionCompare.isNewer(candidate: "2025.12.31", than: "2026.1.1"))
    }

    @Test("isNewer returns false for unparseable versions")
    func unparseable() {
        #expect(!VersionCompare.isNewer(candidate: "invalid", than: "2026.3.22"))
        #expect(!VersionCompare.isNewer(candidate: "2026.3.22", than: "invalid"))
    }
}

// MARK: - Hook Management Tests

struct UpdateCheckerHookTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("addHook creates SessionStart entry with correct command and metadata")
    func addHookCreatesEntry() {
        var settings = Settings()
        let added = UpdateChecker.addHook(to: &settings)
        #expect(added)

        let groups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
        #expect(groups.count == 1)
        let entry = groups.first?.hooks?.first
        #expect(entry?.command == "mcs check-updates --hook")
        #expect(entry?.timeout == 30)
        #expect(entry?.statusMessage == "Checking for updates...")
        #expect(entry?.type == "command")
    }

    @Test("addHook is idempotent")
    func addHookIdempotent() {
        var settings = Settings()
        UpdateChecker.addHook(to: &settings)
        let secondAdd = UpdateChecker.addHook(to: &settings)
        #expect(!secondAdd) // no-op, already present
        #expect(settings.hooks?[Constants.HookEvent.sessionStart.rawValue]?.count == 1)
    }

    @Test("removeHook removes the update check entry")
    func removeHookRemovesEntry() {
        var settings = Settings()
        UpdateChecker.addHook(to: &settings)
        let removed = UpdateChecker.removeHook(from: &settings)
        #expect(removed)
        #expect(settings.hooks == nil)
    }

    @Test("removeHook preserves other SessionStart hooks")
    func removeHookPreservesOthers() {
        var settings = Settings()
        settings.addHookEntry(event: "SessionStart", command: "bash .claude/hooks/startup.sh")
        UpdateChecker.addHook(to: &settings)

        UpdateChecker.removeHook(from: &settings)
        let groups = settings.hooks?["SessionStart"] ?? []
        #expect(groups.count == 1)
        #expect(groups.first?.hooks?.first?.command == "bash .claude/hooks/startup.sh")
    }

    @Test("addHook + removeHook round-trip leaves settings clean")
    func hookRoundTrip() {
        var settings = Settings()
        UpdateChecker.addHook(to: &settings)
        UpdateChecker.removeHook(from: &settings)
        #expect(settings.hooks == nil)
    }

    @Test("syncHook adds hook when config enabled")
    func syncHookAdds() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        // Create empty settings.json
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var config = MCSConfig()
        config.updateCheckPacks = true
        let output = CLIOutput()

        UpdateChecker.syncHook(config: config, env: env, output: output)

        let settings = try Settings.load(from: env.claudeSettings)
        let groups = settings.hooks?[Constants.HookEvent.sessionStart.rawValue] ?? []
        #expect(groups.count == 1)
        #expect(groups.first?.hooks?.first?.command == UpdateChecker.hookCommand)
    }

    @Test("syncHook removes hook when config disabled")
    func syncHookRemoves() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Pre-populate with the hook
        var initial = Settings()
        UpdateChecker.addHook(to: &initial)
        try initial.save(to: env.claudeSettings)

        var config = MCSConfig()
        config.updateCheckPacks = false
        config.updateCheckCLI = false
        let output = CLIOutput()

        UpdateChecker.syncHook(config: config, env: env, output: output)

        let settings = try Settings.load(from: env.claudeSettings)
        #expect(settings.hooks == nil)
    }
}

// MARK: - CheckResult Tests

struct UpdateCheckerResultTests {
    @Test("isEmpty returns true when no updates")
    func emptyResult() {
        let result = UpdateChecker.CheckResult(packUpdates: [], cliUpdate: nil)
        #expect(result.isEmpty)
    }

    @Test("isEmpty returns false with pack updates")
    func nonEmptyPackResult() {
        let result = UpdateChecker.CheckResult(
            packUpdates: [UpdateChecker.PackUpdate(
                identifier: "test", displayName: "Test", localSHA: "aaa", remoteSHA: "bbb"
            )],
            cliUpdate: nil
        )
        #expect(!result.isEmpty)
    }

    @Test("isEmpty returns false with CLI update")
    func nonEmptyCLIResult() {
        let result = UpdateChecker.CheckResult(
            packUpdates: [],
            cliUpdate: UpdateChecker.CLIUpdate(currentVersion: "1.0.0", latestVersion: "2.0.0")
        )
        #expect(!result.isEmpty)
    }
}
