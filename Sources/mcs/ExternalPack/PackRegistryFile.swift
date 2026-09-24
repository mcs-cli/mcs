import Foundation

/// Manages the `~/.mcs/registry.yaml` file that tracks installed external packs.
struct PackRegistryFile {
    let path: URL // ~/.mcs/registry.yaml

    struct PackEntry: Codable, Equatable {
        // `var` only to enable copy-and-mutate via `withCommitSHA`; treat as immutable elsewhere.
        var identifier: String
        var displayName: String
        var author: String?
        var sourceURL: String // Git clone URL or original local path
        var ref: String? // Git tag/branch/commit
        var commitSHA: String // Exact commit (git) or "local" (local packs)
        var localPath: String // Relative to ~/.mcs/packs/ (git) or absolute path (local)
        var addedAt: String // ISO 8601 date
        var trustedScriptHashes: [String: String] // relativePath -> SHA-256
        var isLocal: Bool? // nil/false = git pack, true = local filesystem pack

        /// Whether this pack is a local filesystem pack (not cloned via git).
        var isLocalPack: Bool {
            isLocal ?? false
        }

        /// 7-character short prefix of the commit SHA for display.
        var shortSHA: String {
            String(commitSHA.prefix(7))
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

        /// A git checkout deleted out of band while its registry entry remains. Local packs and
        /// unresolvable paths are never "missing": re-cloning cannot repair either.
        func isCheckoutMissing(packsDirectory: URL) -> Bool {
            guard !isLocalPack, let packPath = resolvedPath(packsDirectory: packsDirectory) else { return false }
            return Self.isCheckoutMissing(at: packPath)
        }

        static func isCheckoutMissing(at packPath: URL) -> Bool {
            let manifest = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
            return !FileManager.default.fileExists(atPath: manifest.path)
        }

        /// Return a copy with `commitSHA` replaced. The registry SHA and working-tree
        /// HEAD are normally kept in lockstep (set together by clone/checkout). Updating
        /// only the SHA reflects "we acknowledged this upstream commit but did not move
        /// the checkout" — used when a non-material upstream commit is recognized but
        /// not pulled.
        func withCommitSHA(_ sha: String) -> Self {
            var copy = self
            copy.commitSHA = sha
            return copy
        }
    }

    struct RegistryData: Codable {
        var packs: [PackEntry]

        init(packs: [PackEntry] = []) {
            self.packs = packs
        }
    }

    // MARK: - Load / Save

    /// Load the registry from disk. Returns empty registry if the file doesn't exist.
    func load() throws -> RegistryData {
        try YAMLFile.load(RegistryData.self, from: path) ?? RegistryData()
    }

    /// Write the registry to disk, creating parent directories if needed.
    func save(_ data: RegistryData) throws {
        try YAMLFile.save(data, to: path)
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
    struct CollisionInput {
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
struct PackCollision: Equatable {
    let type: CollisionType
    let artifactName: String
    let existingPackIdentifier: String
    let newPackIdentifier: String

    enum CollisionType: Equatable {
        case mcpServerName
        case skillDirectory
        case templateSection
        case componentId
    }
}
