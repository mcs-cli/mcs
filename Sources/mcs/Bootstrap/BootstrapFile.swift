import Foundation

/// Declarative bootstrap manifest at a fixed location (`./mcs.yaml` at cwd). Each declared pack
/// is routed to project or global scope; the project is always the folder holding the file.
struct BootstrapFile: Codable, Equatable {
    /// Bumped when the on-disk schema gains a breaking change.
    static let currentSchemaVersion = 1

    static let defaultFilename = "mcs.yaml"

    var schemaVersion: Int
    var packs: [PackRef]
    /// Default scope for entries without their own. `global` makes the file machine-only:
    /// cwd is not treated as a project.
    var scope: String?

    struct PackRef: Codable, Equatable {
        /// Git URL, GitHub shorthand (`user/repo`), or an absolute/relative local path.
        var source: String
        /// Git tag / branch / commit. Ignored for local packs.
        var ref: String?
        /// Prompt priors keyed by prompt `key`. Seeded into `ProjectState.resolvedValues`
        /// so the sync engine reuses them silently without re-prompting.
        var values: [String: String]?
        /// `project` or `global`; overrides the file-level `scope`.
        var scope: String?

        var packScope: PackScope? {
            scope.flatMap(PackScope.init(rawValue:))
        }
    }

    var fileScope: PackScope? {
        scope.flatMap(PackScope.init(rawValue:))
    }
}

// MARK: - Errors

enum BootstrapFileError: Error, LocalizedError, Equatable {
    case notFound(path: String)
    case parseFailed(underlying: String)
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case emptyPackList
    case duplicateSource(String)
    case invalidScope(source: String?, scope: String)
    case projectEntryInGlobalFile(source: String)
    case blankSource

    var errorDescription: String? {
        switch self {
        case let .notFound(path):
            "No \(BootstrapFile.defaultFilename) found at \(path)"
        case let .parseFailed(reason):
            "Failed to parse \(BootstrapFile.defaultFilename): \(reason)"
        case let .unsupportedSchemaVersion(found, expected):
            "Unsupported schemaVersion \(found); this version of mcs expects \(expected)"
        case .emptyPackList:
            "\(BootstrapFile.defaultFilename) declares no packs"
        case let .duplicateSource(source):
            "\(BootstrapFile.defaultFilename) lists source '\(source)' more than once"
        case let .invalidScope(source, scope):
            "\(source.map { "'\($0)': " } ?? "")unknown scope '\(scope)' — expected 'project' or 'global'"
        case let .projectEntryInGlobalFile(source):
            "'\(source)': scope 'project' is not allowed in a file whose scope is 'global'"
        case .blankSource:
            "\(BootstrapFile.defaultFilename) contains a pack entry with an empty source"
        }
    }
}

// MARK: - Loading

extension BootstrapFile {
    /// Load and validate the bootstrap file at `path`. `path` is resolved
    /// against `<cwd>/mcs.yaml` by the caller; we only ever read the exact
    /// file we're given so there is a single source of truth.
    static func load(from path: URL) throws -> BootstrapFile {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BootstrapFileError.notFound(path: path.path)
        }

        let decoded: BootstrapFile?
        do {
            decoded = try YAMLFile.load(BootstrapFile.self, from: path)
        } catch {
            throw BootstrapFileError.parseFailed(underlying: error.localizedDescription)
        }
        guard var file = decoded else {
            throw BootstrapFileError.parseFailed(underlying: "file is empty")
        }

        // Normalize before validation so blank/duplicate checks and later resolution
        // agree on one canonical form. Without this a quoted source like `" user/repo "`
        // passes validation on the trimmed value but is later handed untrimmed to
        // PackSourceResolver.
        for i in file.packs.indices {
            file.packs[i].source = file.packs[i].source
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        try file.validate()
        return file
    }

    /// Structural checks that YAML decoding cannot express.
    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BootstrapFileError.unsupportedSchemaVersion(
                found: schemaVersion,
                expected: Self.currentSchemaVersion
            )
        }

        guard !packs.isEmpty else {
            throw BootstrapFileError.emptyPackList
        }

        if let scope, fileScope == nil {
            throw BootstrapFileError.invalidScope(source: nil, scope: scope)
        }

        var seen: Set<String> = []
        for pack in packs {
            guard !pack.source.isEmpty else {
                throw BootstrapFileError.blankSource
            }
            if !seen.insert(pack.source).inserted {
                throw BootstrapFileError.duplicateSource(pack.source)
            }
            if let scope = pack.scope, pack.packScope == nil {
                throw BootstrapFileError.invalidScope(source: pack.source, scope: scope)
            }
            if fileScope == .global, pack.packScope == .project {
                throw BootstrapFileError.projectEntryInGlobalFile(source: pack.source)
            }
        }
    }
}
