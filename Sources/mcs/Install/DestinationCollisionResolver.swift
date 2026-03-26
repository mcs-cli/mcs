import Foundation

// MARK: - Filesystem Context

/// Provides filesystem awareness to the collision resolver for detecting
/// pre-existing user files at `copyPackFile` destinations.
protocol CollisionFilesystemContext {
    /// Whether a file or directory exists at the resolved destination path.
    func fileExists(destination: String, fileType: CopyFileType) -> Bool
    /// Whether the destination is tracked by any pack in the current project state.
    func isTrackedByPack(destination: String, fileType: CopyFileType) -> Bool
}

/// Project-scoped filesystem context — resolves paths relative to `<project>/.claude/`.
struct ProjectCollisionContext: CollisionFilesystemContext {
    let projectPath: URL
    let trackedFiles: Set<String>

    func fileExists(destination: String, fileType: CopyFileType) -> Bool {
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)
        let destURL = baseDir.appendingPathComponent(destination)
        return FileManager.default.fileExists(atPath: destURL.path)
    }

    func isTrackedByPack(destination: String, fileType: CopyFileType) -> Bool {
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)
        let destURL = baseDir.appendingPathComponent(destination)
        let relPath = PathContainment.relativePath(of: destURL.path, within: projectPath.path)
        return trackedFiles.contains(relPath)
    }
}

/// Global-scoped filesystem context — resolves paths relative to `~/.claude/`.
struct GlobalCollisionContext: CollisionFilesystemContext {
    let environment: Environment
    let trackedFiles: Set<String>

    func fileExists(destination: String, fileType: CopyFileType) -> Bool {
        let destURL = fileType.destinationURL(in: environment, destination: destination)
        return FileManager.default.fileExists(atPath: destURL.path)
    }

    func isTrackedByPack(destination: String, fileType: CopyFileType) -> Bool {
        let destURL = fileType.destinationURL(in: environment, destination: destination)
        let relPath = PathContainment.relativePath(
            of: destURL.path, within: environment.claudeDirectory.path
        )
        return trackedFiles.contains(relPath)
    }
}

// MARK: - Collision Resolver

/// Detects `copyPackFile` destination collisions and applies conditional namespacing.
///
/// Three sources of collision are handled (when `filesystemContext` is provided):
/// 1. **Hooks always namespace** into `<pack-id>/` subdirectories, protecting user hooks.
/// 2. **Cross-pack collisions**: two+ packs targeting the same `(destination, fileType)`.
/// 3. **User-file conflicts**: a pack targets a path occupied by a file not tracked by mcs.
///
/// Without `filesystemContext`, only cross-pack collisions are resolved (backward compat).
enum DestinationCollisionResolver {
    /// Returns a new pack array with destinations namespaced where needed.
    static func resolveCollisions(
        packs: [any TechPack],
        output: CLIOutput,
        filesystemContext: (any CollisionFilesystemContext)? = nil
    ) -> [any TechPack] {
        var packComponentOverrides: [Int: [Int: String]] = [:]
        var collisionMap: [DestinationKey: [CollisionEntry]] = [:]

        // Phase 1: Build collision map and always-namespace hooks (single pass).
        for (packIndex, pack) in packs.enumerated() {
            for (componentIndex, component) in pack.components.enumerated() {
                guard case let .copyPackFile(_, destination, fileType) = component.installAction else {
                    continue
                }

                // Hooks always namespace into <pack-id>/ when filesystem context is available.
                if filesystemContext != nil, fileType == .hook {
                    packComponentOverrides[packIndex, default: [:]][componentIndex] =
                        namespacedDestination(destination: destination, packIdentifier: pack.identifier, fileType: fileType)
                }

                let key = DestinationKey(destination: destination, fileType: fileType)
                collisionMap[key, default: []].append(
                    CollisionEntry(packIndex: packIndex, componentIndex: componentIndex)
                )
            }
        }

        // Phase 1a: Apply cross-pack collision namespacing (2+ distinct packs).
        // Guards skip entries already resolved above.
        for (key, entries) in collisionMap {
            let distinctPackIndices = Set(entries.map(\.packIndex))
            guard distinctPackIndices.count >= 2 else { continue }

            if key.fileType == .skill {
                applySkillSuffix(
                    entries: entries, destination: key.destination,
                    packs: packs, overrides: &packComponentOverrides, output: output
                )
            } else {
                applySubdirectoryPrefix(
                    entries: entries, packs: packs, overrides: &packComponentOverrides
                )
            }
        }

        // Phase 1b: User-file conflict detection.
        // For non-hook entries not yet resolved, check if the destination is occupied
        // by a file not tracked by any pack.
        if let ctx = filesystemContext {
            for (packIndex, pack) in packs.enumerated() {
                for (componentIndex, component) in pack.components.enumerated() {
                    // Skip if already resolved by Phase 0 or 1a
                    if packComponentOverrides[packIndex]?[componentIndex] != nil { continue }

                    guard case let .copyPackFile(_, destination, fileType) = component.installAction else {
                        continue
                    }

                    if ctx.fileExists(destination: destination, fileType: fileType),
                       !ctx.isTrackedByPack(destination: destination, fileType: fileType) {
                        let namespaced = namespacedDestination(
                            destination: destination, packIdentifier: pack.identifier, fileType: fileType
                        )
                        packComponentOverrides[packIndex, default: [:]][componentIndex] = namespaced
                        output.warn(
                            "Pre-existing file at '\(fileType.subdirectory)\(destination)' is not managed by mcs"
                                + " \u{2014} pack '\(pack.identifier)' will install to "
                                + "'\(fileType.subdirectory)\(namespaced)' instead"
                        )
                    }
                }
            }
        }

        // Phase 2: Build result — wrap only packs that have overrides
        guard !packComponentOverrides.isEmpty else { return packs }

        return packs.enumerated().map { packIndex, pack in
            guard let overrides = packComponentOverrides[packIndex] else {
                return pack
            }
            let newComponents = pack.components.enumerated().map { compIndex, component in
                guard let newDestination = overrides[compIndex],
                      case let .copyPackFile(source, _, fileType) = component.installAction
                else {
                    return component
                }
                return ComponentDefinition(
                    id: component.id,
                    displayName: component.displayName,
                    description: component.description,
                    type: component.type,
                    packIdentifier: component.packIdentifier,
                    dependencies: component.dependencies,
                    isRequired: component.isRequired,
                    hookRegistration: component.hookRegistration,
                    installAction: .copyPackFile(source: source, destination: newDestination, fileType: fileType),
                    supplementaryChecks: component.supplementaryChecks
                )
            }
            return CollisionResolvedTechPack(wrapping: pack, components: newComponents)
        }
    }

