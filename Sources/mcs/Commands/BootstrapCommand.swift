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

    @Flag(name: .long, help: "Trust declared packs without prompting (no TTY required)")
    var trustAll: Bool = false

    var skipLock: Bool {
        dryRun
    }

    /// Shared by both trust surfaces bootstrap can reach: a fresh `PackAdder.add` and a
    /// `ref:` advance through `PackUpdater`. Auto-accepting only the first leaves the second
    /// prompting whenever an advanced `ref:` brings new or changed scripts.
    var trustPolicy: PackTrustManager.TrustPolicy {
        trustAll ? .autoAccept : .prompt
    }

    func perform() throws {
        // Dry-run must not mutate `~/.mcs` state or trigger the Homebrew install prompt
        // for Claude Code — both would violate the no-changes contract on a preview.
        let ctx = PackCommandContext(initializeTelemetry: !dryRun)
        defer {
            if !dryRun { MCSAnalytics.trackCommand(.bootstrap) }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try guardCwd(cwd: cwd, env: ctx.env, output: ctx.output)

        if !dryRun {
            guard ensureClaudeCLI(shell: ctx.shell, environment: ctx.env, output: ctx.output) else {
                throw ExitCode.failure
            }
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
        ctx.output.info(label: "Packs", file.packs.map { redactSourceForDisplay($0.source) }.joined(separator: ", "))

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
        // Bootstrap is non-interactive by design: mcs.yaml already expresses the user's
        // intent, so identifier duplicates and artifact collisions must not fall through
        // to askYesNo (which blocks in CI and defeats the declarative contract).
        let bootstrapOptions = PackAdder.Options(
            duplicatePolicy: .autoAccept,
            showNextSteps: false,
            trustPolicy: trustPolicy
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

        var identifiers: [String] = []
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
                printDryRunLine(existing: existing, packSource: packSource, pack: pack, output: ctx.output)
                if let existing { identifiers.append(existing.identifier) }
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
                identifiers.append(existing.identifier)
                continue
            }

            do {
                if let existing {
                    let reconciled = try reconcileExistingGitPack(
                        existing: existing,
                        pack: pack,
                        ctx: ctx
                    )
                    identifiers.append(reconciled.identifier)
                    installedThisRun.append(reconciled.identifier)
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
                        identifiers.append(entry.identifier)
                        installedThisRun.append(entry.identifier)
                    case .declined:
                        // Bootstrap auto-accepts duplicates and collisions, so trust is the
                        // only thing `.declined` can mean here.
                        ctx.output.error("Bootstrap aborted: pack '\(displaySource)' was not added.")
                        hintTrustAllIfUnattended(output: ctx.output)
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
                reportPartialInstall(installed: installedThisRun, failedAt: pack.source, output: ctx.output)
                throw error
            }
        }

        return identifiers
    }

    /// Render the per-pack dry-run line. Existing packs get a dimmed "already
    /// registered" line; new packs distinguish local (registered in place) from
    /// git (would be cloned).
    private func printDryRunLine(
        existing: PackRegistryFile.PackEntry?,
        packSource: PackSource,
        pack: BootstrapFile.PackRef,
        output: CLIOutput
    ) {
        let displaySource = redactSourceForDisplay(pack.source)
        if existing != nil {
            output.dimmed("  already registered: \(displaySource)")
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

    /// Off a TTY the trust prompt takes its `false` default, so a decline reads as "the user
    /// said no" when it may mean there was nobody to ask. Redirected stdin carrying a real "n"
    /// is equally off-TTY, though, so the hint offers the possibility rather than asserting it.
    private func hintTrustAllIfUnattended(output: CLIOutput) {
        guard !output.hasInteractiveStdin, !trustAll else { return }
        output.plain("  If no terminal was available to answer the trust prompt, pass")
        output.plain("  --trust-all to approve declared packs without review.")
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
    /// `PackUpdater`-driven ref advance. Local packs never reach this path (they're
    /// handled inline in `installPacks`).
    private func reconcileExistingGitPack(
        existing: PackRegistryFile.PackEntry,
        pack: BootstrapFile.PackRef,
        ctx: PackCommandContext
    ) throws -> PackRegistryFile.PackEntry {
        if existing.ref == pack.ref {
            let display = redactSourceForDisplay(pack.source)
            ctx.output.dimmed("  \(display) already registered\(pack.ref.map { "@\($0)" } ?? "")")
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
            trustManager: PackTrustManager(output: ctx.output, policy: trustPolicy),
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
            hintTrustAllIfUnattended(output: ctx.output)
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

    /// Merge the bootstrap file's `values` into `state.resolvedValues`. Values whose
    /// key matches a prompt declared by one of the resolved packs are reused silently
    /// on sync. Keys that no pack declares (either because the key is a typo or because
    /// the pack references it only as a `__PLACEHOLDER__` in a file) currently fall
    /// through to the undeclared-placeholder scan and re-prompt — tracked in the
    /// follow-up issue for `values:` handling of undeclared placeholders.
    private func seedPromptValues(
        file: BootstrapFile,
        state: inout ProjectState,
        output: CLIOutput
    ) throws {
        // Fold in manifest order; warn when a later pack overrides an earlier pack's
        // value for the same key so the divergence is visible. Values themselves stay
        // out of the log: bootstrap `values` commonly hold MCP env vars (API keys,
        // tokens), and a CI log is a common secret-exfil path.
        var merged: [String: String] = [:]
        var seedCount = 0
        for pack in file.packs {
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
        guard !merged.isEmpty else { return }

        if dryRun {
            output.dimmed("  would seed \(seedCount) prompt value(s) into project state")
            return
        }

        var current = state.resolvedValues ?? [:]
        for (key, value) in merged {
            current[key] = value
        }
        state.setResolvedValues(current)
        // Failing to persist priors is not recoverable: the declarative contract is that
        // sync will not re-prompt for these keys, and that depends on the priors reaching
        // disk. Surface the failure and abort.
        do {
            try state.save()
        } catch {
            output.error("Failed to seed prompt values: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    // MARK: - Sync

    /// Run project sync for the declared pack set.
    ///
    /// **Default is additive**: any pack configured in the project but absent from
    /// `mcs.yaml` is preserved (its identifier is unioned into the desired set).
    /// `--prune` opts into authoritative behavior — declared IDs become the exact
    /// desired set, and `Configurator.configure(confirmRemovals: !yes)` prompts
    /// before removing anything.
    ///
    /// Exposed as `internal` so integration tests can exercise the additive-vs-prune
    /// branching without spinning up the whole command via ArgumentParser + cwd.
    func runSync(
        projectRoot: URL,
        desiredIdentifiers: [String],
        projectState: ProjectState,
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry
    ) throws {
        // --prune is the authoritative-removal path: the user has explicitly asked to
        // converge the scope, so an unloadable configured pack is what --prune exists
        // to clean up. The downstream `declaredUnresolved` check still blocks a
        // declared pack that fails to load, so bad declarations don't sneak through.
        if !prune, SyncCommand.scopeIsBlockedByUnloadablePack(
            configured: projectState.configuredPacks, registry: registry, output: output
        ) {
            return
        }

        let globalState = try SyncCommand.loadGlobalState(env: env, output: output)

        let declaredIDs = Set(desiredIdentifiers)
        let previouslyConfigured = projectState.configuredPacks
        let extras = previouslyConfigured.subtracting(declaredIDs)

        // Additive default: union declared with the packs already configured here so
        // nothing gets unconfigured. `--prune` collapses back to authoritative.
        // `desiredIdentifiers` is already unique — `BootstrapFile.validate()` rejects
        // duplicate sources and `installPacks` emits one identifier per source.
        let effectiveIDs = prune
            ? desiredIdentifiers
            : desiredIdentifiers + extras.sorted()

        let resolvedPacks: [any TechPack] = effectiveIDs.compactMap { registry.pack(for: $0) }
        let resolvedIDs = Set(resolvedPacks.map(\.identifier))
        let unresolved = Set(effectiveIDs).subtracting(resolvedIDs)

        // Declared IDs that fail to load are hard errors either way. An extra that no
        // longer resolves is only safe to skip under --prune; otherwise
        // Configurator.configure would treat it as a deselection and silently
        // unconfigure it.
        var mustAbort = false
        for id in unresolved.sorted() {
            if declaredIDs.contains(id) {
                output.error("Pack '\(id)' declared in \(BootstrapFile.defaultFilename) failed to load.")
                mustAbort = true
            } else if prune {
                output.warn("Pack '\(id)' has no registry entry — will be unconfigured (--prune).")
            } else {
                output.error("Pack '\(id)' is configured in this project but missing from the registry.")
                output.plain("  Re-add it with 'mcs pack add', or run 'mcs bootstrap --prune' to remove it.")
                mustAbort = true
            }
        }
        if mustAbort { throw ExitCode.failure }

        guard !resolvedPacks.isEmpty else {
            if dryRun {
                // Fresh project whose manifest is only new packs — `installPacks` in
                // dry-run mode does not fetch, so there are no registered identifiers
                // to preview beyond the "would fetch:" lines already printed. Not a
                // failure.
                output.plain("")
                output.info("No previously-registered packs to preview. Run without --dry-run to fetch and sync.")
                return
            }
            output.error("No packs from \(BootstrapFile.defaultFilename) could be loaded.")
            throw ExitCode.failure
        }

        // Under --prune, the sync's `packs` argument doesn't have to hold the
        // "keep" set — it just has to *not* hold anything we want removed. If every
        // declared pack is already globally installed and the project still has
        // extras, filterGloballyBlocked would normally refuse; here we want the
        // prune pass to run against the empty declared set so the extras converge
        // away as Configurator.configure removals.
        let filteredPacks = try ConfiguratorSupport.filterGloballyBlocked(
            resolvedPacks,
            globallyInstalled: globalState.configuredPacks,
            previouslyConfigured: previouslyConfigured,
            output: output,
            allowEmpty: prune
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
            // seedPromptValues already answered every declared prompt — the
            // interactive Y/n gate would contradict that. New prompts still execute.
            try configurator.configure(
                packs: filteredPacks,
                confirmRemovals: !yes,
                excludedComponents: projectState.allExcludedComponents,
                reusePriorValuesSilently: true
            )
            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }

        if !prune, !extras.isEmpty {
            printAdditiveDivergenceNote(extras: extras, output: output)
        }
    }

    /// Post-sync footer emitted after an additive bootstrap when the project holds
    /// packs that aren't in `mcs.yaml`. Non-blocking — an informational report so
    /// users see the divergence without a wall-style prompt.
    private func printAdditiveDivergenceNote(extras: Set<String>, output: CLIOutput) {
        output.plain("")
        output.info("\(extras.count) pack(s) are configured in this project but not in \(BootstrapFile.defaultFilename):")
        for id in extras.sorted() {
            output.plain("  - \(id)")
        }
        output.plain("  Add them to \(BootstrapFile.defaultFilename), or run 'mcs bootstrap --prune' to remove them.")
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
