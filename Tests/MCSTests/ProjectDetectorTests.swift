import Foundation
@testable import mcs
import Testing

struct ProjectDetectorTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdetect-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Finds project root via .git directory")
    func findsGitRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create project structure: tmpDir/.git/ and tmpDir/Sources/
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let sourcesDir = tmpDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: sourcesDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Finds project root via CLAUDE.local.md")
    func findsCLAUDELocalRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create CLAUDE.local.md at root
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        let subDir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: subDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Finds project root via .claude/.mcs-project")
    func findsMCSProjectRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create .claude/.mcs-project (no .git or CLAUDE.local.md)
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "{}".write(
            to: claudeDir.appendingPathComponent(".mcs-project"),
            atomically: true, encoding: .utf8
        )
        let subDir = tmpDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let root = ProjectDetector.findProjectRoot(from: subDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }

    @Test("Prefers .git over CLAUDE.local.md at same level")
    func prefersGitAtSameLevel() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try "test".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let root = ProjectDetector.findProjectRoot(from: tmpDir)
        #expect(root?.standardizedFileURL == tmpDir.standardizedFileURL)
    }
}

// MARK: - resolveProjectKey Tests

struct ProjectDetectorResolveKeyTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-resolvekey-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Returns matching key when projectRoot equals git root")
    func exactMatch() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let keys: Set<String> = [tmpDir.standardizedFileURL.path]
        let result = ProjectDetector.resolveProjectKey(from: tmpDir, in: keys)
        #expect(result == tmpDir.standardizedFileURL.path)
    }

    @Test("Walks up from subdirectory to find key at git root")
    func walkUpToGitRoot() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let subDir = tmpDir.appendingPathComponent("packages/my-lib")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let keys: Set<String> = [tmpDir.standardizedFileURL.path]
        let result = ProjectDetector.resolveProjectKey(from: subDir, in: keys)
        #expect(result == tmpDir.standardizedFileURL.path)
    }

    @Test("Stops at git boundary and does not escape the repo")
    func stopsAtGitBoundary() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outer = tmpDir.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("inner")
        try FileManager.default.createDirectory(
            at: outer.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: inner.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        // Key is at outer, but search starts at inner — should NOT find outer
        let keys: Set<String> = [outer.standardizedFileURL.path]
        let result = ProjectDetector.resolveProjectKey(from: inner, in: keys)
        #expect(result == nil)
    }

    @Test("Returns nil when no key matches")
    func noMatch() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let keys: Set = ["/some/other/path"]
        let result = ProjectDetector.resolveProjectKey(from: tmpDir, in: keys)
        #expect(result == nil)
    }

    @Test("Returns nil when project keys set is empty")
    func emptyKeys() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = ProjectDetector.resolveProjectKey(from: tmpDir, in: [])
        #expect(result == nil)
    }
}

// MARK: - ProjectDoctorChecks

struct ProjectDoctorCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-projdoctor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CLAUDEMDFreshnessCheck (project-scoped)

    @Test("CLAUDEMDFreshnessCheck skips when no CLAUDE.local.md")
    func freshnessCheckSkipsWhenMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("CLAUDEMDFreshnessCheck warns when no section markers")
    func freshnessCheckWarnsNoMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Just a plain file\nNo markers here.\n".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .warn = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    @Test("CLAUDEMDFreshnessCheck warns when no stored values")
    func freshnessCheckWarnsNoStoredValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Some content here
        <!-- mcs:end core -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: .shared,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
        if case .warn = check.check() {
            // expected — no .mcs-project means no stored values
        } else {
            #expect(Bool(false), "Expected .warn result")
        }
    }

    // MARK: - ProjectStateFileCheck

    @Test("ProjectStateFileCheck skips when no CLAUDE.local.md")
    func stateCheckSkipsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .skip = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .skip result")
        }
    }

    @Test("ProjectStateFileCheck fails when CLAUDE.local.md exists but .mcs-project missing")
    func stateCheckFailsMissingProjectFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .fail = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .fail result")
        }
    }

    @Test("ProjectStateFileCheck warns on a corrupt .mcs-project and its fix leaves the file alone")
    func stateCheckLeavesCorruptFileAlone() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        let claudeDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(".mcs-project")
        try "{ not json".write(to: stateFile, atomically: true, encoding: .utf8)

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .warn = check.check() {} else {
            Issue.record("Expected .warn for a corrupt .mcs-project")
        }
        if case .notFixable = check.fix() {} else {
            Issue.record("Expected .notFixable for a corrupt .mcs-project")
        }
        #expect(try String(contentsOf: stateFile, encoding: .utf8) == "{ not json")
    }

    @Test("ProjectStateFileCheck passes when .mcs-project exists without CLAUDE.local.md")
    func stateCheckPassesWithoutClaudeLocal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Only .mcs-project, no CLAUDE.local.md (pack with no templates)
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("tech-to-pm-translator")
        try state.save()

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected — valid state, pack just has no templates
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectStateFileCheck passes when both files exist")
    func stateCheckPassesBothPresent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# Project config".write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )
        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("ios")
        try state.save()

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        if case .pass = check.check() {
            // expected
        } else {
            #expect(Bool(false), "Expected .pass result")
        }
    }

    @Test("ProjectStateFileCheck fix creates .mcs-project from section markers")
    func stateCheckFixCreatesFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let version = MCSVersion.current
        let content = """
        <!-- mcs:begin core v\(version) -->
        Core content
        <!-- mcs:end core -->
        <!-- mcs:begin ios v\(version) -->
        iOS content
        <!-- mcs:end ios -->
        """
        try content.write(
            to: tmpDir.appendingPathComponent("CLAUDE.local.md"),
            atomically: true, encoding: .utf8
        )

        let check = ProjectStateFileCheck(projectRoot: tmpDir)
        let fixResult = check.fix()
        if case .fixed = fixResult {
            // Verify the state file was created
            let state = try ProjectState(projectRoot: tmpDir)
            #expect(state.exists)
            #expect(state.configuredPacks.contains("ios"))
        } else {
            #expect(Bool(false), "Expected .fixed result, got \(fixResult)")
        }
    }
}
