import ArgumentParser
import Foundation

/// Errors thrown when the process lock cannot be acquired.
enum FileLockError: Error, LocalizedError {
    case acquireFailed(path: String)
    case openFailed(path: String, errno: Int32)
    case lockFailed(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case let .acquireFailed(path):
            "Another mcs process is running. Lock file: \(path)"
        case let .openFailed(path, code):
            "Could not open lock file at \(path): \(String(cString: strerror(code)))"
        case let .lockFailed(path, code):
            "Could not lock \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - LockedCommand Protocol

/// A command that acquires an exclusive process lock before executing.
///
/// Conform to `LockedCommand` instead of `ParsableCommand` for any command
/// that writes to shared state (config files, pack registry, project state).
/// The default `run()` acquires `~/.mcs/lock` via POSIX `flock()`
/// before calling `perform()`, and releases it when `perform()` returns or throws.
///
/// Override `skipLock` to bypass the lock for read-only modes (e.g. `--dry-run`).
///
/// Read-only commands (e.g. `pack list`, `doctor` without `--fix`) should
/// conform to `ParsableCommand` directly — no lock needed.
protocol LockedCommand: ParsableCommand {
    /// Return `true` to skip locking (e.g. for `--dry-run` or `--preview`).
    var skipLock: Bool { get }

    /// The command's work. Called inside the lock (or directly if `skipLock` is true).
    func perform() throws
}

extension LockedCommand {
    var skipLock: Bool {
        false
    }

    mutating func run() throws {
        let env = Environment()
        let cmd = self
        if skipLock {
            try cmd.perform()
        } else {
            try runHoldingLock(at: env.lockFile) {
                try cmd.perform()
            }
        }
    }
}

/// `EX_TEMPFAIL` from sysexits(3): another `mcs` process holds the lock, so a scheduled caller
/// can retry later instead of treating the run as a failure.
let lockContentionExitCode: Int32 = 75

/// Run `body` under the process lock, turning contention into `lockContentionExitCode` and a
/// stable `mcs: lock held:` stderr line rather than a generic failure.
func runHoldingLock(at lockFile: URL, body: () throws -> Void) throws {
    do {
        try withFileLock(at: lockFile, body: body)
    } catch let FileLockError.acquireFailed(path) {
        FileHandle.standardError.write(Data(
            "mcs: lock held: another mcs process is running (lock file: \(path))\n".utf8
        ))
        throw ExitCode(lockContentionExitCode)
    }
}

// MARK: - Low-level lock

/// Acquires an exclusive, non-blocking POSIX advisory lock on `path`,
/// executes `body`, and releases the lock when `body` returns or throws.
///
/// The lock file and its parent directories are created if they don't exist.
/// If another process holds the lock, throws ``FileLockError/acquireFailed``
/// immediately (non-blocking).
///
/// On process crash the OS automatically releases the lock when the
/// file descriptor closes.
func withFileLock<T>(at path: URL, body: () throws -> T) throws -> T {
    let dir = path.deletingLastPathComponent()
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir.path) {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let fd = open(path.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
        throw FileLockError.openFailed(path: path.path, errno: errno)
    }
    defer { close(fd) }

    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        let code = errno
        // Only contention means "retry later"; any other failure would retry forever.
        guard code == EWOULDBLOCK else {
            throw FileLockError.lockFailed(path: path.path, errno: code)
        }
        throw FileLockError.acquireFailed(path: path.path)
    }

    return try body()
}
