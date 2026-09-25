import Foundation
@testable import mcs
import Testing

struct GitignoreManagerTests {
    // MARK: - removeEntry

    private func makeManager(label: String, gitignore: String?) throws -> (GitignoreManager, URL, URL) {
        let home = try makeGlobalTmpDir(label: label)
        let manager = GitignoreManager(shell: ShellRunner(environment: Environment(home: home)))
        let path = manager.resolveGlobalGitignorePath()
        if let gitignore {
            try gitignore.write(to: path, atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.removeItem(at: path)
        }
        return (manager, path, home)
    }

    @Test("Remove existing entry from gitignore")
    func removeExistingEntry() throws {
        let (manager, path, home) = try makeManager(
            label: "gitignore-remove", gitignore: ".claude\n*.local.*\n.mcs-project\n"
        )
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try manager.removeEntry("*.local.*"))
        #expect(try String(contentsOf: path, encoding: .utf8) == ".claude\n.mcs-project\n")
    }

    @Test("Remove entry that does not exist returns false and leaves the file untouched")
    func removeNonexistentEntry() throws {
        let (manager, path, home) = try makeManager(label: "gitignore-remove-absent", gitignore: ".claude\n")
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try manager.removeEntry("nonexistent") == false)
        #expect(try String(contentsOf: path, encoding: .utf8) == ".claude\n")
    }

    @Test("Remove entry from nonexistent file returns false without creating it")
    func removeFromMissingFile() throws {
        let (manager, path, home) = try makeManager(label: "gitignore-remove-missing", gitignore: nil)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try manager.removeEntry(".claude") == false)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - Sandbox containment

    /// `GitignoreManager` both reads and writes the global gitignore, so resolving the process's
    /// own home instead of the injected `Environment`'s let any sandboxed caller — including the
    /// whole test suite — mutate the real user's `~/.config/git/ignore`. It also made
    /// `GitignoreCheck` report whatever the developer's machine happened to have, which is how a
    /// doctor test passed locally and on one CI runner while failing on another.
    @Test("Global gitignore path stays inside the injected environment's home")
    func resolvedPathIsContainedInEnvironmentHome() throws {
        let home = try makeGlobalTmpDir(label: "gitignore-containment")
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = GitignoreManager(shell: ShellRunner(environment: Environment(home: home)))
        let resolved = manager.resolveGlobalGitignorePath().resolvingSymlinksInPath().path
        let sandbox = home.resolvingSymlinksInPath().path

        #expect(resolved.hasPrefix(sandbox))
        #expect(!resolved.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }
}
