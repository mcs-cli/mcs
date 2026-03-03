import Foundation

/// Determines whether a global resource (brew package or plugin) can be safely
/// removed by checking all projects and the global scope for references.
///
/// Uses a two-tier check:
/// 1. Global-state artifact records (ownership) for other globally-configured packs
/// 2. Project index → `.mcs-project` → pack manifest (declarations) for project-scoped packs
///
/// MCP servers are project-independent (scoped via `-s local`) and never need ref counting.
struct ResourceRefCounter {
    let environment: Environment
    let output: CLIOutput
    let registry: TechPackRegistry

    enum Resource: Equatable {
        case brewPackage(String)
        case plugin(String)

        var displayName: String {
            switch self {
            case let .brewPackage(name): "brew package '\(name)'"
            case let .plugin(name): "plugin '\(PluginRef(name).bareName)'"
            }
        }
    }

    /// Check if a resource is still needed by any scope OTHER than the one being removed.
    ///
    /// - Parameters:
    ///   - resource: The brew package or plugin to check.
    ///   - scopePath: The scope being removed (project path, `ProjectIndex.globalSentinel`,
    ///     or `ProjectIndex.packRemoveSentinel` when removing a pack entirely).
    ///   - packID: The pack being unconfigured within that scope.
    /// - Returns: `true` if the resource is still needed (do NOT remove), `false` if safe to remove.
    func isStillNeeded(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        checkGlobalArtifacts(resource, excludingScope: scopePath, excludingPack: packID)
            || checkProjectIndex(resource, excludingScope: scopePath, excludingPack: packID)
    }

    // MARK: - Private

    /// Check if any other pack in global-state.json owns the resource.
    private func checkGlobalArtifacts(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        guard let globalState = try? ProjectState(stateFile: environment.globalStateFile) else {
            output.warn("Could not read global state — keeping \(resource.displayName) as a precaution")
            return true
        }

        for otherPackID in globalState.configuredPacks {
            // Skip the pack being removed if we're in the global scope or removing the pack entirely
            if scopePath == ProjectIndex.globalSentinel || scopePath == ProjectIndex.packRemoveSentinel,
               otherPackID == packID {
                continue
            }

            guard let artifacts = globalState.artifacts(for: otherPackID) else { continue }

            switch resource {
            case let .brewPackage(name):
                if artifacts.brewPackages.contains(name) { return true }
            case let .plugin(name):
                let refBareName = PluginRef(name).bareName
                if artifacts.plugins.contains(where: { PluginRef($0).bareName == refBareName }) {
                    return true
                }
            }
        }

        return false
    }

    /// Check if any project (via manifest declarations) still needs the resource.
    private func checkProjectIndex(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
        guard var indexData = try? indexFile.load() else {
            output.warn("Could not read project index — keeping \(resource.displayName) as a precaution")
            return true
        }

        let fm = FileManager.default
        var stalePaths: [String] = []

        for entry in indexData.projects {
            // Skip the scope being removed
            if entry.path == scopePath { continue }

            // Validate project still exists (skip __global__ — always valid)
            if entry.path != ProjectIndex.globalSentinel {
                guard fm.fileExists(atPath: entry.path) else {
                    stalePaths.append(entry.path)
                    continue
                }
            }

            // Check each pack in this scope
            for otherPackID in entry.packs {
                // When removing a pack entirely, skip that pack in every scope
                if scopePath == ProjectIndex.packRemoveSentinel, otherPackID == packID { continue }
                if packDeclaresResource(packID: otherPackID, resource: resource) {
                    // Clean up stale entries we found along the way before returning
                    pruneStaleEntries(stalePaths, in: &indexData, indexFile: indexFile)
                    return true
                }
            }
        }

        // Clean up any stale entries we found
        pruneStaleEntries(stalePaths, in: &indexData, indexFile: indexFile)

        return false
    }

    /// Check if a pack's manifest declares the given resource.
    /// Returns `true` (conservative) if the pack can't be loaded.
    private func packDeclaresResource(packID: String, resource: Resource) -> Bool {
        guard let pack = registry.pack(for: packID) else {
            // Pack not loadable (removed from registry?) — be conservative
            output.dimmed("  Pack '\(packID)' not found in registry — assuming resource still needed")
            return true
        }

        for component in pack.components {
            switch (resource, component.installAction) {
            case let (.brewPackage(name), .brewInstall(pkg)):
                if pkg == name { return true }
            case let (.plugin(name), .plugin(pluginName)):
                if PluginRef(pluginName).bareName == PluginRef(name).bareName { return true }
            default:
                break
            }
        }

        return false
    }

    /// Opportunistically prune stale project entries and warn the user.
    private func pruneStaleEntries(
        _ paths: [String],
        in data: inout ProjectIndex.IndexData,
        indexFile: ProjectIndex
    ) {
        guard !paths.isEmpty else { return }
        for path in paths {
            output.warn("Project not found: \(path) — removing from index")
            indexFile.remove(projectPath: path, from: &data)
        }
        do {
            try indexFile.save(data)
        } catch {
            output.warn("Could not persist pruned index entries: \(error.localizedDescription)")
        }
    }
}
