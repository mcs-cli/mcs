import Foundation

/// Moves the plugins mcs installed to their marketplace's current version, for `mcs update`.
///
/// Only recorded plugins are touched: one the user installed at the same scope was never claimed
/// (`ComponentExecutor.PluginInstallOutcome.alreadyInstalled`), so its version stays theirs to manage.
struct PluginRefresher {
    struct Change: Equatable {
        let scopeLabel: String
        let id: String
        let from: String?
        let to: String?
    }

    let claudeCLI: any ClaudeCLI
    let output: CLIOutput

    @discardableResult
    func refresh(scopes: [SyncScope], dryRun: Bool) -> [Change] {
        guard claudeCLI.isAvailable else { return [] }
        let plans = scopes.compactMap { scope in recordedPluginIDs(in: scope).map { (scope, $0) } }
            .filter { !$0.1.isEmpty }
        guard !plans.isEmpty else { return [] }

        output.header("Plugins")
        if dryRun {
            for (scope, ids) in plans {
                output.dimmed("  \(scope.label): would update \(ids.joined(separator: ", "))")
            }
            return []
        }

        var failed = false
        // A marketplace shared by several scopes needs one refresh, not one per scope.
        let marketplaces = Set(plans.flatMap(\.1).compactMap(Self.marketplaceName(of:)))
        for name in marketplaces.sorted() {
            let result = claudeCLI.pluginMarketplaceUpdate(name: name)
            if !result.succeeded {
                failed = true
                output.warn("  Could not refresh marketplace '\(name)': \(String(result.stderr.prefix(200)))")
            }
        }

        var changes: [Change] = []
        for (scope, ids) in plans {
            let before = versions(in: scope)
            for id in ids {
                let result = claudeCLI.pluginUpdate(
                    id: id, scope: scope.pluginScope, workingDirectory: scope.mcpWorkingDirectory
                )
                if !result.succeeded {
                    failed = true
                    output.warn("  Could not update plugin '\(id)': \(String(result.stderr.prefix(200)))")
                }
            }
            let after = versions(in: scope)
            // Comparing against a listing that failed would report every plugin as changed.
            guard let before, let after else {
                failed = true
                continue
            }
            for id in ids where before[id] != after[id] {
                changes.append(Change(scopeLabel: scope.label, id: id, from: before[id], to: after[id]))
                output.success("  \(scope.label): \(id) \(before[id] ?? "?") → \(after[id] ?? "?")")
            }
        }
        if changes.isEmpty, !failed {
            output.dimmed("  All plugins up to date")
        }
        return changes
    }

    /// The `name@marketplace` ids recorded in the scope's state, or nil when it can't be read.
    private func recordedPluginIDs(in scope: SyncScope) -> [String]? {
        let state: ProjectState
        do {
            state = try ProjectState(stateFile: scope.stateFile)
        } catch {
            output.warn("  \(scope.label): could not read state, skipping plugin updates: \(error.localizedDescription)")
            return nil
        }
        let declared = state.configuredPacks.sorted().flatMap { state.artifacts(for: $0)?.plugins ?? [] }
        guard !declared.isEmpty else { return [] }

        let refs = declared.map(PluginRef.init)
        var marketplaces: [PluginMarketplace] = []
        if refs.contains(where: { $0.marketplaceName == nil }) {
            marketplaces = listMarketplaces()
        }
        var ids: [String] = []
        for ref in refs {
            guard let id = ref.pluginID(in: marketplaces) else {
                output.warn("  Could not find the marketplace for plugin '\(ref.fullName)', not updating it")
                continue
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private func listMarketplaces() -> [PluginMarketplace] {
        let result = claudeCLI.pluginMarketplaceList()
        guard result.succeeded else {
            output.warn("  Could not list plugin marketplaces: \(String(result.stderr.prefix(200)))")
            return []
        }
        do {
            return try JSONDecoder().decode([PluginMarketplace].self, from: Data(result.stdout.utf8))
        } catch {
            output.warn("  Could not read the plugin marketplace list: \(error.localizedDescription)")
            return []
        }
    }

    /// nil when the listing can't be read, so a failure never reads as "no versions".
    private func versions(in scope: SyncScope) -> [String: String]? {
        let result = claudeCLI.pluginList(workingDirectory: scope.mcpWorkingDirectory)
        guard result.succeeded else {
            output.warn("  \(scope.label): could not list plugins: \(String(result.stderr.prefix(200)))")
            return nil
        }
        do {
            let plugins = try JSONDecoder().decode([InstalledPlugin].self, from: Data(result.stdout.utf8))
            var versions: [String: String] = [:]
            for plugin in plugins where plugin.isInstall(atScope: scope.pluginScope, projectDirectory: scope.mcpWorkingDirectory) {
                versions[plugin.id] = plugin.version
            }
            return versions
        } catch {
            output.warn("  Could not read the plugin list: \(error.localizedDescription)")
            return nil
        }
    }

    private static func marketplaceName(of id: String) -> String? {
        let parts = id.split(separator: "@", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
}
