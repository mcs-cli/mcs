import ArgumentParser
import Foundation

/// Refresh-only orchestration: fetch latest pack contents (with trust verification),
/// then re-apply the existing configured set in both the global scope and the current
/// project's scope. Does not add or remove packs (use `mcs sync`).
struct UpdateCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Fetch latest pack versions and re-apply across configured scopes"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Flag(name: .shortAndLong, help: "Only refresh the global scope")
    var global: Bool = false

    @Flag(name: .shortAndLong, help: "Only refresh the current project's scope")
    var project: Bool = false

    @Flag(
        name: [.short, .customLong("all-projects")],
        help: "Refresh every project in the index plus the global scope (fan out machine-wide)"
    )
    var allProjects: Bool = false

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    var skipLock: Bool {
        dryRun
    }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

        let (filter, projectRoot) = try resolveScopeSelection(output: output)

        let resolver = UpdateScopeResolver(environment: env, output: output)
        let runs = try resolver.resolve(filter: filter, projectRoot: projectRoot, dryRun: dryRun)

        guard !runs.isEmpty else {
            output.info("Nothing to update — no scopes have configured packs.")
            return
        }

        if allProjects, !confirmFanOut(runs: runs, env: env, output: output) {
            output.info("Update cancelled.")
            return
        }

        warnIfProjectScopeMissing(filter: filter, projectRoot: projectRoot, runs: runs, output: output)

        let configuredAcrossScopes = runs.reduce(into: Set<String>()) {
            $0.formUnion($1.configuredPackIDs)
        }

        let registryFile = PackRegistryFile(path: env.packsRegistry)
        let registryData = try registryFile.load()

        let updatePhase = try runUpdatePhase(
            packIDsToUpdate: configuredAcrossScopes,
            registryFile: registryFile,
            registryData: registryData,
            env: env,
            shell: shell,
            output: output
        )

        if !dryRun, updatePhase.anyUpdated {
            try registryFile.save(updatePhase.data)
        }

        let techPackRegistry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        let unresolvedScopes = try ScopeReapplier.reapplyScopes(
            runs,
            skippedPackIDs: updatePhase.skipped,
            registry: techPackRegistry,
            dryRun: dryRun,
            env: env,
            shell: shell,
            output: output
        )

        if !dryRun {
            // Surface + persist any legacy MCSConfig migration from this write-safe
            // path. GlobalSyncStrategy loads the config silently during compose, so
            // without this call a legacy config would silently in-memory-migrate but
            // leave the deprecated keys on disk, deferring the notice to the next
            // Sync/Bootstrap run.
            let config = MCSConfig.load(from: env.mcsConfigFile, output: output)
            config.persistMigrationIfNeeded(to: env.mcsConfigFile, output: output)
            UpdateChecker.checkAndPrint(env: env, shell: shell, output: output)
        }

        // Fail after reapply so healthy packs still converge.
        let updateFailed = PackUpdater.shouldExitNonZero(
            failedCount: updatePhase.failed.count,
            attemptedCount: updatePhase.attempted,
            isInteractive: output.hasInteractiveStdin
        )
        if updateFailed {
            output.error("Failed to update: \(updatePhase.failed.sorted().joined(separator: ", "))")
        }
        if !unresolvedScopes.isEmpty {
            output.error("Unresolved prompts in: \(unresolvedScopes.joined(separator: ", "))")
        }
        if updateFailed || !unresolvedScopes.isEmpty {
            throw ExitCode.failure
        }
    }

    // MARK: - Helpers

    private enum ScopeFlag: String {
        case global = "--global"
        case project = "--project"
        case allProjects = "--all-projects"
    }

    private var activeScopeFlags: [ScopeFlag] {
        var flags: [ScopeFlag] = []
        if global { flags.append(.global) }
        if project { flags.append(.project) }
        if allProjects { flags.append(.allProjects) }
        return flags
    }

    private func resolveScopeSelection(
        output: CLIOutput
    ) throws -> (UpdateScopeResolver.Filter, URL?) {
        let active = activeScopeFlags
        guard active.count <= 1 else {
            let names = active.map(\.rawValue).joined(separator: ", ")
            output.error("\(names) are mutually exclusive.")
            throw ExitCode.failure
        }

        switch active.first {
        case .allProjects:
            return (.everywhere, nil)
        case .global:
            return (.globalOnly, nil)
        case .project:
            guard let root = detectProjectRoot() else {
                output.error("--project specified but no project root detected at \(targetPath.path).")
                output.plain("  cd into a project directory, pass a path, or omit --project.")
                throw ExitCode.failure
            }
            return (.projectOnly, root)
        case .none:
            return (.all, detectProjectRoot())
        }
    }

    private func confirmFanOut(
        runs: [UpdateScopeResolver.ScopeRun],
        env: Environment,
        output: CLIOutput
    ) -> Bool {
        guard !dryRun, output.hasInteractiveStdin else { return true }

        let projectPaths = runs.compactMap(\.projectPath)
        let hasGlobal = runs.contains(where: \.isGlobal)
        guard !projectPaths.isEmpty || hasGlobal else { return true }

        let projectNoun = projectPaths.count == 1 ? "project" : "projects"
        let summary = if hasGlobal, !projectPaths.isEmpty {
            "the global scope and \(projectPaths.count) \(projectNoun)"
        } else if hasGlobal {
            "the global scope"
        } else {
            "\(projectPaths.count) \(projectNoun)"
        }

        output.plain("")
        output.warn("--all-projects will refresh \(summary):")
        output.plain("")
        if hasGlobal {
            output.plain("  • global    \(env.claudeDirectory.path)")
        }
        for path in projectPaths {
            output.plain("  • project   \(path.path)")
        }
        output.plain("")
        output.plain("  Each pack is re-applied in every listed scope. Local edits to")
        output.plain("  settings.local.json, hooks, or skills in those projects may be overwritten.")
        output.plain("")
        return output.askYesNo("Proceed?", default: false)
    }

    private func warnIfProjectScopeMissing(
        filter: UpdateScopeResolver.Filter,
        projectRoot: URL?,
        runs: [UpdateScopeResolver.ScopeRun],
        output: CLIOutput
    ) {
        guard filter == .all else { return }
        guard !runs.contains(where: { !$0.isGlobal }) else { return }

        if let projectRoot {
            output.warn("Project at \(projectRoot.path) has no configured packs — only refreshing the global scope.")
            output.plain("  Run 'mcs sync' inside the project to configure packs there first.")
        } else {
            output.warn("Not in a project directory — only refreshing the global scope.")
            output.plain("  cd into a project to also refresh its packs.")
        }
    }

    private var targetPath: URL {
        if let path {
            URL(fileURLWithPath: path)
        } else {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    }

    private func detectProjectRoot() -> URL? {
        ProjectDetector.findProjectRoot(from: targetPath)
    }

    private func runUpdatePhase(
        packIDsToUpdate: Set<String>,
        registryFile: PackRegistryFile,
        registryData: PackRegistryFile.RegistryData,
        env: Environment,
        shell: ShellRunner,
        output: CLIOutput
    ) throws -> UpdatePhaseOutcome {
        var updatedData = registryData
        var anyUpdated = false
        // `skipped` is excluded from reapply (every non-updated pack lands here so we never
        // reapply a stale/broken checkout). `failed` is the hard-failure subset of `skipped`,
        // used only for the exit-code decision in `perform()`. `attempted` counts the non-local
        // packs we tried, so "every attempted pack failed" is an accurate trigger.
        var skipped: Set<String> = []
        var failed: Set<String> = []
        var attempted = 0

        let entries = registryData.packs.filter { packIDsToUpdate.contains($0.identifier) }
        guard !entries.isEmpty else {
            return UpdatePhaseOutcome(data: updatedData, anyUpdated: anyUpdated, skipped: skipped, failed: failed, attempted: attempted)
        }

        output.header("Updating packs")

        if dryRun {
            for entry in entries {
                if entry.isCheckoutMissing(packsDirectory: env.packsDirectory) {
                    output.dimmed("  \(entry.displayName): would re-fetch (checkout missing)")
                } else {
                    output.dimmed("  \(entry.displayName): would check for updates")
                }
            }
            return UpdatePhaseOutcome(data: updatedData, anyUpdated: anyUpdated, skipped: skipped, failed: failed, attempted: attempted)
        }

        let updater = PackUpdater(
            fetcher: PackFetcher(shell: shell, output: output, packsDirectory: env.packsDirectory),
            trustManager: PackTrustManager(output: output),
            environment: env,
            output: output
        )

        for entry in entries {
            if entry.isLocalPack {
                output.dimmed("  \(entry.displayName): local pack (skipped)")
                continue
            }

            attempted += 1
            guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
                output.warn("  \(entry.identifier): invalid path — skipping")
                skipped.insert(entry.identifier)
                failed.insert(entry.identifier)
                continue
            }

            let result = updater.updateGitPack(entry: entry, packPath: packPath, registry: registryFile)
            switch result {
            case .alreadyUpToDate:
                output.dimmed("  \(entry.displayName): already up to date")
            case let .updated(updatedEntry, diff):
                registryFile.register(updatedEntry, in: &updatedData)
                anyUpdated = true
                output.success("  \(entry.displayName): \(entry.shortSHA) → \(updatedEntry.shortSHA)")
                output.packChangeSummary(diff, indent: "    ")
            case .trustDeclined:
                output.info("  \(entry.identifier): \(result.reason ?? "trust not granted") (will re-prompt on next 'mcs update')")
                skipped.insert(entry.identifier)
            case .fetchFailed, .manifestInvalid, .internalError:
                output.warn("  \(entry.identifier): \(result.reason ?? "update failed")")
                skipped.insert(entry.identifier)
                failed.insert(entry.identifier)
            }
        }

        return UpdatePhaseOutcome(data: updatedData, anyUpdated: anyUpdated, skipped: skipped, failed: failed, attempted: attempted)
    }

    /// Result of the fetch/trust update pass, before reapply. `skipped` packs are excluded
    /// from reapply; `failed` is the hard-failure subset used for the process exit code.
    private struct UpdatePhaseOutcome {
        let data: PackRegistryFile.RegistryData
        let anyUpdated: Bool
        let skipped: Set<String>
        let failed: Set<String>
        let attempted: Int
    }
}
