import Foundation
@testable import mcs
import Testing

struct BackupTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - backupFile

    @Test("backupFile creates a timestamped copy")
    func backupCreatesFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let original = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: original, atomically: true, encoding: .utf8)

        var backup = Backup()
        let backupURL = try backup.backupFile(at: original)

        let url = try #require(backupURL)
        #expect(url.lastPathComponent.contains(".backup."))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let backupContent = try String(contentsOf: url, encoding: .utf8)
        #expect(backupContent == "content")
    }

    @Test("backupFile returns nil for nonexistent file")
    func backupNonexistent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let missing = tmpDir.appendingPathComponent("missing.txt")
        var backup = Backup()
        let result = try backup.backupFile(at: missing)

        #expect(result == nil)
    }

    @Test("backupFile tracks created backups")
    func backupTracking() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file1 = tmpDir.appendingPathComponent("a.txt")
        let file2 = tmpDir.appendingPathComponent("b.txt")
        try "a".write(to: file1, atomically: true, encoding: .utf8)
        try "b".write(to: file2, atomically: true, encoding: .utf8)

        var backup = Backup()
        try backup.backupFile(at: file1)
        try backup.backupFile(at: file2)

        #expect(backup.createdBackups.count == 2)
    }

    @Test("backupFile produces unique names for rapid successive backups")
    func backupUniqueNames() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let original = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: original, atomically: true, encoding: .utf8)

        var backup = Backup()
        let first = try backup.backupFile(at: original)
        let second = try backup.backupFile(at: original)

        #expect(first != nil)
        #expect(second != nil)
        #expect(try #require(first?.path) != second!.path)
    }

    // MARK: - findBackups

    @Test("findBackups discovers backup files including in hidden dirs")
    func findBackupsInHiddenDirs() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a backup file in a hidden directory
        let hiddenDir = tmpDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        let backupFile = hiddenDir.appendingPathComponent("settings.json.backup.20260220_120000")
        try "data".write(to: backupFile, atomically: true, encoding: .utf8)

        let found = Backup.findBackups(in: tmpDir)
        #expect(found.count == 1)
        #expect(found.first?.lastPathComponent == "settings.json.backup.20260220_120000")
    }

    @Test("findBackups returns empty for directory with no backups")
    func findBackupsEmpty() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "regular".write(
            to: tmpDir.appendingPathComponent("file.txt"),
            atomically: true, encoding: .utf8
        )

        let found = Backup.findBackups(in: tmpDir)
        #expect(found.isEmpty)
    }

    // MARK: - deleteBackups

    @Test("deleteBackups removes files and returns empty on success")
    func deleteSuccess() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let backup = tmpDir.appendingPathComponent("f.backup.123")
        try "data".write(to: backup, atomically: true, encoding: .utf8)

        let failures = Backup.deleteBackups([backup])
        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("deleteBackups returns failures for missing files")
    func deletePartialFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exists = tmpDir.appendingPathComponent("a.backup.1")
        let missing = tmpDir.appendingPathComponent("b.backup.2")
        try "data".write(to: exists, atomically: true, encoding: .utf8)

        let failures = Backup.deleteBackups([exists, missing])
        #expect(failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: exists.path))
    }
}
