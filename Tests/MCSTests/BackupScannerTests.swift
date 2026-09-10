import Foundation
@testable import mcs
import Testing

struct BackupScannerTests {
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-scanner-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardizedFileURL
    }

    private func writeFile(_ url: URL, _ contents: String = "x") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeProject(in sandbox: URL, named name: String) throws -> URL {
        let root = sandbox.appendingPathComponent(name)
        try writeFile(root.appendingPathComponent("CLAUDE.local.md.backup.20260101_101010_1"))
        try writeFile(root.appendingPathComponent(".claude/settings.local.json.backup.20260101_101010_2"))
        return root
    }

    private func indexProjects(_ paths: [URL], home: URL) throws {
        let index = ProjectIndex(path: Environment(home: home).projectsIndexFile)
        var data = ProjectIndex.IndexData()
        for path in paths {
            index.upsert(projectPath: path.path, packIDs: ["ios"], in: &data)
        }
        index.upsert(projectPath: ProjectIndex.globalSentinel, packIDs: ["ios"], in: &data)
        try index.save(data)
    }

    private func names(_ groups: [BackupScanner.Group]) -> Set<String> {
        Set(groups.flatMap(\.backups).map(\.lastPathComponent))
    }

    @Test("scan finds global and current-directory backups without the fan-out flag")
    func scanLocalScopes() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        try writeFile(home.appendingPathComponent(".claude/CLAUDE.md.backup.20260101_101010_1"))
        let cwd = try makeProject(in: sandbox, named: "cwd-project")
        let tracked = try makeProject(in: sandbox, named: "tracked")
        try indexProjects([tracked], home: home)

        let scanner = BackupScanner(environment: Environment(home: home), currentDirectory: cwd)
        let groups = scanner.scan(includeTrackedProjects: false, output: CLIOutput(colorsEnabled: false))

        #expect(groups.count == 2)
        #expect(names(groups) == [
            "CLAUDE.md.backup.20260101_101010_1",
            "CLAUDE.local.md.backup.20260101_101010_1",
            "settings.local.json.backup.20260101_101010_2",
        ])
    }

    @Test("scan with tracked projects adds every indexed project")
    func scanTrackedProjects() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        let cwd = sandbox.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let alpha = try makeProject(in: sandbox, named: "alpha")
        let beta = try makeProject(in: sandbox, named: "beta")
        try indexProjects([alpha, beta], home: home)

        let scanner = BackupScanner(environment: Environment(home: home), currentDirectory: cwd)
        let groups = scanner.scan(includeTrackedProjects: true, output: CLIOutput(colorsEnabled: false))

        #expect(groups.count == 2)
        #expect(groups.map(\.root.path) == [alpha.path, beta.path])
        #expect(groups.flatMap(\.backups).count == 4)
    }

    @Test("tracked-project scan skips deep files but keeps the project root and .claude")
    func scanTrackedProjectsIsShallowAtRoot() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let project = try makeProject(in: sandbox, named: "alpha")
        try writeFile(project.appendingPathComponent("node_modules/dep/db.backup.2024"))
        try writeFile(project.appendingPathComponent(".claude/skills/deep/s.md.backup.20260101_101010_3"))
        try indexProjects([project], home: home)

        let scanner = BackupScanner(
            environment: Environment(home: home), currentDirectory: home
        )
        let groups = scanner.scan(includeTrackedProjects: true, output: CLIOutput(colorsEnabled: false))

        #expect(names(groups) == [
            "CLAUDE.local.md.backup.20260101_101010_1",
            "settings.local.json.backup.20260101_101010_2",
            "s.md.backup.20260101_101010_3",
        ])
    }

    @Test("a project reachable from two scopes is reported once")
    func scanDeduplicatesAcrossScopes() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let project = try makeProject(in: sandbox, named: "alpha")
        try indexProjects([project], home: home)

        let scanner = BackupScanner(environment: Environment(home: home), currentDirectory: project)
        let groups = scanner.scan(includeTrackedProjects: true, output: CLIOutput(colorsEnabled: false))

        #expect(groups.count == 1)
        #expect(groups[0].root.path == project.path)
        #expect(groups[0].backups.count == 2)
    }

    @Test("index entries for deleted projects are ignored")
    func scanSkipsStaleIndexEntries() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let gone = sandbox.appendingPathComponent("deleted-project")
        try indexProjects([gone], home: home)

        let scanner = BackupScanner(environment: Environment(home: home), currentDirectory: home)
        let groups = scanner.scan(includeTrackedProjects: true, output: CLIOutput(colorsEnabled: false))

        #expect(groups.isEmpty)
    }

    @Test("a directory matching the backup pattern is not offered for deletion")
    func scanIgnoresDirectories() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let home = sandbox.appendingPathComponent("home")
        let cwd = sandbox.appendingPathComponent("project")
        try writeFile(cwd.appendingPathComponent("skills.backup.20260101_101010_1/keep.md"))

        let scanner = BackupScanner(environment: Environment(home: home), currentDirectory: cwd)
        let groups = scanner.scan(includeTrackedProjects: false, output: CLIOutput(colorsEnabled: false))

        #expect(groups.isEmpty)
    }
}
