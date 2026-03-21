import Foundation

/// Tracks per-pack artifacts installed into a project, enabling clean removal
/// when a pack is deselected during `mcs sync`.
struct PackArtifactRecord: Codable, Equatable {
    /// MCP servers registered for this pack (name + scope for `claude mcp remove`).
    var mcpServers: [MCPServerRef] = []
    /// Project-relative paths of files installed by this pack.
    var files: [String] = []
    /// Section identifiers contributed to CLAUDE.local.md.
    var templateSections: [String] = []
    /// Hook commands registered in settings.local.json.
    var hookCommands: [String] = []
    /// Settings keys contributed by this pack.
    var settingsKeys: [String] = []
    /// Homebrew packages installed by MCS for this pack (ownership tracking).
    var brewPackages: [String] = []
    /// Plugins installed by MCS for this pack (ownership tracking).
    var plugins: [String] = []
    /// Global gitignore entries added by this pack.
    var gitignoreEntries: [String] = []
    /// SHA-256 hashes of installed files (project-relative path → hash) for content drift detection.
    var fileHashes: [String: String] = [:]
    /// SHA-256 hash of the pack's contributed settings key-value pairs, for drift detection.
    /// Nil for state files written by older MCS versions (backward compat).
    var settingsHash: String?

    /// Whether all artifact lists are empty (cleanup is complete).
    /// Note: `settingsHash` is intentionally excluded — it is derived metadata
    /// tied to `settingsKeys` and has no independent cleanup semantics.
    var isEmpty: Bool {
        mcpServers.isEmpty && files.isEmpty && templateSections.isEmpty
            && hookCommands.isEmpty && settingsKeys.isEmpty
            && brewPackages.isEmpty && plugins.isEmpty
            && gitignoreEntries.isEmpty && fileHashes.isEmpty
    }

    /// Custom decoder for backward compatibility — existing JSON files may lack
    /// newer keys (brewPackages, plugins, gitignoreEntries, fileHashes).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mcpServers = try container.decodeIfPresent([MCPServerRef].self, forKey: .mcpServers) ?? []
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        templateSections = try container.decodeIfPresent([String].self, forKey: .templateSections) ?? []
        hookCommands = try container.decodeIfPresent([String].self, forKey: .hookCommands) ?? []
        settingsKeys = try container.decodeIfPresent([String].self, forKey: .settingsKeys) ?? []
        brewPackages = try container.decodeIfPresent([String].self, forKey: .brewPackages) ?? []
        plugins = try container.decodeIfPresent([String].self, forKey: .plugins) ?? []
        gitignoreEntries = try container.decodeIfPresent([String].self, forKey: .gitignoreEntries) ?? []
        fileHashes = try container.decodeIfPresent([String: String].self, forKey: .fileHashes) ?? [:]
        settingsHash = try container.decodeIfPresent(String.self, forKey: .settingsHash)
    }

    init(
        mcpServers: [MCPServerRef] = [],
        files: [String] = [],
        templateSections: [String] = [],
        hookCommands: [String] = [],
        settingsKeys: [String] = [],
        brewPackages: [String] = [],
        plugins: [String] = [],
        gitignoreEntries: [String] = [],
        fileHashes: [String: String] = [:],
        settingsHash: String? = nil
    ) {
        self.mcpServers = mcpServers
        self.files = files
        self.templateSections = templateSections
        self.hookCommands = hookCommands
        self.settingsKeys = settingsKeys
        self.brewPackages = brewPackages
        self.plugins = plugins
        self.gitignoreEntries = gitignoreEntries
        self.fileHashes = fileHashes
        self.settingsHash = settingsHash
    }

    /// Record a brew package as MCS-owned, deduplicating automatically.
    mutating func recordBrewPackage(_ package: String) {
        if !brewPackages.contains(package) {
            brewPackages.append(package)
        }
    }

    /// Record a plugin as MCS-owned, deduplicating automatically.
    mutating func recordPlugin(_ name: String) {
        if !plugins.contains(name) {
            plugins.append(name)
        }
    }
}

