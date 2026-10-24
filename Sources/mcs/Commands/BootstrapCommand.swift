import ArgumentParser
import Foundation

struct BootstrapCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "bootstrap",
        abstract: "Apply a declarative \(BootstrapFile.defaultFilename) — install packs and sync the current project"
    )

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .long, help: "Remove packs configured in this project but absent from mcs.yaml")
    var prune: Bool = false

    @Flag(name: .shortAndLong, help: "Skip the removal-confirmation prompt (only meaningful with --prune)")
    var yes: Bool = false

    /// `trust.policy` must reach both trust surfaces bootstrap can reach: a fresh `PackAdder.add`
    /// and a `ref:` advance through `PackUpdater`. Auto-accepting only the first leaves the second
    /// prompting whenever an advanced `ref:` brings new or changed scripts.
    @OptionGroup var trust: TrustOptions

    var skipLock: Bool {
        dryRun
    }

    func perform() throws {
        let ctx = PackCommandContext()

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let filePath = cwd.appendingPathComponent(BootstrapFile.defaultFilename)
        let file: BootstrapFile
        do {
            file = try BootstrapFile.load(from: filePath)
        } catch let error as BootstrapFileError {
            ctx.output.error(error.localizedDescription)
            throw ExitCode.failure
        }
        // A machine-only file never treats cwd as a project, so it may live anywhere.
        if file.fileScope != .global {
            try guardCwd(cwd: cwd, env: ctx.env, output: ctx.output)
        }

        // Dry-run must not trigger the Homebrew install prompt for Claude Code — that
        // would violate the no-changes contract on a preview.
        if !dryRun {
            guard ensureClaudeCLI(shell: ctx.shell, environment: ctx.env, output: ctx.output) else {
                throw ExitCode.failure
            }
        }

        ctx.output.header("Bootstrap")
        ctx.output.plain("")
        ctx.output.info(label: "File", filePath.path)
        ctx.output.info(label: "Packs", file.packs.map { redactSourceForDisplay($0.source) }.joined(separator: ", "))

        let declared = try installPacks(file: file, ctx: ctx)
        let registry = TechPackRegistry.loadWithExternalPacks(environment: ctx.env, output: ctx.output)
        try runSync(
            declared: declared,
            fileScope: file.fileScope,
            allDeclaredResolved: declared.count == file.packs.count,
            projectRoot: cwd,
            env: ctx.env,
            output: ctx.output,
            shell: ctx.shell,
            registry: registry
        )

        if !dryRun {
            let config = MCSConfig.load(from: ctx.env.mcsConfigFile, output: ctx.output)
            config.persistMigrationIfNeeded(to: ctx.env.mcsConfigFile, output: ctx.output)
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

    /// Reconcile each declared pack with the registry and return the resolved entries in the
    /// file's order, then print one status line per pack. Uses the smallest operation that fits:
    /// - No-op when the pack is already registered from the same source + ref.
    /// - `PackUpdater.updateGitPack` when only the ref differs (git packs).
    /// - `PackAdder` (auto-accept) when the identifier is registered from a different source.
    /// - `PackAdder` (default) when the pack is new to the registry.
    private func installPacks(
        file: BootstrapFile,
        ctx: PackCommandContext
    ) throws -> [DeclaredPack] {
        let resolver = PackSourceResolver()
        let adder = PackAdder(ctx: ctx)
        // Bootstrap is non-interactive by design: mcs.yaml already expresses the user's
        // intent, so identifier duplicates and artifact collisions must not fall through
        // to askYesNo (which blocks in CI and defeats the declarative contract).
        let bootstrapOptions = PackAdder.Options(
            duplicatePolicy: .autoAccept,
            showNextSteps: false,
            trustPolicy: trust.policy
        )

        var bySourceURL: [String: PackRegistryFile.PackEntry] = [:]
        do {
            for entry in try ctx.loadRegistry().packs {
                bySourceURL[entry.sourceURL] = entry
            }
        } catch {
            ctx.output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        var declared: [DeclaredPack] = []
        var statuses: [(identifier: String, status: String)] = []
        var installedThisRun: [String] = []
        // `BootstrapFile.validate` dedups on raw source strings, but PackSourceResolver
        // canonicalizes (`user/repo` → `https://github.com/user/repo.git`, `file://…` →
        // path). Two entries that differ as strings can resolve to the same URL, and
        // the loop would re-fetch and race against itself. Track canonical URLs here.
        var seenCanonicalURLs: Set<String> = []
        // Two entries with different sources can still resolve to the same manifest
        // `identifier`. With `.autoAccept`, the second `PackAdder.add` would replace
        // the first checkout and registry entry silently. Track identifiers so the
        // second one errors instead of shadowing the first.
        var seenIdentifiers: Set<String> = []
        for pack in file.packs {
            let displaySource = redactSourceForDisplay(pack.source)
            let packSource: PackSource
            do {
                packSource = try resolver.resolve(pack.source)
            } catch {
                ctx.output.error("Failed to resolve '\(displaySource)': \(error.localizedDescription)")
                reportPartialInstall(installed: installedThisRun, failedAt: pack.source, output: ctx.output)
                throw ExitCode.failure
            }

            let sourceURL = packSource.referenceURL
            if !seenCanonicalURLs.insert(sourceURL).inserted {
                ctx.output.error(
                    "Pack '\(displaySource)' resolves to '\(redactSourceForDisplay(sourceURL))'"
                        + ", already declared in this file."
                )
                reportPartialInstall(installed: installedThisRun, failedAt: pack.source, output: ctx.output)
                throw ExitCode.failure
            }
            let existing = bySourceURL[sourceURL]

            // Every existing-pack path (dry-run/existing, local/existing, git/reconcile)
            // knows the identifier before any mutation, so run the collision check once,
            // upfront. The new-pack path can only know the identifier after PackAdder
            // fetches and reads the manifest, so it runs a second check post-add.
            if let existing {
                try trackIdentifier(
                    existing.identifier,
                    source: pack.source,
                    seen: &seenIdentifiers,
                    installed: installedThisRun,
                    ctx: ctx
                )
            }

            if dryRun {
                printDryRunLine(
                    existing: existing,
                    packSource: packSource,
                    pack: pack,
                    packsDirectory: ctx.env.packsDirectory,
                    output: ctx.output
                )
                if let existing { declared.append(DeclaredPack(identifier: existing.identifier, ref: pack)) }
                continue
            }

            // Local packs stay in-place; nothing to fetch or refresh when re-declared.
            // PackAdder emits the "--ref is ignored" warning on fresh local adds; the
            // already-registered branch handles it here since PackAdder never sees it.
            if case .localPath = packSource, let existing {
                if pack.ref != nil {
                    ctx.output.warn("'\(displaySource)': --ref is ignored for local packs")
                }
                ctx.output.dimmed("  \(displaySource) already registered (local pack)")
                declared.append(DeclaredPack(identifier: existing.identifier, ref: pack))
                statuses.append((existing.identifier, "unchanged"))
                continue
            }

            do {
                if let existing {
                    let reconciled = try reconcileExistingGitPack(
                        existing: existing,
                        pack: pack,
                        ctx: ctx
                    )
                    declared.append(DeclaredPack(identifier: reconciled.identifier, ref: pack))
                    installedThisRun.append(reconciled.identifier)
                    statuses.append((reconciled.identifier, Self.reconcileStatus(existing: existing, reconciled: reconciled)))
                } else {
                    let outcome = try adder.add(source: packSource, ref: pack.ref, options: bootstrapOptions)
                    switch outcome {
                    case let .installed(entry):
                        // Post-add check: the identifier isn't knowable without a fetch,
                        // so if two entries with different sources produce the same
                        // manifest identifier, the second one has already overwritten
                        // the first by the time we detect it. The error tells the user
                        // to fix mcs.yaml and re-run.
                        try trackIdentifier(
                            entry.identifier,
                            source: pack.source,
                            seen: &seenIdentifiers,
                            installed: installedThisRun,
                            ctx: ctx
                        )
                        declared.append(DeclaredPack(identifier: entry.identifier, ref: pack))
                        installedThisRun.append(entry.identifier)
                        statuses.append((entry.identifier, "added"))
                    case .declined:
                        // Bootstrap auto-accepts duplicates and collisions, so trust is the
                        // only thing `.declined` can mean here.
                        ctx.output.error("Bootstrap aborted: pack '\(displaySource)' was not added.")
                        trust.hintIfUnattended(output: ctx.output, subject: "declared packs")
                        throw ExitCode.failure
                    case .previewed:
                        // PackAdder only returns .previewed when Options.preview is true;
                        // bootstrap never sets that flag. Belt-and-suspenders: crash in debug
                        // if that assumption ever changes so the miss is caught in tests.
                        assertionFailure("PackAdder returned .previewed but bootstrap never sets Options.preview")
                        ctx.output.error("Unexpected preview outcome for '\(displaySource)'.")
                        throw ExitCode.failure
                    }
                }
            } catch {
                printStatuses(statuses + [(displaySource, "failed")], output: ctx.output)
                reportPartialInstall(installed: installedThisRun, failedAt: pack.source, output: ctx.output)
                throw error
            }
        }

        printStatuses(statuses, output: ctx.output)
        return declared
    }

    /// Stable one-word outcomes a scheduled wrapper can parse from the log.
    private func printStatuses(_ statuses: [(identifier: String, status: String)], output: CLIOutput) {
        guard !statuses.isEmpty else { return }
        output.plain("")
        for entry in statuses {
            output.plain("  \(entry.identifier): \(entry.status)")
        }
    }

    static func reconcileStatus(
        existing: PackRegistryFile.PackEntry,
        reconciled: PackRegistryFile.PackEntry
    ) -> String {
        if existing.ref != reconciled.ref {
            return "moved to \(reconciled.ref ?? "default branch")"
        }
        return existing.commitSHA == reconciled.commitSHA ? "unchanged" : "updated"
    }

    /// Render the per-pack dry-run line. Existing packs get a dimmed "already
    /// registered" line; new packs distinguish local (registered in place) from
    /// git (would be cloned).
    private func printDryRunLine(
        existing: PackRegistryFile.PackEntry?,
        packSource: PackSource,
        pack: BootstrapFile.PackRef,
        packsDirectory: URL,
        output: CLIOutput
    ) {
        let displaySource = redactSourceForDisplay(pack.source)
        if let existing {
            if existing.isCheckoutMissing(packsDirectory: packsDirectory) {
                output.info("  would re-fetch (checkout missing): \(displaySource)")
            } else {
                output.dimmed("  already registered: \(displaySource)")
            }
            return
        }
        let isLocal = if case .localPath = packSource {
            true
        } else {
            false
        }
        let verb = isLocal ? "would register (local)" : "would fetch"
        let refSuffix = isLocal ? "" : (pack.ref.map { "@\($0)" } ?? "")
        output.info("  \(verb): \(displaySource)\(refSuffix)")
    }

    /// Reject the current entry when an earlier one in the same bootstrap already
    /// produced this identifier. Prints a partial-install epilogue and throws so
    /// the user can deduplicate `mcs.yaml` and re-run.
    private func trackIdentifier(
        _ identifier: String,
        source: String,
        seen: inout Set<String>,
        installed: [String],
        ctx: PackCommandContext
    ) throws {
        guard !seen.insert(identifier).inserted else { return }
        ctx.output.error(
            "Two entries in \(BootstrapFile.defaultFilename) resolve to the same pack"
                + " identifier '\(identifier)'. The second declaration would overwrite the first."
        )
        ctx.output.plain("  Remove the duplicate declaration or point one at a different pack.")
        reportPartialInstall(installed: installed, failedAt: source, output: ctx.output)
        throw ExitCode.failure
    }

    /// Summarize which packs are already installed when bootstrap aborts mid-loop, so users
    /// know what state re-running finds and where to resume from.
    private func reportPartialInstall(installed: [String], failedAt source: String, output: CLIOutput) {
        guard !installed.isEmpty else { return }
        let displaySource = redactSourceForDisplay(source)
        output.plain("")
        output.info(
            "\(installed.count) pack(s) already registered before the failure on '\(displaySource)':"
        )
        for id in installed {
            output.plain("  - \(id)")
        }
        output.plain("  Re-run 'mcs bootstrap' after fixing '\(displaySource)' to continue.")
    }

    /// Handle a git pack that is already registered — either a same-ref no-op or a
    /// `PackUpdater`-driven ref advance or missing-checkout re-clone. Local packs never reach this path (they're
    /// handled inline in `installPacks`).
    func reconcileExistingGitPack(
        existing: PackRegistryFile.PackEntry,
        pack: BootstrapFile.PackRef,
        ctx: PackCommandContext
    ) throws -> PackRegistryFile.PackEntry {
        guard let packPath = existing.resolvedPath(packsDirectory: ctx.env.packsDirectory) else {
            ctx.output.error("Pack '\(existing.identifier)' has an invalid path — skipping")
            throw ExitCode.failure
        }

        // A missing checkout skips both lines: the updater announces its own re-clone.
        if !PackRegistryFile.PackEntry.isCheckoutMissing(at: packPath) {
            if existing.ref == pack.ref {
                let display = redactSourceForDisplay(pack.source)
                ctx.output.dimmed("  \(display) already registered\(pack.ref.map { "@\($0)" } ?? "")")
                return existing
            }
            ctx.output.info("Updating '\(existing.displayName)' to \(pack.ref ?? "default branch")...")
        }
        var target = existing
        target.ref = pack.ref

        let updater = PackUpdater(
            fetcher: PackFetcher(shell: ctx.shell, output: ctx.output, packsDirectory: ctx.env.packsDirectory),
            trustManager: PackTrustManager(output: ctx.output, policy: trust.policy),
            environment: ctx.env,
            output: ctx.output
        )
        let result = updater.updateGitPack(entry: target, packPath: packPath, registry: ctx.registry)

        switch result {
        case .alreadyUpToDate:
            // Reached here means `existing.ref != pack.ref` (same-ref returns above), but
            // `updateGitPack` reports `.alreadyUpToDate` on SHA equality alone — the ref
            // label may still have moved (e.g. `main` → a tag on HEAD). Persist so
            // re-runs converge instead of re-attempting the same update forever.
            try persistRegistryEntry(target, ctx: ctx)
            ctx.output.success("\(target.displayName): already up to date")
            return target
        case let .updated(entry, diff):
            try persistRegistryEntry(entry, ctx: ctx)
            ctx.output.success("\(entry.displayName): \(existing.shortSHA) → \(entry.shortSHA)")
            if let diff {
                ctx.output.packChangeSummary(diff, indent: "    ")
            }
            return entry
        case .trustDeclined:
            ctx.output.error("Bootstrap aborted: trust declined for '\(target.identifier)'")
            trust.hintIfUnattended(output: ctx.output, subject: "declared packs")
            throw ExitCode.failure
        case .fetchFailed, .manifestInvalid, .internalError:
            ctx.output.error("Bootstrap aborted: \(result.reason ?? "update failed") (\(target.identifier))")
            throw ExitCode.failure
        }
    }

    /// Write a single pack entry into the on-disk registry. Reads the registry, applies
    /// the register, saves — the small triple that both reconcile branches need.
    private func persistRegistryEntry(
        _ entry: PackRegistryFile.PackEntry,
        ctx: PackCommandContext
    ) throws {
        var latest = try ctx.loadRegistry()
        ctx.registry.register(entry, in: &latest)
        try ctx.registry.save(latest)
    }

    // MARK: - Prompt priors

    /// The `values` of the entries routed to one scope, folded in manifest order. Sync merges them
    /// into that scope's `resolvedValues` and reuses them silently for keys a resolved pack declares
    /// as a prompt or references as a `__PLACEHOLDER__`; any other key is dropped.
    ///
    /// Returned rather than saved: sync merges them only after its removals,
    /// so pruning a removed pack's values can't take seeds meant for a pack being added.
    private func seedValues(
        from refs: [BootstrapFile.PackRef],
        scopeLabel: String,
        output: CLIOutput
    ) -> [String: String] {
        // Warn when a later pack overrides an earlier pack's value for the same key so the
        // divergence is visible. Values themselves stay out of the log: bootstrap `values`
        // commonly hold MCP env vars (API keys, tokens), and a CI log is a common secret-exfil path.
        var merged: [String: String] = [:]
        var seedCount = 0
        for pack in refs {
            for (key, value) in pack.values ?? [:] {
                seedCount += 1
                if let previous = merged[key], previous != value {
                    let file = BootstrapFile.defaultFilename
                    output.warn(
                        "Duplicate prompt key '\(key)' across packs in \(file)"
                            + " — using the later value (values hidden; prompts may hold secrets)"
                    )
                }
                merged[key] = value
            }
        }
        if dryRun, !merged.isEmpty {
            output.dimmed("  would seed \(seedCount) prompt value(s) into \(scopeLabel) state")
        }
        return merged
    }

    /// A seeded key nothing consumes is most likely a typo, and sync drops it without a
    /// trace while prompting for the key the pack actually expects.
    private func warnUnmatchedSeedKeys(
        refs: [BootstrapFile.PackRef],
        packs: [any TechPack],
        strategy: any SyncStrategy,
        output: CLIOutput
    ) {
        let file = BootstrapFile(schemaVersion: BootstrapFile.currentSchemaVersion, packs: refs)
        let context = strategy.makeConfigContext(output: output, resolvedValues: [:], priorValues: [:])
        for key in Self.unmatchedSeedKeys(
            file: file, packs: packs, context: context,
            includeTemplates: strategy.scope.includeTemplatesInScan
        ) {
            output.warn(
                "'\(key)' in \(BootstrapFile.defaultFilename) values matches no prompt or placeholder"
                    + " in the declared packs — ignored. Check it for a typo."
            )
        }
    }

    /// Seeded keys that no pack declares as a prompt or references as a `__PLACEHOLDER__`.
    /// Empty when a template can't be read, since its placeholders are then unknown.
    static func unmatchedSeedKeys(
        file: BootstrapFile,
        packs: [any TechPack],
        context: ProjectConfigContext,
        includeTemplates: Bool
    ) -> [String] {
        let seeded = Set(file.packs.flatMap { ($0.values ?? [:]).keys })
        guard !seeded.isEmpty else { return [] }

        var templatesUnreadable = false
        let consumed = CrossPackPromptResolver.consumedKeys(
            packs: packs,
            context: context,
            includeTemplates: includeTemplates,
            onWarning: { _ in templatesUnreadable = true }
        )
        guard !templatesUnreadable else { return [] }
        return seeded.subtracting(consumed.all).sorted()
    }

    // MARK: - Sync

    /// A declared entry and the registered pack identifier it resolved to.
    struct DeclaredPack {
        let identifier: String
        let ref: BootstrapFile.PackRef
    }

    /// The scope a declared pack converges in: the entry's `scope`, then the file's, then the
    /// pack's only declared scope, then project.
    static func route(_ ref: BootstrapFile.PackRef, fileScope: PackScope?, pack: any TechPack) -> PackScope {
        if let explicit = ref.packScope ?? fileScope {
            return explicit
        }
        if pack.supportedScopes.count == 1, let only = pack.supportedScopes.first {
            return only
        }
        return .project
    }

    private struct ScopePlan {
        let scope: PackScope
        let packs: [any TechPack]
        let refs: [BootstrapFile.PackRef]
        let keptExtras: [String]
        let state: ProjectState
        let configurator: Configurator
        let strategy: any SyncStrategy

        var removals: [String] {
            state.configuredPacks.subtracting(packs.map(\.identifier)).sorted()
        }
    }

    /// Converge every scope the declared packs route to, global first.
    ///
    /// Each scope is **additive by default**: packs configured there but absent from the file are
    /// kept. `--prune` makes the file authoritative for the project, and for global only when the
    /// file's own scope is `global` — one repo's file is never the full list of a user's global
    /// packs. Every check runs against both scopes before either changes.
    ///
    /// `allDeclaredResolved` is false on a dry run that skipped fetching new packs.
    /// Exposed as `internal` so integration tests can drive it without ArgumentParser + cwd.
    func runSync(
        declared: [DeclaredPack],
        fileScope: PackScope? = nil,
        allDeclaredResolved: Bool = true,
        projectRoot: URL,
        env: Environment,
        output: CLIOutput,
        shell: any ShellRunning,
        registry: TechPackRegistry,
        claudeCLI: (any ClaudeCLI)? = nil
    ) throws {
        let fileName = BootstrapFile.defaultFilename
        let routed = try route(declared, fileScope: fileScope, registry: registry, output: output)

        guard !declared.isEmpty else {
            if dryRun {
                // `installPacks` doesn't fetch on a dry run, so a file of only new packs has
                // nothing registered to preview beyond its "would fetch:" lines. Not a failure.
                output.plain("")
                output.info("No previously-registered packs to preview. Run without --dry-run to fetch and sync.")
                return
            }
            output.error("No packs from \(fileName) could be loaded.")
            throw ExitCode.failure
        }

        let globalEntries = routed[.global] ?? []
        let projectEntries = routed[.project] ?? []
        let prunesGlobal = prune && fileScope == .global
        let runsGlobal = !globalEntries.isEmpty || prunesGlobal
        let runsProject = fileScope != .global && (!projectEntries.isEmpty || prune)

        let globalState = try SyncCommand.loadGlobalState(env: env, output: output)
        var projectState: ProjectState?
        if fileScope != .global {
            do {
                projectState = try ProjectState(projectRoot: projectRoot)
            } catch {
                output.error("Corrupt .mcs-project: \(error.localizedDescription)")
                output.error("Delete .claude/.mcs-project and re-run 'mcs bootstrap'.")
                throw ExitCode.failure
            }
        }

        // A blocked scope skips the whole run: converging only the other one would leave the
        // file half-applied. Under prune the unloadable pack is what the run exists to remove.
        if runsGlobal, !prunesGlobal, SyncCommand.scopeIsBlockedByUnloadablePack(
            configured: globalState.configuredPacks, registry: registry, output: output
        ) {
            return
        }
        if runsProject, !prune, let projectState, SyncCommand.scopeIsBlockedByUnloadablePack(
            configured: projectState.configuredPacks, registry: registry, output: output
        ) {
            return
        }

        // Installing globally what this project also holds is the state `ScopeDuplicationCheck`
        // fails on. Under --prune the project run drops it, so the pack moves instead.
        let moving = globalEntries.map(\.pack)
            .filter { projectState?.configuredPacks.contains($0.identifier) == true }
        if !moving.isEmpty, !prune {
            output.error("\(fileName) routes these packs to global scope, but this project already configures them:")
            output.plain("  \(moving.map(\.displayName).sorted().joined(separator: ", "))")
            output.plain("  Run 'mcs bootstrap --prune' to move them, or remove them from this project first.")
            throw ExitCode.failure
        }

        func makeConfigurator(_ strategy: any SyncStrategy) -> Configurator {
            Configurator(
                environment: env, output: output, shell: shell,
                registry: registry, strategy: strategy, claudeCLI: claudeCLI
            )
        }

        var plans: [ScopePlan] = []
        if runsGlobal {
            let desired = try ConfiguratorSupport.additivePackSet(
                requested: globalEntries.map(\.pack),
                previouslyConfigured: globalState.configuredPacks,
                prune: prunesGlobal,
                pruneCommand: "mcs bootstrap --prune",
                registry: registry,
                output: output
            )
            let strategy = GlobalSyncStrategy(environment: env)
            plans.append(ScopePlan(
                scope: .global, packs: desired.packs, refs: globalEntries.map(\.ref),
                keptExtras: desired.keptExtras, state: globalState,
                configurator: makeConfigurator(strategy), strategy: strategy
            ))
        }
        if runsProject, let projectState {
            let desired = try ConfiguratorSupport.additivePackSet(
                requested: projectEntries.map(\.pack),
                previouslyConfigured: projectState.configuredPacks,
                prune: prune,
                pruneCommand: "mcs bootstrap --prune",
                registry: registry,
                output: output
            )
            // Under --prune the list only has to exclude what should go, so an empty result is
            // legitimate: the extras converge away as removals.
            let packs = try ConfiguratorSupport.filterGloballyBlocked(
                desired.packs,
                globallyInstalled: globalState.configuredPacks,
                previouslyConfigured: projectState.configuredPacks,
                output: output,
                allowEmpty: prune
            )
            let strategy = ProjectSyncStrategy(projectPath: projectRoot, environment: env)
            plans.append(ScopePlan(
                scope: .project, packs: packs, refs: projectEntries.map(\.ref),
                keptExtras: desired.keptExtras, state: projectState,
                configurator: makeConfigurator(strategy), strategy: strategy
            ))
        }

        var seeds: [PackScope: [String: String]] = [:]
        for plan in plans {
            if allDeclaredResolved {
                warnUnmatchedSeedKeys(refs: plan.refs, packs: plan.packs, strategy: plan.strategy, output: output)
            }
            seeds[plan.scope] = seedValues(from: plan.refs, scopeLabel: plan.scope.rawValue, output: output)
        }

        if !dryRun {
            for plan in plans {
                try plan.configurator.preflight(
                    packs: plan.packs, seededValues: seeds[plan.scope] ?? [:], reusePriorValuesSilently: true
                )
            }
            guard confirmRemovals(plans: plans, output: output) else {
                output.info("Bootstrap cancelled.")
                return
            }
        }

        for plan in plans {
            try converge(plan, seededValues: seeds[plan.scope] ?? [:], projectRoot: projectRoot, env: env, output: output)
        }
        if !dryRun {
            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }

        for plan in plans {
            ConfiguratorSupport.reportKeptExtras(
                plan.keptExtras,
                notIn: "in \(fileName)\(plan.scope == .global ? " (global)" : "")",
                remedy: plan.scope == .global && fileScope != .global
                    ? "Add them to \(fileName), or deselect them with 'mcs sync --global'."
                    : "Add them to \(fileName), or run 'mcs bootstrap --prune' to remove them.",
                output: output
            )
        }
    }

    private typealias RoutedEntry = (pack: any TechPack, ref: BootstrapFile.PackRef)

    /// Group declared packs by the scope they route to, failing on any pack that can't load or
    /// doesn't support its scope — before either scope is touched.
    private func route(
        _ declared: [DeclaredPack],
        fileScope: PackScope?,
        registry: TechPackRegistry,
        output: CLIOutput
    ) throws -> [PackScope: [RoutedEntry]] {
        var routed: [PackScope: [RoutedEntry]] = [:]
        var failures: [String] = []
        for entry in declared {
            guard let pack = registry.pack(for: entry.identifier) else {
                failures.append("Pack '\(entry.identifier)' declared in \(BootstrapFile.defaultFilename) failed to load.")
                continue
            }
            let target = Self.route(entry.ref, fileScope: fileScope, pack: pack)
            guard pack.supportedScopes.contains(target) else {
                let supported = PackScope.allCases.filter(pack.supportedScopes.contains).map(\.rawValue)
                failures.append(
                    "Pack '\(pack.displayName)' is routed to \(target.rawValue) scope"
                        + " but supports \(supported.joined(separator: ", ")) only."
                )
                continue
            }
            routed[target, default: []].append((pack, entry.ref))
        }
        guard failures.isEmpty else {
            for failure in failures {
                output.error(failure)
            }
            throw ExitCode.failure
        }
        return routed
    }

    private func converge(
        _ plan: ScopePlan,
        seededValues: [String: String],
        projectRoot: URL,
        env: Environment,
        output: CLIOutput
    ) throws {
        output.header(plan.scope == .global ? "Sync Global" : "Sync Project")
        output.plain("")
        if plan.scope == .global {
            output.info(label: "Target", env.claudeDirectory.path)
            output.warn("Global scope applies to every project on this machine.")
        } else {
            output.info(label: "Project", projectRoot.path)
        }
        output.info(label: "Packs", plan.packs.map(\.displayName).joined(separator: ", "))

        if dryRun {
            try plan.configurator.dryRun(packs: plan.packs, seededValues: seededValues)
        } else {
            // Seeded and stored values must not re-prompt behind the interactive Y/n gate;
            // prompts nothing answers still execute.
            try plan.configurator.configure(
                packs: plan.packs,
                confirmRemovals: false,
                reusePriorValuesSilently: true,
                seededValues: seededValues
            )
        }
    }

    /// One confirmation for every scope's removals, asked before any scope changes so declining
    /// never leaves one scope converged and the other not. `true` when there is nothing to confirm.
    private func confirmRemovals(plans: [ScopePlan], output: CLIOutput) -> Bool {
        let withRemovals = plans.filter { !$0.removals.isEmpty }
        guard prune, !yes, !withRemovals.isEmpty else { return true }

        output.plain("")
        for plan in withRemovals {
            output.warn("The following packs will be removed\(plan.strategy.scope.labelSuffix):")
            for packID in plan.removals {
                output.plain("  - \(packID)")
                if let artifacts = plan.state.artifacts(for: packID) {
                    plan.strategy.printRemovalSummary(artifacts, output: output)
                }
            }
        }
        output.plain("")
        return output.askYesNo("Proceed with removal?", default: true)
    }
}

// MARK: - PackSource helper

extension PackSource {
    /// String form used as the registry `sourceURL`.
    var referenceURL: String {
        switch self {
        case let .gitURL(url): url
        case let .localPath(path): path.path
        }
    }
}

// MARK: - Source display

/// Redact userinfo (`user:pass@`) from a URL-shaped source before it reaches the
/// terminal. HTTPS clone URLs for private repos commonly carry a token in the
/// userinfo component, and every bootstrap diagnostic ends up in CI logs.
///
/// Non-URL sources (GitHub shorthand `user/repo`, SSH `git@host:...`, absolute
/// paths) do not carry userinfo and pass through unchanged.
func redactSourceForDisplay(_ source: String) -> String {
    guard var comps = URLComponents(string: source),
          comps.user != nil || comps.password != nil
    else {
        return source
    }
    comps.user = nil
    comps.password = nil
    return comps.string ?? source
}
