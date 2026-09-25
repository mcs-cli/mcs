import Foundation

/// Converges a scope onto the packs it already has configured. Shared by `mcs update` and
/// `mcs doctor --fix`, neither of which ever changes which packs a scope holds.
enum ScopeReapplier {
    /// Re-apply every scope in order and return the labels of those whose prompts could not
    /// be resolved. One scope's unanswerable prompt must not strand every scope after it
    /// unrefreshed, so that failure is reported and the loop moves on; any other error aborts.
    static func reapplyScopes(
        _ runs: [UpdateScopeResolver.ScopeRun],
        skippedPackIDs: Set<String>,
        registry: TechPackRegistry,
        dryRun: Bool,
        env: Environment,
        shell: any ShellRunning,
        output: CLIOutput,
        claudeCLI: (any ClaudeCLI)? = nil
    ) throws -> [String] {
        var unresolvedScopes: [String] = []
        for run in runs {
            do {
                try reapplyScope(
                    run,
                    skippedPackIDs: skippedPackIDs,
                    registry: registry,
                    dryRun: dryRun,
                    env: env,
                    shell: shell,
                    output: output,
                    claudeCLI: claudeCLI
                )
            } catch let error as PromptResolutionError {
                error.lines.forEach { output.error($0) }
                unresolvedScopes.append(run.label)
            }
        }
        return unresolvedScopes
    }

    /// Print one scope's header, resolve its configured packs, and converge the scope onto them.
    /// Returns `true` when the scope was left untouched — `mcs update` discards it; `doctor --fix`
    /// and integration tests read it to tell a skipped scope from a re-synced one.
    ///
    /// The list must stay the scope's own configured set: `Configurator.configure` treats it
    /// as the complete desired state and unconfigures anything missing, with no prompt here.
    @discardableResult
    static func reapplyScope(
        _ run: UpdateScopeResolver.ScopeRun,
        skippedPackIDs: Set<String>,
        registry: TechPackRegistry,
        dryRun: Bool,
        env: Environment,
        shell: any ShellRunning,
        output: CLIOutput,
        claudeCLI: (any ClaudeCLI)? = nil
    ) throws -> Bool {
        output.header(run.label)

        // Any pack this run cannot produce blocks the *whole* scope: `configure` treats its list
        // as the complete desired state, so a shorter one silently unconfigures the rest (#382).
        // Nothing here is a deselection — unlike `mcs sync` — so an unregistered pack blocks too.
        let notUpdated = run.configuredPackIDs.intersection(skippedPackIDs)
        let unloadable = Set(registry.unloadableConfiguredPacks(configured: run.configuredPackIDs))
            .subtracting(notUpdated)
        let unregistered = run.configuredPackIDs
            .subtracting(registry.availablePackIDs)
            .subtracting(notUpdated)
            .subtracting(unloadable)

        if !notUpdated.isEmpty || !unloadable.isEmpty || !unregistered.isEmpty {
            for identifier in notUpdated.sorted() {
                output.warn("  \(identifier): update did not complete — re-run 'mcs update'.")
            }
            for identifier in unloadable.sorted() {
                output.warn("  \(identifier): failed to load — run 'mcs pack update \(identifier)'.")
            }
            for identifier in unregistered.sorted() {
                output.warn("  \(identifier): tracked in state but missing from the pack registry — run 'mcs pack add' to restore it.")
            }
            output.warn("  Skipping re-apply for this scope so no artifacts are removed.")
            return true
        }

        let packs = run.configuredPackIDs.sorted().compactMap { registry.pack(for: $0) }

        guard !packs.isEmpty else {
            output.info("No packs to refresh in this scope.")
            return true
        }

        let configurator = Configurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry,
            strategy: run.strategy,
            claudeCLI: claudeCLI
        )

        if dryRun {
            try configurator.dryRun(packs: packs)
        } else {
            try configurator.configure(
                packs: packs,
                confirmRemovals: false,
                excludedComponents: run.excludedComponents,
                reusePriorValuesSilently: true
            )
        }
        return false
    }
}
