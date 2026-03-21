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
