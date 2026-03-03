import Foundation
@testable import mcs
import Testing

@Suite("FileLock")
struct FileLockTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-filelock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Basic locking

    @Test("withFileLock executes body and returns result")
    func basicExecution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")
        let result = try withFileLock(at: lockFile) {
            42
        }
        #expect(result == 42)
    }

    @Test("withFileLock creates lock file if it does not exist")
    func createsLockFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")
        #expect(!FileManager.default.fileExists(atPath: lockFile.path))

        try withFileLock(at: lockFile) {}

        #expect(FileManager.default.fileExists(atPath: lockFile.path))
    }

    @Test("withFileLock creates parent directories if needed")
    func createsParentDirectories() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir
            .appendingPathComponent("nested")
            .appendingPathComponent("dir")
            .appendingPathComponent("lock")

        try withFileLock(at: lockFile) {}

        #expect(FileManager.default.fileExists(atPath: lockFile.path))
    }

    @Test("withFileLock propagates errors from body")
    func propagatesBodyErrors() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")

        #expect(throws: MCSError.self) {
            try withFileLock(at: lockFile) {
                throw MCSError.configurationFailed(reason: "test error")
            }
        }
    }

    @Test("withFileLock releases lock after body completes")
    func releasesLockAfterCompletion() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")

        try withFileLock(at: lockFile) {}

        // Second acquisition should succeed (lock was released)
        try withFileLock(at: lockFile) {}
    }

    @Test("withFileLock releases lock after body throws")
    func releasesLockAfterError() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")

        do {
            try withFileLock(at: lockFile) {
                throw MCSError.configurationFailed(reason: "test")
            }
        } catch {
            // Expected
        }

        // Second acquisition should succeed (lock was released despite error)
        try withFileLock(at: lockFile) {}
    }

    // MARK: - Contention

    @Test("withFileLock fails immediately when lock is held by another fd")
    func failsWhenLockHeld() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")

        // Hold a lock via raw flock on a separate file descriptor
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }

        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

        // withFileLock should fail immediately
        #expect(throws: FileLockError.self) {
            try withFileLock(at: lockFile) {}
        }
    }

    @Test("FileLockError.acquireFailed has descriptive message")
    func errorMessage() {
        let error = FileLockError.acquireFailed(path: "/tmp/lock")
        let description = error.localizedDescription
        #expect(description.contains("Another mcs process"))
        #expect(description.contains("/tmp/lock"))
    }

    // MARK: - Environment integration

    @Test("Environment.lockFile points to correct path")
    func environmentLockFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let env = Environment(home: tmpDir)
        let expected = tmpDir
            .appendingPathComponent(".mcs")
            .appendingPathComponent("lock")
            .path

        #expect(env.lockFile.path == expected)
    }
}
