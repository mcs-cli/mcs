import Foundation

/// The trust hash of a pack-hosted plugin's directory.
///
/// For a git checkout it covers the files git tracks there, not whatever sits on disk: a plugin
/// running in place writes its own artifacts (`__pycache__`, `.DS_Store`), and hashing them would
/// refuse the pack at load. Contents still come from the working tree, so a local edit is caught.
enum PluginTreeHasher {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case trackedFileMissing(String)
        case symlinkEscapesPlugin(path: String, target: String)
        case gitFailed(String)

        var errorDescription: String? {
            switch self {
            case let .trackedFileMissing(path):
                "\(path) is missing from the checkout — run 'mcs pack update' to restore it"
            case let .symlinkEscapesPlugin(path, target):
                "\(path) links to \(target), outside the plugin directory"
            case let .gitFailed(stderr):
                "could not list the plugin's tracked files: \(stderr)"
            }
        }
    }

    static func hash(
        _ plugin: PackMarketplace.HostedPlugin, packPath: URL, shell: any ShellRunning
    ) throws -> (hash: String, fileCount: Int) {
        let root = packPath.resolvingSymlinksInPath()
        let result = shell.run(
            shell.environment.gitPath, arguments: ["ls-files", "-s", "-z", "--", plugin.relativePath],
            workingDirectory: root.path,
            // The "not a git repository" check below reads git's message, which git translates.
            additionalEnvironment: ["LC_ALL": "C"]
        )
        guard result.succeeded else {
            // A local pack need not be a checkout; its trust is skipped at load anyway.
            if result.stderr.contains("not a git repository") { return try hashOnDisk(plugin.source) }
            throw Error.gitFailed(String(result.stderr.prefix(200)))
        }

        var lines: [String] = []
        for record in result.stdout.split(separator: "\0") where !record.isEmpty {
            // `<mode> <object> <stage>\t<path>`
            let parts = record.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let fields = parts[0].split(separator: " ")
            let path = String(parts[1])
            let hash = try entryHash(
                mode: fields.first ?? "", object: fields.dropFirst().first ?? "", path: path, root: root, source: plugin.source
            )
            lines.append("\(path)\0\(hash)")
        }
        return (FileHasher.sha256(data: Data(lines.sorted().joined(separator: "\n").utf8)), lines.count)
    }

    private static func entryHash(mode: Substring, object: Substring, path: String, root: URL, source: URL) throws -> String {
        let fileURL = root.appendingPathComponent(path)
        switch mode {
        case "160000":
            // A submodule: `PackFetcher` never recurses into one, so its directory stays empty and
            // nothing in it can load. Its pinned commit is the whole content. If clones ever recurse,
            // this has to hash the submodule's files instead.
            return "gitlink:\(object)"
        case "120000":
            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
            } catch {
                throw Error.trackedFileMissing(path)
            }
            // The target's own files are hashed only when they are inside the plugin, so a link
            // leaving it would let content change unreviewed — refuse rather than rely on Claude
            // Code declining to follow it.
            let resolved = URL(fileURLWithPath: target, relativeTo: fileURL.deletingLastPathComponent())
            guard PathContainment.isContained(url: resolved, within: source) else {
                throw Error.symlinkEscapesPlugin(path: path, target: target)
            }
            return "link:\(target)"
        default:
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw Error.trackedFileMissing(path) }
            return try FileHasher.sha256(of: fileURL)
        }
    }

    private static func hashOnDisk(_ source: URL) throws -> (hash: String, fileCount: Int) {
        let result = try FileHasher.directoryFileHashes(at: source)
        if let failure = result.failures.first { throw failure.error }
        let lines = result.hashes.map { "\($0.relativePath)\0\($0.hash)" }
        return (FileHasher.sha256(data: Data(lines.joined(separator: "\n").utf8)), lines.count)
    }
}
