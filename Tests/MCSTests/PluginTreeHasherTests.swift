import Foundation
@testable import mcs
import Testing

struct PluginTreeHasherTests {
    private func shell(_ repo: URL) -> ShellRunner {
        ShellRunner(environment: Environment(home: repo))
    }

    private func root(_ repo: URL) -> PackMarketplace.HostedPlugin {
        PackMarketplace.HostedPlugin(name: "demo", source: repo, relativePath: ".")
    }

    private func git(_ repo: URL, _ arguments: [String]) throws {
        try runGit(arguments, in: repo)
    }

    /// A committed checkout: `hooks/` links to `scripts/` inside the plugin, plus a tracked hook.
    private func makeRepo() throws -> URL {
        let repo = try makeTmpDir(label: "plugin-tree")
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "echo v1".write(to: repo.appendingPathComponent("scripts/start.sh"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: repo.appendingPathComponent("hooks").path, withDestinationPath: "scripts")
        try git(repo, ["init", "-q"])
        try git(repo, ["add", "."])
        try git(repo, ["-c", "user.email=t@mcs.dev", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "init"])
        return repo
    }

    @Test("Untracked runtime files don't change the hash")
    func untrackedFilesIgnored() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let before = try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo))

        try FileManager.default.createDirectory(at: repo.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
        try "bytecode".write(to: repo.appendingPathComponent("__pycache__/x.pyc"), atomically: true, encoding: .utf8)
        try "finder".write(to: repo.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        #expect(try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo)) == before)
    }

    @Test("Editing a file reached through a symlinked directory changes the hash")
    func symlinkedDirectoryCovered() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let before = try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo))

        try "echo v2".write(to: repo.appendingPathComponent("hooks/start.sh"), atomically: true, encoding: .utf8)

        #expect(try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo)).hash != before.hash)
    }

    @Test("A tracked symlink leaving the plugin directory refuses the hash")
    func escapingSymlinkRejected() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let plugin = repo.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: plugin.appendingPathComponent("hooks").path, withDestinationPath: "../scripts")
        try git(repo, ["add", "."])

        #expect(throws: PluginTreeHasher.Error.symlinkEscapesPlugin(path: "plugin/hooks", target: "../scripts")) {
            try PluginTreeHasher.hash(
                PackMarketplace.HostedPlugin(name: "demo", source: plugin, relativePath: "plugin"), packPath: repo, shell: shell(repo)
            )
        }
    }

    @Test("A tracked file deleted from the checkout refuses the hash")
    func deletedTrackedFileRejected() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try FileManager.default.removeItem(at: repo.appendingPathComponent("scripts/start.sh"))

        #expect(throws: PluginTreeHasher.Error.trackedFileMissing("scripts/start.sh")) {
            try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo))
        }
    }

    @Test("A submodule is hashed by its pinned commit")
    func submoduleHashedByCommit() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, ["update-index", "--add", "--cacheinfo", "160000,\(String(repeating: "a", count: 40)),vendor"])
        let pinned = try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo))

        try git(repo, ["update-index", "--cacheinfo", "160000,\(String(repeating: "b", count: 40)),vendor"])

        #expect(try PluginTreeHasher.hash(root(repo), packPath: repo, shell: shell(repo)).hash != pinned.hash)
    }

    @Test("Listing tracked files forces git's untranslated messages, so a non-repo is recognised in any locale")
    func lsFilesRunsInCLocale() throws {
        let dir = try makeTmpDir(label: "plugin-tree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shell = MockShellRunner(environment: Environment(home: dir))

        _ = try PluginTreeHasher.hash(root(dir), packPath: dir, shell: shell)

        let lsFiles = try #require(shell.runCalls.first { $0.arguments.contains("ls-files") })
        #expect(lsFiles.additionalEnvironment["LC_ALL"] == "C")
    }
}
