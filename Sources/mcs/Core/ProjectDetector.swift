import Foundation

/// Detects the project root by walking up from a starting directory.
/// Looks for `.git/`, `CLAUDE.local.md`, or `.claude/.mcs-project` as project root indicators.
enum ProjectDetector {
    /// Walk up from `startingAt` looking for a project root marker.
    /// Returns the first ancestor directory containing `.git/`, `CLAUDE.local.md`,
    /// or `.claude/.mcs-project`, or nil.
    static func findProjectRoot(from startingPath: URL) -> URL? {
        let fm = FileManager.default
        var current = startingPath.standardizedFileURL

        while current.path != "/" {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            if fm.fileExists(atPath: current.appendingPathComponent(Constants.FileNames.claudeLocalMD).path) {
                return current
            }
            let mcsProjectPath = current
                .appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent(Constants.FileNames.mcsProject)
            if fm.fileExists(atPath: mcsProjectPath.path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Walk up from `startingPath` looking for a path that exists in `projectKeys`.
    /// Stops at (and includes) the first directory containing `.git/`.
    /// Returns the matching key string, or nil if no match is found.
    ///
    /// This resolves the mismatch between `findProjectRoot()` (which may return a
    /// subdirectory containing CLAUDE.local.md) and the Claude CLI's convention of
    /// keying project-scoped entries by the git root in `~/.claude.json`.
    static func resolveProjectKey(from startingPath: URL, in projectKeys: Set<String>) -> String? {
        let fm = FileManager.default
        var current = startingPath.standardizedFileURL
        while current.path != "/" {
            if projectKeys.contains(current.path) {
                return current.path
            }
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) {
                break
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Convenience: find project root from the current working directory.
    static func findProjectRoot() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return findProjectRoot(from: cwd)
    }
}
