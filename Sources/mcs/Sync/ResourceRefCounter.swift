import Foundation

/// Determines whether a global resource (brew package, plugin, or gitignore entry) can be
/// safely removed by checking all projects and the global scope for references.
///
/// Uses a two-tier check:
/// 1. Global-state artifact records (ownership) for other globally-configured packs
/// 2. Project index → `.mcs-project` → pack manifest (declarations) for project-scoped packs
///
/// MCP servers are project-independent (scoped via `-s local`) and never need ref counting.
/// Gitignore entries do: `GitignoreManager` resolves one file for the whole machine, so a
/// pack installed in two scopes holds two claims on a single physical line.
struct ResourceRefCounter {
    let environment: Environment
    let output: CLIOutput
    let registry: TechPackRegistry

    /// Decoded state, read once per counter and shared by every `isStillNeeded` call it serves.
    ///
    /// One removal pass queries once per artifact, and a pack can declare many — nothing rewrites
    /// these files in between, except this type's own stale-entry pruning, which the cache
    /// collapses from a warning-and-write per query into one for the whole pass.
    private let cache = StateCache()

    private final class StateCache {
        var globalState: ProjectState?
        var indexData: ProjectIndex.IndexData?
        var globalStateLoaded = false
        var indexLoaded = false
    }

    enum Resource: Equatable {
        case brewPackage(String)
        case plugin(String)
        case gitignoreEntry(String)

        var displayName: String {
            switch self {
            case let .brewPackage(name): "brew package '\(name)'"
            case let .plugin(name): "plugin '\(PluginRef(name).bareName)'"
            case let .gitignoreEntry(entry): "gitignore entry '\(entry)'"
            }
        }

        /// Resources the tool owns rather than any pack, and that no pack may delete.
        ///
        /// Reference counting answers "does another *pack* claim this?" — a question that can
        /// never protect something no pack ever claimed. `GitignoreManager.coreEntries` are
        /// mcs's own lines: a pack may declare one, but must not be able to remove it.
        var isProtected: Bool {
            switch self {
            case .brewPackage, .plugin: false
            case let .gitignoreEntry(entry): GitignoreManager.coreEntries.contains(entry)
            }
        }
    }

    /// Check if a resource is still needed by any scope OTHER than the one being removed.
    ///
    /// - Parameters:
    ///   - resource: The brew package, plugin, or gitignore entry to check.
    ///   - scopePath: The scope being removed (project path, `ProjectIndex.globalSentinel`,
    ///     or `ProjectIndex.packRemoveSentinel` when removing a pack entirely).
    ///   - packID: The pack being unconfigured within that scope.
    /// - Returns: `true` if the resource is still needed (do NOT remove), `false` if safe to remove.
    func isStillNeeded(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        resource.isProtected
            || checkGlobalArtifacts(resource, excludingScope: scopePath, excludingPack: packID)
            || checkProjectIndex(resource, excludingScope: scopePath, excludingPack: packID)
    }

    // MARK: - Private

    /// Decode `global-state.json` once per counter. `nil` means unreadable, which callers treat
    /// as "keep the resource" — the conservative direction.
    private func cachedGlobalState() -> ProjectState? {
        guard !cache.globalStateLoaded else { return cache.globalState }
        cache.globalStateLoaded = true
        do {
            cache.globalState = try ProjectState(stateFile: environment.globalStateFile)
        } catch {
            output.warn(
                "Could not read global state (\(error.localizedDescription)) "
                    + "— keeping shared resources as a precaution"
            )
        }
        return cache.globalState
    }

    /// Load `projects.yaml` once per counter. `nil` means unreadable — same conservative rule.
    private func cachedIndexData() -> ProjectIndex.IndexData? {
        guard !cache.indexLoaded else { return cache.indexData }
        cache.indexLoaded = true
        do {
            cache.indexData = try ProjectIndex(path: environment.projectsIndexFile).load()
        } catch {
            output.warn(
                "Could not read project index (\(error.localizedDescription)) "
                    + "— keeping shared resources as a precaution"
            )
        }
        return cache.indexData
    }

    /// Check if any other pack in global-state.json owns the resource.
    private func checkGlobalArtifacts(
        _ resource: Resource,
        excludingScope scopePath: String,
        excludingPack packID: String
    ) -> Bool {
        guard let globalState = cachedGlobalState() else { return true }

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
            case let .gitignoreEntry(entry):
                if artifacts.gitignoreEntries.contains(entry) { return true }
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
        guard var indexData = cachedIndexData() else { return true }

        let fm = FileManager.default
        var stalePaths: [String] = []
        var stillNeeded = false

        search: for entry in indexData.projects {
            // Skip the global scope's own entry when that is what is being removed:
            // `checkGlobalArtifacts` already covers it by *ownership*, and re-scanning it here
            // by *declaration* would keep resources the pack never actually installed.
            if entry.path == scopePath, entry.path == ProjectIndex.globalSentinel { continue }

            // Validate project still exists (skip __global__ — always valid)
            if entry.path != ProjectIndex.globalSentinel {
                guard fm.fileExists(atPath: entry.path) else {
                    stalePaths.append(entry.path)
                    continue
                }
            }

            // Check each pack in this scope. The scope being removed is still scanned — a
            // *sibling* pack there is a genuine referent, and skipping the whole entry let a
            // shared artifact be deleted out from under a pack that still declares it.
            for otherPackID in entry.packs {
                // Never count the pack being unconfigured: in the scope it is leaving, and in
                // every scope when the pack is being removed outright.
                if otherPackID == packID,
                   entry.path == scopePath || scopePath == ProjectIndex.packRemoveSentinel {
                    continue
                }
                if packDeclaresResource(packID: otherPackID, resource: resource) {
                    stillNeeded = true
                    break search
                }
            }
        }

        // Prune stale entries found along the way — one write per counter, matched or not, and
        // the pruned copy goes back into the cache so later queries don't repeat the warning.
        pruneStaleEntries(
            stalePaths, in: &indexData,
            indexFile: ProjectIndex(path: environment.projectsIndexFile)
        )
        cache.indexData = indexData

        return stillNeeded
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
            // Exact match: `.gitignoreEntries` carries a literal payload that never goes
            // through placeholder substitution, unlike `MCPServerConfig.substituting`.
            case let (.gitignoreEntry(entry), .gitignoreEntries(entries)):
                if entries.contains(entry) { return true }
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
