import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import mcs
import Testing

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

    @Test("withFileLock does not leak the lock into exec'd children")
    func lockIsNotInheritedByChildren() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let lockFile = tmpDir.appendingPathComponent("lock")

        // posix_spawn hands every descriptor without FD_CLOEXEC to the child, exactly like the
        // forkpty + execve path in ShellRunner. Foundation.Process closes inherited descriptors
        // itself, so a Process-based child would pass with or without O_CLOEXEC on the lock.
        var child: pid_t = 0
        try withFileLock(at: lockFile) {
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
            defer { argv.forEach { free($0) } }
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            #expect(posix_spawn(&child, "/bin/sleep", nil, nil, argv, envp) == 0)
        }
        defer {
            if child > 0 {
                kill(child, SIGKILL)
                waitpid(child, nil, 0)
            }
        }
        #expect(child > 0)

        // The body has returned and the parent's descriptor is closed, so only a copy inherited by
        // the still-running child could hold the lock now.
        let fd = open(lockFile.path, O_RDWR)
        #expect(fd >= 0)
        defer { close(fd) }

        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "lock is still held by the exec'd child")
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
