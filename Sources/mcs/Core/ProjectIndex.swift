import Foundation
import Yams

/// Lightweight index tracking which projects use which packs (`~/.mcs/projects.yaml`).
/// Used for reference counting global resources (brew packages, plugins) before removal.
struct ProjectIndex: Sendable {
    let path: URL

    /// Sentinel path representing the global scope (`mcs sync --global`).
    static let globalSentinel = "__global__"

    /// Sentinel scope used during `mcs pack remove` (excludes all scopes).
    static let packRemoveSentinel = "__pack_remove__"

    struct ProjectEntry: Codable, Sendable, Equatable {
        /// Absolute project path or `__global__` for the global scope.
        let path: String
        /// Pack identifiers configured in this scope.
        var packs: [String]
        /// ISO 8601 timestamp of the last sync.
        var lastSynced: String
    }

    struct IndexData: Codable, Sendable {
        var indexVersion: Int = 1
        var projects: [ProjectEntry] = []
    }

    // MARK: - Load / Save

    /// Load from disk. Returns empty index if the file doesn't exist.
    func load() throws -> IndexData {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return IndexData()
        }
        let content = try String(contentsOf: path, encoding: .utf8)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return IndexData()
        }
        return try YAMLDecoder().decode(IndexData.self, from: content)
    }

    /// Write to disk, creating parent directories if needed.
    func save(_ data: IndexData) throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let yaml = try YAMLEncoder().encode(data)
        try yaml.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Mutations

    /// Register or update a project entry with its current pack list.
    func upsert(projectPath: String, packIDs: [String], in data: inout IndexData) {
        let entry = ProjectEntry(
            path: projectPath,
            packs: packIDs.sorted(),
            lastSynced: ISO8601DateFormatter().string(from: Date())
        )
        if let index = data.projects.firstIndex(where: { $0.path == projectPath }) {
            data.projects[index] = entry
        } else {
            data.projects.append(entry)
        }
    }

    /// Remove a project entry by path.
    func remove(projectPath: String, from data: inout IndexData) {
        data.projects.removeAll { $0.path == projectPath }
    }

    /// Remove a specific pack from all project entries. Prunes entries with no remaining packs.
    func removePack(_ packID: String, from data: inout IndexData) {
        for i in data.projects.indices {
            data.projects[i].packs.removeAll { $0 == packID }
        }
        data.projects.removeAll { $0.packs.isEmpty }
    }

    // MARK: - Queries

    /// All project entries that have a given pack configured.
    /// Does NOT filter stale entries — caller decides how to handle them.
    func projects(withPack packID: String, in data: IndexData) -> [ProjectEntry] {
        data.projects.filter { $0.packs.contains(packID) }
    }

    /// Remove entries for project directories that no longer exist on disk.
    /// The `__global__` sentinel is never pruned.
    /// Returns the pruned paths for reporting.
    @discardableResult
    func pruneStale(in data: inout IndexData) -> [String] {
        let fm = FileManager.default
        var pruned: [String] = []
        data.projects.removeAll { entry in
            guard entry.path != Self.globalSentinel else { return false }
            if !fm.fileExists(atPath: entry.path) {
                pruned.append(entry.path)
                return true
            }
            return false
        }
        return pruned
    }
}
