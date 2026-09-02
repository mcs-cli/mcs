import Foundation

/// Lightweight index tracking which projects use which packs (`~/.mcs/projects.yaml`).
/// Used for reference counting global resources (brew packages, plugins) before removal.
struct ProjectIndex {
    let path: URL

    /// Sentinel path representing the global scope (`mcs sync --global`).
    static let globalSentinel = "__global__"

    /// Sentinel scope used during `mcs pack remove` (excludes all scopes).
    static let packRemoveSentinel = "__pack_remove__"

    struct ProjectEntry: Codable, Equatable {
        /// Absolute project path or `__global__` for the global scope.
        let path: String
        /// Pack identifiers configured in this scope.
        var packs: [String]
        /// ISO 8601 timestamp of the last sync.
        var lastSynced: String

        /// Whether this entry represents the global scope rather than a project.
        var isGlobal: Bool {
            path == ProjectIndex.globalSentinel
        }

        /// File URL for project entries. Returns `nil` for the global sentinel.
        var url: URL? {
            isGlobal ? nil : URL(fileURLWithPath: path)
        }
    }

    struct IndexData: Codable {
        var indexVersion: Int = 1
        var projects: [ProjectEntry] = []
    }

    // MARK: - Load / Save

    /// Load from disk. Returns empty index if the file doesn't exist.
    func load() throws -> IndexData {
        try YAMLFile.load(IndexData.self, from: path) ?? IndexData()
    }

    /// Write to disk, creating parent directories if needed.
    func save(_ data: IndexData) throws {
        try YAMLFile.save(data, to: path)
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

    /// Remove a specific pack from one project entry, pruning the entry if nothing remains.
    ///
    /// Deliberately not expressed as `upsert` with the surviving packs: `upsert` stamps
    /// `lastSynced` with the current time, which would claim a sync that never happened.
    func removePack(_ packID: String, fromProject path: String, in data: inout IndexData) {
        guard let index = data.projects.firstIndex(where: { $0.path == path }) else { return }
        data.projects[index].packs.removeAll { $0 == packID }
        if data.projects[index].packs.isEmpty {
            data.projects.remove(at: index)
        }
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
