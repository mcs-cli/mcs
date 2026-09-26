import Foundation

/// Resolves which scopes `mcs update` should refresh.
///
/// `ProjectState` is the source of truth for whether a scope has configured packs.
/// `~/.mcs/projects.yaml` is consulted only for project discovery (`.everywhere`)
/// and for stale-entry pruning, since the index write in sync is best-effort and
/// can lag behind state on a partial failure.
struct UpdateScopeResolver {
    let environment: Environment
    let output: CLIOutput

    struct ScopeRun {
        let label: String
        let strategy: any SyncStrategy
        let configuredPackIDs: Set<String>
        let isGlobal: Bool
        /// The project root path. `nil` for the global scope.
        let projectPath: URL?
    }

    enum Filter {
        case all
        case globalOnly
        case projectOnly
        case everywhere
    }

    func resolve(filter: Filter, projectRoot: URL?, dryRun: Bool = false) throws -> [ScopeRun] {
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
        var indexData = try indexFile.load()

        let pruned = indexFile.pruneStale(in: &indexData)
        if !pruned.isEmpty {
            output.dimmed("Pruned \(pruned.count) stale project entries from index.")
            if !dryRun {
                try indexFile.save(indexData)
            }
        }

        var runs: [ScopeRun] = []

        if filter != .projectOnly, let run = try scopeRun(projectRoot: nil) {
            runs.append(run)
        }

        switch filter {
        case .everywhere:
            for entry in indexData.projects {
                guard let projectURL = entry.url?.standardizedFileURL else { continue }
                if let run = try buildRun(
                    strategy: ProjectSyncStrategy(projectPath: projectURL, environment: environment),
                    label: "Project: \(entry.path)",
                    isGlobal: false,
                    projectPath: projectURL
                ) {
                    runs.append(run)
                }
            }
        case .all, .projectOnly:
            if let projectRoot, let run = try scopeRun(projectRoot: projectRoot) {
                runs.append(run)
            }
        case .globalOnly:
            break
        }

        return runs
    }

    /// The run for one scope — the global scope when `projectRoot` is nil — or nil when it has
    /// no configured packs.
    func scopeRun(projectRoot: URL?) throws -> ScopeRun? {
        guard let projectRoot else {
            return try buildRun(
                strategy: GlobalSyncStrategy(environment: environment),
                label: "Global (\(environment.claudeDirectory.path))",
                isGlobal: true,
                projectPath: nil
            )
        }
        return try buildRun(
            strategy: ProjectSyncStrategy(projectPath: projectRoot, environment: environment),
            label: "Project (\(projectRoot.lastPathComponent))",
            isGlobal: false,
            projectPath: projectRoot
        )
    }

    private func buildRun(
        strategy: any SyncStrategy,
        label: String,
        isGlobal: Bool,
        projectPath: URL?
    ) throws -> ScopeRun? {
        let state = try ProjectState(stateFile: strategy.scope.stateFile)
        let configured = state.configuredPacks
        guard !configured.isEmpty else { return nil }

        return ScopeRun(
            label: label,
            strategy: strategy,
            configuredPackIDs: configured,
            isGlobal: isGlobal,
            projectPath: projectPath
        )
    }
}
