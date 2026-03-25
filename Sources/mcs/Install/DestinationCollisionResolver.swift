import Foundation

/// Detects cross-pack `copyPackFile` destination collisions and applies conditional namespacing.
///
/// When no collision exists, destinations remain flat (e.g., `.claude/commands/pr.md`).
/// When two+ packs define the same `(destination, fileType)`:
/// - **Non-skill types**: destinations are prefixed with `<pack-id>/` subdirectory
/// - **Skills**: destinations are suffixed with `-<pack-id>` (first pack keeps the clean name)
///   because Claude Code requires flat one-level directories for skill discovery.
enum DestinationCollisionResolver {
    /// Returns a new pack array with destinations namespaced only for conflicting files.
    /// Emits warnings for skill collisions via `output`.
    static func resolveCollisions(packs: [any TechPack], output: CLIOutput) -> [any TechPack] {
        // Phase 1: Scan all packs for copyPackFile destinations
        // Key: (destination, fileType) → [(packIndex, componentIndex)]
        var collisionMap: [DestinationKey: [CollisionEntry]] = [:]

        for (packIndex, pack) in packs.enumerated() {
            for (componentIndex, component) in pack.components.enumerated() {
                guard case let .copyPackFile(_, destination, fileType) = component.installAction else {
                    continue
                }
                let key = DestinationKey(destination: destination, fileType: fileType)
                collisionMap[key, default: []].append(
                    CollisionEntry(packIndex: packIndex, componentIndex: componentIndex)
                )
            }
        }

        // Phase 2: Identify actual collisions (2+ distinct pack indices)
        var packComponentOverrides: [Int: [Int: String]] = [:] // packIndex → (componentIndex → newDestination)

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

        // Phase 3: Build result — wrap only packs that have overrides
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

    /// For non-skill types, prefix all colliding entries with `<pack-id>/`.
    private static func applySubdirectoryPrefix(
        entries: [CollisionEntry],
        packs: [any TechPack],
        overrides: inout [Int: [Int: String]]
    ) {
        for entry in entries {
            let pack = packs[entry.packIndex]
            let component = pack.components[entry.componentIndex]
            guard case let .copyPackFile(_, destination, _) = component.installAction else { continue }
            let namespaced = "\(pack.identifier)/\(destination)"
            overrides[entry.packIndex, default: [:]][entry.componentIndex] = namespaced
        }
    }

    /// For skills, the first pack keeps the clean name; subsequent packs get `-<pack-id>` suffix.
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
            let pack = packs[entry.packIndex]
            let suffixed = "\(destination)-\(pack.identifier)"
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
