import Foundation
@testable import mcs
import Testing

struct GitignoreManagerTests {
    // MARK: - removeEntry

    @Test("Remove existing entry from gitignore")
    func removeExistingEntry() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-gitignore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gitignorePath = tmpDir.appendingPathComponent("ignore")
        let content = ".claude\n*.local.*\n.mcs-project\n"
        try content.write(to: gitignorePath, atomically: true, encoding: .utf8)

        let manager = GitignoreManagerWithFixedPath(path: gitignorePath)
        let removed = try manager.removeEntry("*.local.*")
        #expect(removed == true)

        let updated = try String(contentsOf: gitignorePath, encoding: .utf8)
        #expect(!updated.contains("*.local.*"))
        #expect(updated.contains(".claude"))
        #expect(updated.contains(".mcs-project"))
    }

    @Test("Remove entry that does not exist returns false")
    func removeNonexistentEntry() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-gitignore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gitignorePath = tmpDir.appendingPathComponent("ignore")
        try ".claude\n".write(to: gitignorePath, atomically: true, encoding: .utf8)

        let manager = GitignoreManagerWithFixedPath(path: gitignorePath)
        let removed = try manager.removeEntry("nonexistent")
        #expect(removed == false)
    }

    @Test("Remove entry from nonexistent file returns false")
    func removeFromMissingFile() throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-gitignore-missing-\(UUID().uuidString)")
            .appendingPathComponent("ignore")

        let manager = GitignoreManagerWithFixedPath(path: nonexistent)
        let removed = try manager.removeEntry(".claude")
        #expect(removed == false)
    }

    // MARK: - Sandbox containment

    /// `GitignoreManager` both reads and writes the global gitignore, so resolving the process's
    /// own home instead of the injected `Environment`'s let any sandboxed caller — including the
    /// whole test suite — mutate the real user's `~/.config/git/ignore`. It also made
    /// `GitignoreCheck` report whatever the developer's machine happened to have, which is how a
    /// doctor test passed locally and on one CI runner while failing on another.
    @Test("Global gitignore path stays inside the injected environment's home")
    func resolvedPathIsContainedInEnvironmentHome() throws {
        let home = try makeGlobalTmpDir(label: "gitignore-containment")
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = GitignoreManager(shell: ShellRunner(environment: Environment(home: home)))
        let resolved = manager.resolveGlobalGitignorePath().resolvingSymlinksInPath().path
        let sandbox = home.resolvingSymlinksInPath().path

        #expect(resolved.hasPrefix(sandbox))
        #expect(!resolved.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}

/// Test helper that bypasses git config resolution and operates on a fixed file path.
/// Mirrors the `removeEntry` logic from `GitignoreManager` without needing a ShellRunner.
private struct GitignoreManagerWithFixedPath {
    let path: URL

    @discardableResult
    func removeEntry(_ entry: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        let content = try String(contentsOf: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let filtered = lines.filter { $0 != entry }

        guard filtered.count < lines.count else { return false }

        let updated = filtered.joined(separator: "\n")
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return true
    }
}
