import Foundation

/// Unified configuration engine for both project-scoped and global-scoped sync.
///
/// Implements the 12-phase convergence flow once, delegating scope-specific
/// behavior to a `SyncStrategy` (project or global). Data-level differences
/// (paths, flags) are captured in `SyncScope`.
struct Configurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var registry: TechPackRegistry = .shared
    let strategy: any SyncStrategy

    private var scope: SyncScope {
        strategy.scope
    }

    // MARK: - Interactive Flow

    /// Full interactive configure flow — multi-select of registered packs.
    ///
    /// - Parameter customize: When `true`, present per-pack component multi-select after pack selection.
    func interactiveConfigure(dryRun: Bool = false, customize: Bool = false) throws {
        output.header("Sync \(scope.label)")
        output.plain("")
        if scope.isGlobalScope {
            output.info("Target: \(scope.targetPath.path)")
        } else {
            output.info("Project: \(scope.targetPath.deletingLastPathComponent().path)")
        }

        let packs = registry.availablePacks
        guard !packs.isEmpty else {
            output.error("No packs registered. Run 'mcs pack add <url>' first.")
            return
        }

        let previousState = try ProjectState(stateFile: scope.stateFile)
        let previousPacks = previousState.configuredPacks

        let items = packs.enumerated().map { index, pack in
            SelectableItem(
                number: index + 1,
                name: pack.displayName,
                description: pack.description,
                isSelected: previousPacks.contains(pack.identifier)
            )
        }

        let groupTitle = scope.isGlobalScope ? "Tech Packs (Global)" : "Tech Packs"
        var groups = [SelectableGroup(
            title: groupTitle,
            items: items,
            requiredItems: []
        )]

        let selectedNumbers = output.multiSelect(groups: &groups)

        let selectedPacks = packs.enumerated().compactMap { index, pack in
            selectedNumbers.contains(index + 1) ? pack : nil
        }

        if selectedPacks.isEmpty, previousPacks.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing to configure.")
            return
        }

        var excludedComponents: [String: Set<String>] = [:]
        if customize, !selectedPacks.isEmpty {
            excludedComponents = ConfiguratorSupport.selectComponentExclusions(
                packs: selectedPacks,
                previousState: previousState,
                output: output
            )
        }

        if dryRun {
            try self.dryRun(packs: selectedPacks)
        } else {
            try configure(packs: selectedPacks, excludedComponents: excludedComponents)

            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }

    // MARK: - Dry Run

    /// Compute and display what `configure` would do, without making any changes.
    func dryRun(packs: [any TechPack]) throws {
        let state = try ProjectState(stateFile: scope.stateFile)
        let headerLabel = scope.isGlobalScope ? "Plan (Global)" : "Plan"
        ConfiguratorSupport.dryRunSummary(
            packs: packs,
            state: state,
            header: headerLabel,
            output: output,
            artifactSummary: { strategy.printArtifactSummary($0, output: output) },
            removalSummary: { strategy.printRemovalSummary($0, output: output) }
        )
    }

    // MARK: - Configure (Multi-Pack)

    /// Configure with the given set of packs.
    /// Handles convergence: adds new packs, updates existing, removes deselected.
    ///
    /// - Parameter confirmRemovals: When `true`, prompt the user before removing packs.
    ///   Pass `false` for non-interactive paths (`--pack`, `--all`).
    /// - Parameter excludedComponents: Component IDs excluded per pack (packID -> Set<componentID>).
    func configure(
        packs: [any TechPack],
        confirmRemovals: Bool = true,
        excludedComponents: [String: Set<String>] = [:]
    ) throws {
        let selectedIDs = Set(packs.map(\.identifier))

        var state = try ProjectState(stateFile: scope.stateFile)
        let previousIDs = state.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)

        // 1. Confirm and unconfigure removed packs
        if confirmRemovals, !removals.isEmpty {
            output.plain("")
            let suffix = scope.labelSuffix
            output.warn("The following packs will be removed\(suffix):")
            for packID in removals.sorted() {
                output.plain("  - \(packID)")
                if let artifacts = state.artifacts(for: packID) {
                    strategy.printRemovalSummary(artifacts, output: output)
                }
            }
            output.plain("")
            guard output.askYesNo("Proceed with removal?", default: true) else {
                output.info("Sync cancelled.")
                return
            }
        }

        for packID in removals.sorted() {
            unconfigurePack(packID, state: &state)
        }

        // 2. Auto-install global dependencies (project scope only — global handles inline)
        if !scope.isGlobalScope {
            for pack in packs {
                let excluded = excludedComponents[pack.identifier] ?? []
                autoInstallGlobalDependencies(pack, excludedIDs: excluded)
            }
        }

        // 3. Resolve all template/placeholder values upfront (single pass)
        // 3a. Built-in values (REPO_NAME, PROJECT_DIR_NAME in project scope)
        var allValues = strategy.resolveBuiltInValues(shell: shell, output: output)

        // 3b–3c. Detect shared prompts across packs and resolve them once.
        // `initialContext` uses partial resolvedValues (built-ins only). groupSharedPrompts
        // filters out already-resolved keys; current TechPack implementations only use
        // isGlobalScope from the context in declaredPrompts().
        let initialContext = strategy.makeConfigContext(output: output, resolvedValues: allValues)
        let sharedPrompts = CrossPackPromptResolver.groupSharedPrompts(
            packs: packs, context: initialContext
        )
        if !sharedPrompts.isEmpty {
            let sharedValues = CrossPackPromptResolver.resolveSharedPrompts(sharedPrompts, output: output)
            allValues.merge(sharedValues) { existing, _ in existing }
        }

        // 3d. Execute remaining per-pack prompts. templateValues() skips prompts whose key
        // already exists in context.resolvedValues (pre-resolved by shared prompt resolution).
        // Merge uses "first wins" — shared values and built-ins take precedence.
        let context = strategy.makeConfigContext(output: output, resolvedValues: allValues)
        for pack in packs {
            let packValues = try pack.templateValues(context: context)
            allValues.merge(packValues) { existing, _ in existing }
        }

        // 4. Auto-prompt for undeclared placeholders in pack files
        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: packs, resolvedValues: allValues,
            includeTemplates: scope.includeTemplatesInScan,
            onWarning: { output.warn($0) }
        )
        for key in undeclared {
            let value = output.promptInline("Set value for \(key)", default: nil)
            allValues[key] = value
        }

        // 4b. Persist resolved values for doctor freshness checks
        state.setResolvedValues(allValues)

        // 4c. Pre-load templates (single disk read per pack)
        var preloadedTemplates: [String: [TemplateContribution]] = [:]
        for pack in packs {
            do {
                preloadedTemplates[pack.identifier] = try pack.templates
            } catch {
                output.warn("Could not load templates for \(pack.displayName): \(error.localizedDescription)")
            }
        }

        // 5. Install artifacts per pack
        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            let isNew = additions.contains(pack.identifier)
            let label = isNew ? "Configuring" : "Updating"
            let suffix = scope.labelSuffix
            output.info("\(label) \(pack.displayName)\(suffix)...")
            let previousArtifacts = state.artifacts(for: pack.identifier)
            var exec = makeExecutor()
            let artifacts = strategy.installArtifacts(
                pack,
                previousArtifacts: previousArtifacts,
                excludedIDs: excluded,
                resolvedValues: allValues,
                preloadedTemplates: preloadedTemplates[pack.identifier],
                executor: &exec,
                shell: shell,
                output: output
            )
            state.setArtifacts(artifacts, for: pack.identifier)
            state.setExcludedComponents(excluded, for: pack.identifier)
            state.recordPack(pack.identifier)
        }

        // 5b. Intermediate state save
        try state.save()

        // 6. Compose settings file from ALL selected packs
        let contributedKeys = try strategy.composeSettings(
            packs: packs, excludedComponents: excludedComponents,
            resolvedValues: allValues, output: output
        )

        // 6b. Record contributed settings keys in artifact records
        for (packID, keys) in contributedKeys {
            if var artifacts = state.artifacts(for: packID) {
                artifacts.settingsKeys = keys
                state.setArtifacts(artifacts, for: packID)
            }
        }

        // 7. Compose CLAUDE markdown file
        let writtenSections = try strategy.composeClaude(
            packs: packs, preloadedTemplates: preloadedTemplates,
            values: allValues, output: output
        )

        // 7b. Reconcile template sections (global only — removes skipped sections from artifacts)
        if let writtenSections {
            for pack in packs {
                if var artifacts = state.artifacts(for: pack.identifier) {
                    let before = artifacts.templateSections.count
                    artifacts.templateSections = artifacts.templateSections.filter { writtenSections.contains($0) }
                    if artifacts.templateSections.count != before {
                        state.setArtifacts(artifacts, for: pack.identifier)
                    }
                }
            }
        }

        // 8. Run pack-specific configureProject hooks (project scope only)
        if scope.runConfigureProjectHooks {
            let hookContext = strategy.makeConfigContext(output: output, resolvedValues: allValues)
            let projectPath = scope.targetPath.deletingLastPathComponent()
            for pack in packs {
                try pack.configureProject(at: projectPath, context: hookContext)
            }
        }

        // 9. Ensure gitignore entries
        try ConfiguratorSupport.ensureGitignoreEntries(shell: shell)

        // 10. Final state save
        do {
            try state.save()
            output.success("Updated \(scope.stateFile.lastPathComponent)")
        } catch {
            output.error("Could not write \(scope.stateFile.lastPathComponent): \(error.localizedDescription)")
            output.error("State may be inconsistent. Re-run '\(scope.syncHint)' to recover.")
            throw MCSError.fileOperationFailed(
                path: scope.stateFile.path,
                reason: error.localizedDescription
            )
        }

        // 11. Update project index for cross-project tracking
        do {
            let indexFile = ProjectIndex(path: environment.projectsIndexFile)
            var indexData = try indexFile.load()
            indexFile.upsert(
                projectPath: scope.scopeIdentifier,
                packIDs: packs.map(\.identifier),
                in: &indexData
            )
            try indexFile.save(indexData)
        } catch {
            output.error("Could not update project index: \(error.localizedDescription)")
            output.error("Cross-project resource tracking may be inaccurate. Re-run '\(scope.syncHint)' to retry.")
        }
    }

    // MARK: - Pack Unconfiguration

    /// Remove all artifacts installed by a pack.
    ///
    /// - Parameters:
    ///   - packID: Identifier of the pack to remove.
    ///   - state: Project state to update (caller must save after return).
    ///   - refCountScope: Override scope identifier for reference counting.
    ///     Pass `ProjectIndex.packRemoveSentinel` when removing a pack from
    ///     all scopes (e.g. `mcs pack remove`) so the ref counter excludes
    ///     every scope. Defaults to `nil` (uses `scope.scopeIdentifier`).
    func unconfigurePack(
        _ packID: String,
        state: inout ProjectState,
        refCountScope: String? = nil
    ) {
        let suffix = scope.labelSuffix
        output.info("Removing \(packID)\(suffix)...")
        let exec = makeExecutor()

        guard let artifacts = state.artifacts(for: packID) else {
            output.dimmed("No artifact record for \(packID) — skipping")
            state.removePack(packID)
            return
        }

        var remaining = artifacts
        var removedServers: Set<MCPServerRef> = []

        // Remove MCS-owned brew packages and plugins (with reference counting)
        let excludeScope = refCountScope ?? scope.scopeIdentifier
        let refCounter = ResourceRefCounter(
            environment: environment,
            output: output,
            registry: registry
        )
        for package in artifacts.brewPackages {
            if refCounter.isStillNeeded(
                .brewPackage(package),
                excludingScope: excludeScope,
                excludingPack: packID
            ) {
                output.dimmed("  Keeping brew package '\(package)' — still needed by another scope")
            } else {
                if exec.uninstallBrewPackage(package) {
                    output.dimmed("  Removed brew package: \(package)")
                }
            }
        }
        remaining.brewPackages = []

        for pluginName in artifacts.plugins {
            if refCounter.isStillNeeded(
                .plugin(pluginName),
                excludingScope: excludeScope,
                excludingPack: packID
            ) {
                output.dimmed("  Keeping plugin '\(PluginRef(pluginName).bareName)' — still needed by another scope")
            } else {
                if exec.removePlugin(pluginName) {
                    output.dimmed("  Removed plugin: \(PluginRef(pluginName).bareName)")
                }
            }
        }
        remaining.plugins = []

        // Remove MCP servers
        for server in artifacts.mcpServers
            where exec.removeMCPServer(name: server.name, scope: server.scope) {
            removedServers.insert(server)
            output.dimmed("  Removed MCP server: \(server.name)")
        }
        remaining.mcpServers.removeAll { removedServers.contains($0) }

        // Remove files via strategy (project vs global have different removal logic)
        var removedFiles: Set<String> = []
        for path in artifacts.files
            where strategy.removeFileArtifact(relativePath: path, output: output) {
            removedFiles.insert(path)
        }
        remaining.files.removeAll { removedFiles.contains($0) }

        // Remove auto-derived hook commands and contributed settings keys
        let hasHooksToRemove = !artifacts.hookCommands.isEmpty
        let hasSettingsToRemove = !artifacts.settingsKeys.isEmpty
        if hasHooksToRemove || hasSettingsToRemove {
            var settings: Settings
            do {
                settings = try Settings.load(from: scope.settingsPath)
            } catch {
                output.warn("Could not parse \(scope.settingsPath.lastPathComponent): \(error.localizedDescription)")
                output.warn("Settings for \(packID) were not cleaned up. Fix the file and re-run.")
                state.setArtifacts(remaining, for: packID)
                output.warn("Some artifacts for \(packID) could not be removed. Re-run '\(scope.syncHint)' to retry.")
                return
            }
            if hasHooksToRemove {
                let commandsToRemove = Set(artifacts.hookCommands)
                if var hooks = settings.hooks {
                    for (event, groups) in hooks {
                        hooks[event] = groups.filter { group in
                            guard let cmd = group.hooks?.first?.command else { return true }
                            return !commandsToRemove.contains(cmd)
                        }
                    }
                    hooks = hooks.filter { !$0.value.isEmpty }
                    settings.hooks = hooks.isEmpty ? nil : hooks
                }
            }
            if hasSettingsToRemove {
                settings.removeKeys(artifacts.settingsKeys)
            }
            do {
                let dropKeys = Set(artifacts.settingsKeys.filter { !$0.contains(".") })
                try settings.save(to: scope.settingsPath, dropKeys: dropKeys)
                remaining.hookCommands = []
                remaining.settingsKeys = []
                for cmd in artifacts.hookCommands {
                    output.dimmed("  Removed hook: \(cmd)")
                }
                for key in artifacts.settingsKeys {
                    output.dimmed("  Removed setting: \(key)")
                }
            } catch {
                output.warn("Could not write \(scope.settingsPath.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Remove template sections from CLAUDE file
        if !artifacts.templateSections.isEmpty {
            let claudePath = scope.claudeFilePath
            if !FileManager.default.fileExists(atPath: claudePath.path) {
                remaining.templateSections = []
                output.dimmed("  \(claudePath.lastPathComponent) not found — clearing template section records")
            } else {
                do {
                    let content = try String(contentsOf: claudePath, encoding: .utf8)
                    var updated = content
                    for sectionID in artifacts.templateSections {
                        updated = TemplateComposer.removeSection(in: updated, sectionIdentifier: sectionID)
                    }
                    if updated != content {
                        try updated.write(to: claudePath, atomically: true, encoding: .utf8)
                        for sectionID in artifacts.templateSections {
                            output.dimmed("  Removed template section: \(sectionID)")
                        }
                    } else {
                        output.dimmed("  Template sections already absent from \(claudePath.lastPathComponent)")
                    }
                    remaining.templateSections = []
                } catch {
                    output.warn("Could not update \(claudePath.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        // Remove gitignore entries
        if !artifacts.gitignoreEntries.isEmpty {
            let gitignoreManager = GitignoreManager(shell: shell)
            var removedEntries: Set<String> = []
            for entry in artifacts.gitignoreEntries {
                do {
                    try gitignoreManager.removeEntry(entry)
                    removedEntries.insert(entry)
                    output.dimmed("  Removed gitignore entry: \(entry)")
                } catch {
                    output.warn("Could not remove gitignore entry '\(entry)': \(error.localizedDescription)")
                }
            }
            remaining.gitignoreEntries.removeAll { removedEntries.contains($0) }
        }

        if remaining.isEmpty {
            state.removePack(packID)
        } else {
            state.setArtifacts(remaining, for: packID)
            output.warn("Some artifacts for \(packID) could not be removed. Re-run '\(scope.syncHint)' to retry.")
        }
    }

    // MARK: - Global Dependencies

    /// Auto-install brew packages and plugins (project scope only).
    private func autoInstallGlobalDependencies(_ pack: any TechPack, excludedIDs: Set<String> = []) {
        let exec = makeExecutor()
        for component in pack.components {
            guard !excludedIDs.contains(component.id) else { continue }
            guard !ComponentExecutor.isAlreadyInstalled(component) else { continue }

            switch component.installAction {
            case let .brewInstall(package):
                output.dimmed("  Installing \(component.displayName)...")
                _ = exec.installBrewPackage(package)
            case let .plugin(name):
                output.dimmed("  Installing plugin \(component.displayName)...")
                _ = exec.installPlugin(name)
            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func makeExecutor() -> ComponentExecutor {
        ConfiguratorSupport.makeExecutor(environment: environment, output: output, shell: shell)
    }
}
