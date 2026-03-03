import Foundation
@testable import mcs
import Testing

@Suite("ProjectIndex")
struct ProjectIndexTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-index-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Load / Save

    @Test("Load returns empty data for missing file")
    func loadMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let index = ProjectIndex(path: tmpDir.appendingPathComponent("projects.yaml"))
        let data = try index.load()
        #expect(data.indexVersion == 1)
        #expect(data.projects.isEmpty)
    }

    @Test("Save and load round-trip preserves data")
    func roundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let index = ProjectIndex(path: tmpDir.appendingPathComponent("projects.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/to/project", packIDs: ["ios", "swift"], in: &data)
        index.upsert(projectPath: ProjectIndex.globalSentinel, packIDs: ["bruno-setup"], in: &data)
        try index.save(data)

        let loaded = try index.load()
        #expect(loaded.projects.count == 2)
        #expect(loaded.projects[0].packs == ["ios", "swift"])
        #expect(loaded.projects[1].path == ProjectIndex.globalSentinel)
    }

    // MARK: - Upsert

    @Test("Upsert adds new entry")
    func upsertNew() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["pack-1"], in: &data)
        #expect(data.projects.count == 1)
        #expect(data.projects[0].path == "/path/a")
        #expect(data.projects[0].packs == ["pack-1"])
    }

    @Test("Upsert updates existing entry")
    func upsertExisting() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["pack-1"], in: &data)
        index.upsert(projectPath: "/path/a", packIDs: ["pack-1", "pack-2"], in: &data)
        #expect(data.projects.count == 1)
        #expect(data.projects[0].packs == ["pack-1", "pack-2"])
    }

    @Test("Upsert sorts pack IDs")
    func upsertSortsPacks() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["zebra", "alpha"], in: &data)
        #expect(data.projects[0].packs == ["alpha", "zebra"])
    }

    // MARK: - Remove

    @Test("Remove deletes entry by path")
    func removeEntry() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["pack-1"], in: &data)
        index.upsert(projectPath: "/path/b", packIDs: ["pack-2"], in: &data)
        index.remove(projectPath: "/path/a", from: &data)
        #expect(data.projects.count == 1)
        #expect(data.projects[0].path == "/path/b")
    }

    @Test("Remove is no-op for missing path")
    func removeNonExistent() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["pack-1"], in: &data)
        index.remove(projectPath: "/path/nonexistent", from: &data)
        #expect(data.projects.count == 1)
    }

    // MARK: - RemovePack

    @Test("RemovePack removes pack from all entries and prunes empty entries")
    func removePackFromAll() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["ios", "swift"], in: &data)
        index.upsert(projectPath: "/path/b", packIDs: ["ios"], in: &data)
        index.removePack("ios", from: &data)
        #expect(data.projects.count == 1)
        #expect(data.projects[0].path == "/path/a")
        #expect(data.projects[0].packs == ["swift"])
    }

    // MARK: - Queries

    @Test("Projects with pack returns matching entries")
    func projectsWithPack() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/path/a", packIDs: ["ios", "swift"], in: &data)
        index.upsert(projectPath: "/path/b", packIDs: ["swift"], in: &data)
        index.upsert(projectPath: "/path/c", packIDs: ["android"], in: &data)

        let iosProjects = index.projects(withPack: "ios", in: data)
        #expect(iosProjects.count == 1)
        #expect(iosProjects[0].path == "/path/a")

        let swiftProjects = index.projects(withPack: "swift", in: data)
        #expect(swiftProjects.count == 2)
    }

    // MARK: - Stale Pruning

    @Test("PruneStale removes entries for non-existent directories")
    func pruneStale() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: tmpDir.path, packIDs: ["pack-1"], in: &data)
        index.upsert(projectPath: "/nonexistent/path", packIDs: ["pack-2"], in: &data)
        index.upsert(projectPath: ProjectIndex.globalSentinel, packIDs: ["pack-3"], in: &data)

        let pruned = index.pruneStale(in: &data)
        #expect(pruned == ["/nonexistent/path"])
        #expect(data.projects.count == 2) // tmpDir + __global__
    }

    @Test("PruneStale never removes global sentinel")
    func pruneStaleKeepsGlobal() {
        let index = ProjectIndex(path: URL(fileURLWithPath: "/tmp/test.yaml"))
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: ProjectIndex.globalSentinel, packIDs: ["pack-1"], in: &data)

        let pruned = index.pruneStale(in: &data)
        #expect(pruned.isEmpty)
        #expect(data.projects.count == 1)
    }
}