    // MARK: - Private

    /// Computes the namespaced destination for a given file type.
    /// Skills get a `-<pack-id>` suffix; all other types get a `<pack-id>/` subdirectory prefix.
    private static func namespacedDestination(
        destination: String, packIdentifier: String, fileType: CopyFileType
    ) -> String {
        if fileType == .skill {
            "\(destination)-\(packIdentifier)"
        } else {
            "\(packIdentifier)/\(destination)"
        }
    }

    /// For non-skill types, prefix colliding entries with `<pack-id>/`.
    /// Skips entries already resolved by an earlier phase.
    private static func applySubdirectoryPrefix(
        entries: [CollisionEntry],
        packs: [any TechPack],
        overrides: inout [Int: [Int: String]]
    ) {
        for entry in entries {
            guard overrides[entry.packIndex]?[entry.componentIndex] == nil else { continue }
            let pack = packs[entry.packIndex]
            let component = pack.components[entry.componentIndex]
            guard case let .copyPackFile(_, destination, fileType) = component.installAction else { continue }
            overrides[entry.packIndex, default: [:]][entry.componentIndex] =
                namespacedDestination(destination: destination, packIdentifier: pack.identifier, fileType: fileType)
        }
    }

    /// For skills, the first pack keeps the clean name; subsequent packs get `-<pack-id>` suffix.
    /// Skips entries already resolved by an earlier phase.
    private static func applySkillSuffix(
        entries: [CollisionEntry],
        destination: String,
        packs: [any TechPack],
        overrides: inout [Int: [Int: String]],
        output: CLIOutput
    ) {
        let firstPackIndex = entries[0].packIndex
        let firstPackName = packs[firstPackIndex].identifier

        for entry in entries where entry.packIndex != firstPackIndex {
            guard overrides[entry.packIndex]?[entry.componentIndex] == nil else { continue }
            let pack = packs[entry.packIndex]
            let suffixed = namespacedDestination(
                destination: destination, packIdentifier: pack.identifier, fileType: .skill
            )
            overrides[entry.packIndex, default: [:]][entry.componentIndex] = suffixed
            output.warn(
                "Skill '\(destination)' from pack '\(pack.identifier)' renamed to " +
                    "'\(suffixed)' to avoid collision with pack '\(firstPackName)'"
            )
        }
    }
}

// MARK: - Supporting Types

private struct DestinationKey: Hashable {
    let destination: String
    let fileType: CopyFileType
}

private struct CollisionEntry {
    let packIndex: Int
    let componentIndex: Int
}

/// A TechPack wrapper that overrides `components` with collision-resolved versions.
/// All other protocol members forward to the inner pack.
private struct CollisionResolvedTechPack: TechPack {
    private let inner: any TechPack
    let components: [ComponentDefinition]

    init(wrapping pack: any TechPack, components: [ComponentDefinition]) {
        inner = pack
        self.components = components
    }

    var identifier: String {
        inner.identifier
    }

    var displayName: String {
        inner.displayName
    }

    var description: String {
        inner.description
    }

    var templates: [TemplateContribution] {
        get throws { try inner.templates }
    }

    var templateSectionIdentifiers: [String] {
        inner.templateSectionIdentifiers
    }

    func supplementaryDoctorChecks(projectRoot: URL?) -> [any DoctorCheck] {
        inner.supplementaryDoctorChecks(projectRoot: projectRoot)
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        try inner.configureProject(at: path, context: context)
    }

    func templateValues(context: ProjectConfigContext) throws -> [String: String] {
        try inner.templateValues(context: context)
    }

    func declaredPrompts(context: ProjectConfigContext) -> [PromptDefinition] {
        inner.declaredPrompts(context: context)
    }
}
