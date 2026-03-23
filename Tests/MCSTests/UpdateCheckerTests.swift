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
            result: result
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

        UpdateChecker.invalidateCache(environment: env)
        #expect(!FileManager.default.fileExists(atPath: env.updateCheckCacheFile.path))
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
