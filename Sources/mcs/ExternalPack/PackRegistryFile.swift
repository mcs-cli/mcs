import Foundation
import Yams

/// Manages the `~/.mcs/registry.yaml` file that tracks installed external packs.
struct PackRegistryFile: Sendable {
    let path: URL // ~/.mcs/registry.yaml

    struct PackEntry: Codable, Sendable, Equatable {
        let identifier: String
        let displayName: String
        let author: String?
        let sourceURL: String // Git clone URL or original local path
        let ref: String? // Git tag/branch/commit
        let commitSHA: String // Exact commit (git) or "local" (local packs)
        let localPath: String // Relative to ~/.mcs/packs/ (git) or absolute path (local)
        let addedAt: String // ISO 8601 date
        let trustedScriptHashes: [String: String] // relativePath -> SHA-256
        let isLocal: Bool? // nil/false = git pack, true = local filesystem pack

        /// Whether this pack is a local filesystem pack (not cloned via git).
        var isLocalPack: Bool {
            isLocal ?? false
        }

        /// Resolve the on-disk path for this pack entry.
        /// Local packs store an absolute path; git packs store a path relative to `packsDirectory`.
        /// Returns `nil` if the local path is invalid or the git path escapes the packs directory.
        func resolvedPath(packsDirectory: URL) -> URL? {
            if isLocalPack {
                guard !localPath.isEmpty, localPath.hasPrefix("/") else { return nil }
                return URL(fileURLWithPath: localPath)
            }
            return PathContainment.safePath(relativePath: localPath, within: packsDirectory)
        }
    }

    struct RegistryData: Codable, Sendable {
        var packs: [PackEntry]

        init(packs: [PackEntry] = []) {
            self.packs = packs
        }
    }

    // MARK: - Load / Save

    /// Load the registry from disk. Returns empty registry if the file doesn't exist.
    func load() throws -> RegistryData {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return RegistryData()
        }
        let content = try String(contentsOf: path, encoding: .utf8)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RegistryData()
        }
        return try YAMLDecoder().decode(RegistryData.self, from: content)
    }

    /// Write the registry to disk, creating parent directories if needed.
    func save(_ data: RegistryData) throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let yaml = try YAMLEncoder().encode(data)
        try yaml.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Queries

    /// Look up a pack by identifier.
    func pack(identifier: String, in data: RegistryData) -> PackEntry? {
        data.packs.first { $0.identifier == identifier }
    }

    // MARK: - Mutations

    /// Add or update a pack entry. If a pack with the same identifier exists, it is replaced.
    func register(_ entry: PackEntry, in data: inout RegistryData) {
        if let index = data.packs.firstIndex(where: { $0.identifier == entry.identifier }) {
            data.packs[index] = entry
        } else {
            data.packs.append(entry)
        }
    }

    /// Remove a pack entry by identifier. No-op if the identifier is not found.
    func remove(identifier: String, from data: inout RegistryData) {
        data.packs.removeAll { $0.identifier == identifier }
    }

    // MARK: - Collision Detection

    /// Input describing a new pack's artifacts for collision checking.
    struct CollisionInput: Sendable {
        let identifier: String
        let mcpServerNames: [String]
        let skillDirectories: [String]
        let templateSectionIDs: [String]
        let componentIDs: [String]

        /// An empty input with no artifacts — used when a manifest cannot be loaded.
        static func empty(identifier: String) -> CollisionInput {
            CollisionInput(
                identifier: identifier,
                mcpServerNames: [],
                skillDirectories: [],
                templateSectionIDs: [],
                componentIDs: []
            )
        }
    }

    /// Check if any registered pack has a collision with a new pack's artifacts.
    ///
    /// Compares MCP server names, skill directories, template section IDs,
    /// and component IDs between the new pack and all existing packs.
    func detectCollisions(
        newPack: CollisionInput,
        existingPacks: [CollisionInput]
    ) -> [PackCollision] {
        var collisions: [PackCollision] = []

        for existing in existingPacks {
            guard existing.identifier != newPack.identifier else { continue }

            for name in newPack.mcpServerNames where existing.mcpServerNames.contains(name) {
                collisions.append(PackCollision(
                    type: .mcpServerName,
                    artifactName: name,
                    existingPackIdentifier: existing.identifier,
                    newPackIdentifier: newPack.identifier
                ))
            }

            for dir in newPack.skillDirectories where existing.skillDirectories.contains(dir) {
                collisions.append(PackCollision(
                    type: .skillDirectory,
                    artifactName: dir,
                    existingPackIdentifier: existing.identifier,
                    newPackIdentifier: newPack.identifier
                ))
            }

            for section in newPack.templateSectionIDs where existing.templateSectionIDs.contains(section) {
                collisions.append(PackCollision(
                    type: .templateSection,
                    artifactName: section,
                    existingPackIdentifier: existing.identifier,
                    newPackIdentifier: newPack.identifier
                ))
            }

            for id in newPack.componentIDs where existing.componentIDs.contains(id) {
                collisions.append(PackCollision(
                    type: .componentId,
                    artifactName: id,
                    existingPackIdentifier: existing.identifier,
                    newPackIdentifier: newPack.identifier
                ))
            }
        }

        return collisions
    }
}

// MARK: - CollisionInput from Manifest

extension PackRegistryFile.CollisionInput {
    /// Extract collision-checkable artifacts from an external pack manifest.
    init(from manifest: ExternalPackManifest) {
        var mcpNames: [String] = []
        var skillDirs: [String] = []
        var componentIDs: [String] = []

        if let components = manifest.components {
            for component in components {
                componentIDs.append(component.id)
                switch component.installAction {
                case let .mcpServer(config):
                    mcpNames.append(config.name)
                case let .copyPackFile(config) where config.fileType == .skill:
                    skillDirs.append(config.destination)
                default:
                    break
                }
            }
        }

        let templateSections = manifest.templates?.map(\.sectionIdentifier) ?? []

        self.init(
            identifier: manifest.identifier,
            mcpServerNames: mcpNames,
            skillDirectories: skillDirs,
            templateSectionIDs: templateSections,
            componentIDs: componentIDs
        )
    }
}

/// A collision between two packs' artifacts.
struct PackCollision: Sendable, Equatable {
    let type: CollisionType
    let artifactName: String
    let existingPackIdentifier: String
    let newPackIdentifier: String

    enum CollisionType: Sendable, Equatable {
        case mcpServerName
        case skillDirectory
        case templateSection
        case componentId
    }
}