/// Reference to a registered MCP server for later removal.
struct MCPServerRef: Codable, Hashable {
    var name: String
    var scope: String
}

/// Per-project state stored at `<project>/.claude/.mcs-project`.
/// Tracks which tech packs have been configured for this specific project,
/// along with per-pack artifact records for convergence.
struct ProjectState {
    private let path: URL
    private var storage: StateStorage

    /// JSON-backed storage model.
    private struct StateStorage: Codable {
        var mcsVersion: String?
        var configuredAt: String?
        var configuredPacks: [String] = []
        var packArtifacts: [String: PackArtifactRecord] = [:]
        /// Component IDs excluded per pack (packID -> [componentID]).
        /// Exclusion-based: new components added by pack updates are included by default.
        var excludedComponents: [String: [String]] = [:]
        /// Template placeholder values resolved during the last sync.
        /// Used by doctor to re-render expected sections for content-hash comparison.
        var resolvedValues: [String: String]?
    }

    init(projectRoot: URL) throws {
        path = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        storage = StateStorage()
        try load()
    }

    /// Initialize with a specific state file path (used for global state at `~/.mcs/global-state.json`).
    init(stateFile: URL) throws {
        path = stateFile
        storage = StateStorage()
        try load()
    }

    /// Whether the state file exists on disk.
    var exists: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// The set of pack identifiers configured for this project.
    var configuredPacks: Set<String> {
        Set(storage.configuredPacks)
    }

    /// Record that a pack was configured for this project.
    mutating func recordPack(_ identifier: String) {
        if !storage.configuredPacks.contains(identifier) {
            storage.configuredPacks.append(identifier)
            storage.configuredPacks.sort()
        }
    }

    /// Remove a pack from the configured list.
    mutating func removePack(_ identifier: String) {
        storage.configuredPacks.removeAll { $0 == identifier }
        storage.packArtifacts.removeValue(forKey: identifier)
        storage.excludedComponents.removeValue(forKey: identifier)
    }

    /// The MCS version that last wrote this file.
    var mcsVersion: String? {
        storage.mcsVersion
    }

    // MARK: - Pack Artifacts

    /// Get the artifact record for a pack, if any.
    func artifacts(for packID: String) -> PackArtifactRecord? {
        storage.packArtifacts[packID]
    }

    /// Set the artifact record for a pack.
    mutating func setArtifacts(_ record: PackArtifactRecord, for packID: String) {
        storage.packArtifacts[packID] = record
    }

    // MARK: - Component Exclusions

    /// Get excluded component IDs for a pack.
    func excludedComponents(for packID: String) -> Set<String> {
        Set(storage.excludedComponents[packID] ?? [])
    }

    /// Set excluded component IDs for a pack. Pass empty set to clear exclusions.
    mutating func setExcludedComponents(_ componentIDs: Set<String>, for packID: String) {
        if componentIDs.isEmpty {
            storage.excludedComponents.removeValue(forKey: packID)
        } else {
            storage.excludedComponents[packID] = componentIDs.sorted()
        }
    }

    /// All excluded components across all packs: packID -> Set<componentID>.
    var allExcludedComponents: [String: Set<String>] {
        storage.excludedComponents.mapValues { Set($0) }
    }

    // MARK: - Resolved Values

    /// Template placeholder values from the last sync, or nil if not yet synced.
    var resolvedValues: [String: String]? {
        storage.resolvedValues
    }

    /// Store resolved template values for later doctor freshness checks.
    mutating func setResolvedValues(_ values: [String: String]) {
        storage.resolvedValues = values
    }

    // MARK: - Persistence

    /// Save to disk. Updates internal state with timestamp and version.
    mutating func save() throws {
        let fm = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        storage.configuredAt = ISO8601DateFormatter().string(from: Date())
        storage.mcsVersion = MCSVersion.current

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storage)
        try data.write(to: path)
    }

    // MARK: - Private

    private mutating func load() throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let data = try Data(contentsOf: path)
        storage = try JSONDecoder().decode(StateStorage.self, from: data)
    }
}
