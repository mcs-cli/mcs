import Foundation

/// Creates timestamped backups before overwriting files and tracks them for cleanup.
struct Backup {
    /// All backups created during this session.
    private(set) var createdBackups: [URL] = []

    /// Monotonic counter ensuring unique names within a single session.
    private var sequence: Int = 0

    /// Create a timestamped backup of the file at `path` if it exists.
    /// Returns the backup URL, or nil if the original file didn't exist.
    @discardableResult
    mutating func backupFile(at path: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let timestamp = formatter.string(from: Date())
        sequence += 1
        let backupPath = URL(fileURLWithPath: "\(path.path).backup.\(timestamp)_\(sequence)")

        try fm.copyItem(at: path, to: backupPath)
        createdBackups.append(backupPath)

        return backupPath
    }

    /// Find all backup files matching `*.backup.*` under the given directory.
    static func findBackups(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }

        var backups: [URL] = []
        for case let url as URL in enumerator
            where url.lastPathComponent.contains(".backup.") {
            backups.append(url)
        }
        return backups
    }

    /// A backup deletion that failed, with the reason.
    struct DeletionFailure {
        let url: URL
        let error: any Error
    }

    /// Delete the given backup files. Returns failures with error details.
    @discardableResult
    static func deleteBackups(_ backups: [URL]) -> [DeletionFailure] {
        let fm = FileManager.default
        var failures: [DeletionFailure] = []
        for backup in backups {
            do {
                try fm.removeItem(at: backup)
            } catch {
                failures.append(DeletionFailure(url: backup, error: error))
            }
        }
        return failures
    }
}
