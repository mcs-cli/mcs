import ArgumentParser
import Foundation

struct BootstrapCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "bootstrap",
        abstract: "Apply a declarative \(BootstrapFile.defaultFilename) — install packs and sync the current project"
    )

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Skip the confirmation prompt when packs would be removed")
    var yes: Bool = false

    var skipLock: Bool {
        dryRun
    }

    func perform() throws {
        let ctx = PackCommandContext()
        defer { MCSAnalytics.trackCommand(.bootstrap) }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try guardCwd(cwd: cwd, env: ctx.env, output: ctx.output)

        guard ensureClaudeCLI(shell: ctx.shell, environment: ctx.env, output: ctx.output) else {
            throw ExitCode.failure
        }

        let filePath = cwd.appendingPathComponent(BootstrapFile.defaultFilename)
        let file: BootstrapFile
        do {
            file = try BootstrapFile.load(from: filePath)
        } catch let error as BootstrapFileError {
            ctx.output.error(error.localizedDescription)
            throw ExitCode.failure
        }

        ctx.output.header("Bootstrap")
        ctx.output.plain("")
        ctx.output.info(label: "File", filePath.path)
        ctx.output.info(label: "Packs", file.packs.map(\.source).joined(separator: ", "))

        let desiredIdentifiers = try installPacks(file: file, ctx: ctx)

        var projectState: ProjectState
        do {
            projectState = try ProjectState(projectRoot: cwd)
        } catch {
            ctx.output.error("Corrupt .mcs-project: \(error.localizedDescription)")
            ctx.output.error("Delete .claude/.mcs-project and re-run 'mcs bootstrap'.")
            throw ExitCode.failure
        }

        let registry = TechPackRegistry.loadWithExternalPacks(environment: ctx.env, output: ctx.output)
        try seedPromptValues(file: file, state: &projectState, output: ctx.output)
        try runSync(
            projectRoot: cwd,
            desiredIdentifiers: desiredIdentifiers,
            projectState: projectState,
            env: ctx.env,
            output: ctx.output,
            shell: ctx.shell,
            registry: registry
        )

        if !dryRun {
            let config = MCSConfig.load(from: ctx.env.mcsConfigFile, output: ctx.output)
            UpdateChecker.syncHook(config: config, env: ctx.env, output: ctx.output)
            UpdateChecker.checkAndPrint(env: ctx.env, shell: ctx.shell, output: ctx.output)
        }
    }

    // MARK: - Guards

    /// Bootstrap always acts on the current directory as project scope. Refuse to run
    /// from `~/.claude` or `$HOME` — those are global-scope territory, not projects.
    private func guardCwd(cwd: URL, env: Environment, output: CLIOutput) throws {
        guard env.isInsideClaudeHome(cwd) else { return }
        output.error("'mcs bootstrap' must be run from a project directory, not \(cwd.path).")
        output.plain("  Move to a project folder that contains \(BootstrapFile.defaultFilename) and re-run.")
        throw ExitCode.failure
    }

    // MARK: - Install packs

    /// Reconcile each declared pack with the registry and return the resolved identifier list
    /// in the file's order. Uses the smallest operation that fits:
    /// - No-op when the pack is already registered from the same source + ref.
    /// - `PackUpdater.updateGitPack` when only the ref differs (git packs).
    /// - `PackAdder` (auto-accept) when the identifier is registered from a different source.
    /// - `PackAdder` (default) when the pack is new to the registry.
    private func installPacks(
        file: BootstrapFile,
        ctx: PackCommandContext
    ) throws -> [String] {
        let resolver = PackSourceResolver()
        let adder = PackAdder(ctx: ctx)
        let bootstrapOptions = PackAdder.Options(showNextSteps: false)

        var bySourceURL: [String: PackRegistryFile.PackEntry] = [:]
        for entry in try ctx.loadRegistry().packs {
            bySourceURL[entry.sourceURL] = entry
        }

        var identifiers: [String] = []
        for pack in file.packs {
            let packSource: PackSource
            do {
                packSource = try resolver.resolve(pack.source)
            } catch {
                ctx.output.error("Failed to resolve '\(pack.source)': \(error.localizedDescription)")
                throw ExitCode.failure
            }

            let sourceURL = packSource.referenceURL
            let existing = bySourceURL[sourceURL]

            if dryRun {
                if let existing {
                    ctx.output.dimmed("  already registered: \(pack.source)")
                    identifiers.append(existing.identifier)
                } else {
                    ctx.output.info("  would fetch: \(pack.source)\(pack.ref.map { "@\($0)" } ?? "")")
                }
                continue
            }

            // Local packs stay in-place; nothing to fetch or refresh when re-declared.
            if case .localPath = packSource, let existing {
                ctx.output.dimmed("  \(pack.source) already registered (local pack)")
                identifiers.append(existing.identifier)
                continue
            }

            if let existing {
                let reconciled = try reconcileExistingGitPack(
                    existing: existing,
                    pack: pack,
                    ctx: ctx
                )
                bySourceURL[reconciled.sourceURL] = reconciled
                identifiers.append(reconciled.identifier)
            } else {
                let outcome = try adder.add(source: packSource, ref: pack.ref, options: bootstrapOptions)
                switch outcome {
                case let .installed(entry):
                    bySourceURL[entry.sourceURL] = entry
                    identifiers.append(entry.identifier)
                case .declined:
                    ctx.output.error("Bootstrap aborted: pack '\(pack.source)' was not added.")
                    throw ExitCode.failure
                case .previewed:
                    // PackAdder only returns .previewed when Options.preview is true;
                    // bootstrap never sets that flag.
                    ctx.output.error("Unexpected preview outcome for '\(pack.source)'.")
                    throw ExitCode.failure
                }
            }
        }

        return identifiers
    }

    /// Handle a git pack that is already registered — either a same-ref no-op or a
    /// `PackUpdater`-driven ref advance. Local packs never reach this path (they're
    /// handled inline in `installPacks`).
    private func reconcileExistingGitPack(
        existing: PackRegistryFile.PackEntry,
        pack: BootstrapFile.PackRef,
        ctx: PackCommandContext
    ) throws -> PackRegistryFile.PackEntry {
        if existing.ref == pack.ref {
            ctx.output.dimmed("  \(pack.source) already registered\(pack.ref.map { "@\($0)" } ?? "")")
            return existing
        }

        ctx.output.info("Updating '\(existing.displayName)' to \(pack.ref ?? "default branch")...")
        var target = existing
        target.ref = pack.ref

        guard let packPath = target.resolvedPath(packsDirectory: ctx.env.packsDirectory) else {
            ctx.output.error("Pack '\(target.identifier)' has an invalid path — skipping")
            throw ExitCode.failure
        }

        let updater = PackUpdater(
            fetcher: PackFetcher(shell: ctx.shell, output: ctx.output, packsDirectory: ctx.env.packsDirectory),
            trustManager: PackTrustManager(output: ctx.output),
            environment: ctx.env,
            output: ctx.output
        )
        let result = updater.updateGitPack(entry: target, packPath: packPath, registry: ctx.registry)

        switch result {
        case .alreadyUpToDate:
            ctx.output.success("\(target.displayName): already up to date")
            return target
        case let .updated(entry, diff):
            var latest = try ctx.loadRegistry()
            ctx.registry.register(entry, in: &latest)
            try ctx.registry.save(latest)
            ctx.output.success("\(entry.displayName): \(existing.shortSHA) → \(entry.shortSHA)")
            if let diff {
                ctx.output.packChangeSummary(diff, indent: "    ")
            }
            return entry
        case .trustDeclined:
            ctx.output.error("Bootstrap aborted: trust declined for '\(target.identifier)'")
            throw ExitCode.failure
        case .fetchFailed, .manifestInvalid, .internalError:
            ctx.output.error("Bootstrap aborted: \(result.reason ?? "update failed") (\(target.identifier))")
            throw ExitCode.failure
        }
    }

    // MARK: - Prompt priors

    /// Merge the bootstrap file's `values` into `state.resolvedValues`. The sync engine
    /// reuses these as priors, so declared values do not re-prompt. Keys not declared by
    /// any pack still land as priors and satisfy the undeclared-placeholder scan in
    /// `Configurator.resolveAllValues`.
    private func seedPromptValues(
        file: BootstrapFile,
        state: inout ProjectState,
        output: CLIOutput
    ) throws {
        guard file.packs.contains(where: { !($0.values?.isEmpty ?? true) }) else { return }
        let seeds = file.packs.flatMap { pack in
            (pack.values ?? [:]).map { ($0.key, $0.value) }
        }
        if dryRun {
            output.dimmed("  would seed \(seeds.count) prompt value(s) into project state")
            return
        }

        var current = state.resolvedValues ?? [:]
        for (key, value) in seeds {
            current[key] = value
        }
        state.setResolvedValues(current)
        do {
            try state.save()
        } catch {
            output.warn("Could not seed prompt values: \(error.localizedDescription)")
        }
    }

    // MARK: - Sync

    /// Run project sync authoritatively for the declared pack set.
    /// Removals go through the same `Configurator.configure(confirmRemovals:)` gate
    /// `mcs sync` uses; `--yes` bypasses the confirmation.
    private func runSync(
        projectRoot: URL,
        desiredIdentifiers: [String],
        projectState: ProjectState,
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry
    ) throws {
        if SyncCommand.scopeIsBlockedByUnloadablePack(
            configured: projectState.configuredPacks, registry: registry, output: output
        ) {
            return
        }

        let globalState: ProjectState
        do {
            globalState = try ProjectState(stateFile: env.globalStateFile)
        } catch {
            output.error("Corrupt global state: \(error.localizedDescription)")
            output.error("Delete \(env.globalStateFile.path) and re-run 'mcs sync --global'.")
            throw ExitCode.failure
        }

        let resolvedPacks: [any TechPack] = desiredIdentifiers.compactMap { registry.pack(for: $0) }
        let unknown = Set(desiredIdentifiers).subtracting(resolvedPacks.map(\.identifier))
        for id in unknown.sorted() {
            output.warn("Pack '\(id)' failed to load — skipping")
        }
        guard !resolvedPacks.isEmpty else {
            output.error("No packs from \(BootstrapFile.defaultFilename) could be loaded.")
            throw ExitCode.failure
        }

        let filteredPacks = try ConfiguratorSupport.filterGloballyBlocked(
            resolvedPacks,
            globallyInstalled: globalState.configuredPacks,
            previouslyConfigured: projectState.configuredPacks,
            output: output
        )

        let configurator = Configurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: projectRoot, environment: env)
        )

        output.header("Sync Project")
        output.plain("")
        output.info(label: "Project", projectRoot.path)
        output.info(label: "Packs", filteredPacks.map(\.displayName).joined(separator: ", "))

        if dryRun {
            try configurator.dryRun(packs: filteredPacks)
        } else {
            try configurator.configure(
                packs: filteredPacks,
                confirmRemovals: !yes,
                excludedComponents: projectState.allExcludedComponents
            )
            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }
}

// MARK: - PackSource helper

extension PackSource {
    /// String form used as the registry `sourceURL`.
    /// Git URLs use their URL; local packs use their absolute path.
    var referenceURL: String {
        switch self {
        case let .gitURL(url): url
        case let .localPath(path): path.path
        }
    }
}
