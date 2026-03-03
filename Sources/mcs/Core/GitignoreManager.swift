import Foundation

/// Manages the global gitignore file. Resolves the correct path,
/// creates the file if needed, and adds entries idempotently.
struct GitignoreManager: Sendable {
    let shell: ShellRunner

    /// Core entries managed by mcs (not pack-specific).
    static let coreEntries: [String] = [
        Constants.FileNames.claudeDirectory,
        "*.local.*",
        "\(Constants.FileNames.claudeDirectory)/\(Constants.FileNames.mcsProject)",
    ]

    /// Resolve the global gitignore file path.
    /// Checks `git config core.excludesFile`, falls back to `~/.config/git/ignore`.
    func resolveGlobalGitignorePath() -> URL {
        let result = shell.run(
            shell.environment.gitPath,
            arguments: ["config", "--global", "core.excludesFile"]
        )
        if result.succeeded, !result.stdout.isEmpty {
            let path = result.stdout.replacingOccurrences(
                of: "~",
                with: FileManager.default.homeDirectoryForCurrentUser.path
            )
            return URL(fileURLWithPath: path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config")
            .appendingPathComponent("git")
            .appendingPathComponent("ignore")
    }

    /// Ensure the global gitignore file exists, creating parent directories as needed.
    func ensureFileExists() throws {
        let path = resolveGlobalGitignorePath()
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
        }
    }

    /// Add an entry to the global gitignore if not already present.
    func addEntry(_ entry: String) throws {
        try ensureFileExists()
        let path = resolveGlobalGitignorePath()
        let content = try String(contentsOf: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        if !lines.contains(entry) {
            var updated = content
            if !updated.isEmpty, !updated.hasSuffix("\n") {
                updated += "\n"
            }
            updated += entry + "\n"
            try updated.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    /// Remove an entry from the global gitignore.
    /// Returns `true` if the entry was found and removed.
    @discardableResult
    func removeEntry(_ entry: String) throws -> Bool {
        let path = resolveGlobalGitignorePath()
        guard FileManager.default.fileExists(atPath: path.path) else { return false }

        let content = try String(contentsOf: path, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let filtered = lines.filter { $0 != entry }

        guard filtered.count < lines.count else { return false }

        let updated = filtered.joined(separator: "\n")
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return true
    }

    /// Add all core gitignore entries.
    func addCoreEntries() throws {
        for entry in Self.coreEntries {
            try addEntry(entry)
        }
    }
}
