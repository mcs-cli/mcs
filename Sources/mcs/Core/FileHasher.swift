import CryptoKit
import Foundation

/// Pure CryptoKit utilities for SHA-256 file hashing.
/// Extracted from the deleted `Manifest` type — used by `PackTrustManager`
/// for trust verification and by `ComponentExecutor` for directory copies.
enum FileHasher {
    /// Compute SHA-256 hash of a file.
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256(data: data)
    }

    /// Compute SHA-256 hex digest of an in-memory byte buffer.
    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// How a file on disk compares to a hash recorded when it was installed.
    ///
    /// Callers map these onto their own vocabulary — `FileContentCheck` reports them, and
    /// `ScopeDuplicationCheck` refuses to delete anything that is not `.matches` — but the
    /// policy for *what counts as drift* lives here so the two cannot disagree. A disagreement
    /// would mean deleting a file doctor elsewhere reports as user-modified.
    enum DriftState {
        case matches
        case missing
        case directory
        case changed
        case unreadable(any Error)
    }

    /// Compare a file against its recorded hash.
    ///
    /// A missing file has nothing to compare and a directory is covered by the entries for the
    /// files inside it, so neither is drift. An unreadable file is reported rather than assumed
    /// intact — the caller decides how cautious to be.
    static func drift(of url: URL, expecting expectedHash: String) -> DriftState {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        if isDirectory.boolValue { return .directory }
        do {
            return try sha256(of: url) == expectedHash ? .matches : .changed
        } catch {
            return .unreadable(error)
        }
    }

    /// Result of hashing all files in a directory, with per-file error resilience.
    struct DirectoryHashResult {
        let hashes: [(relativePath: String, hash: String)]
        let failures: [(relativePath: String, error: any Error)]
    }

    /// Compute SHA-256 hashes for all regular files in a directory (recursive).
    /// Per-file errors are collected in `failures` rather than aborting the whole operation.
    /// Throws only if the directory itself cannot be enumerated.
    static func directoryFileHashes(at url: URL) throws -> DirectoryHashResult {
        let fm = FileManager.default
        // Resolve symlinks to ensure consistent path comparison
        // (macOS /var → /private/var, /tmp → /private/tmp)
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(
            at: resolvedURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MCSError.fileOperationFailed(
                path: resolvedURL.path,
                reason: "Could not enumerate directory contents"
            )
        }

        var results: [(relativePath: String, hash: String)] = []
        var failures: [(relativePath: String, error: any Error)] = []
        let basePath = resolvedURL.path
        while let fileURL = enumerator.nextObject() as? URL {
            let resolvedFile = fileURL.resolvingSymlinksInPath()
            do {
                let resourceValues = try resolvedFile.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else { continue }
                let relativePath = PathContainment.relativePath(of: resolvedFile.path, within: basePath)
                let hash = try sha256(of: resolvedFile)
                results.append((relativePath, hash))
            } catch {
                let relativePath = PathContainment.relativePath(of: resolvedFile.path, within: basePath)
                failures.append((relativePath, error))
            }
        }
        return DirectoryHashResult(
            hashes: results.sorted { $0.relativePath < $1.relativePath },
            failures: failures
        )
    }
}
