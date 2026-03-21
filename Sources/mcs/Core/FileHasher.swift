import CryptoKit
import Foundation

/// Pure CryptoKit utilities for SHA-256 file hashing.
/// Extracted from the deleted `Manifest` type — used by `PackTrustManager`
/// for trust verification and by `ComponentExecutor` for directory copies.
enum FileHasher {
    /// Compute SHA-256 hash of a file.
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
