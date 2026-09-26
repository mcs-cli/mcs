import Foundation

/// Outcome tallies from a doctor run, captured at summary time.
struct DoctorSummary {
    let passed: Int
    let warnings: Int
    let issues: Int
    var remainingIssues: Int
    let hasUnloadedFilteredPack: Bool

    var isHealthy: Bool {
        remainingIssues == 0 && !hasUnloadedFilteredPack
    }
}

/// Orchestrates all doctor checks grouped by section, with optional fix mode.
///
/// **Scope of `--fix`**: a check's own cleanup or repair, or a re-sync of the scope a failed
/// check belongs to. See CoreDoctorChecks.swift header for the full responsibility boundary.
struct DoctorRunner {
    let fixMode: Bool
    /// Skip the confirmation prompt before executing fixes (e.g. `--yes` flag).
    let skipConfirmation: Bool
    /// Explicit pack filter. If nil, uses packs from project state or pack registry.
    let packFilter: String?

    /// `packFilter` split into identifiers, so the comma convention is defined in one place.
    ///
    /// Entries are trimmed and empties dropped: `--pack "ios, swift"` is a natural thing to type,
    /// and an untrimmed `" swift"` matches no pack — the run would just report it as unregistered.
    private var packFilterIDs: Set<String>? {
        packFilter.map {
            Set(
                $0.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
    }

    /// When true, check only globally-configured packs (ignores project scope).
    let globalOnly: Bool
    let registry: TechPackRegistry

    /// Counts every warning emitted through `output`, including advisories shown
    /// outside the check loop (collision renames, unregistered packs, unreadable
    /// state) so the summary tally is faithful to what the user saw.
    private let warningCounter = WarningCounter()
    private let output: CLIOutput
    private var passCount = 0
    private var failCount = 0
    private var fixedCount = 0
    /// Failed checks collected during diagnosis, to be fixed after confirmation.
    private var pendingFixes: [CollectedCheck] = []
    private let shell: any ShellRunning
    private let claudeCLI: (any ClaudeCLI)?

    private enum SyncTarget: Hashable {
        case global
        case project(URL)

        var projectRoot: URL? {
            if case let .project(root) = self { return root }
            return nil
        }

        var label: String {
            projectRoot.map { "project \($0.lastPathComponent)" } ?? "the global scope"
        }
    }

    /// `syncTarget` is nil when a re-sync cannot make the check pass: checks a pack author wrote,
    /// standalone checks, and anything sync does not install.
    private typealias CollectedCheck = (check: any DoctorCheck, syncTarget: SyncTarget?)

    /// A resolved scope for check collection. Each scope carries the pack IDs,
    /// effective project root, and a display label.
    private struct CheckScope {
        let packIDs: Set<String>
        let effectiveProjectRoot: URL?
        let label: String
        let artifactsByPack: [String: PackArtifactRecord]
        /// False when the scope's packs are not all configured where it points, so a re-sync there
        /// would converge the wrong packs (`--pack` names a global-only pack from inside a project).
        var canResync = true

        var syncTarget: SyncTarget? {
            guard canResync else { return nil }
            return effectiveProjectRoot.map(SyncTarget.project) ?? .global
        }

        /// Hook directory the commands in `artifactsByPack` were recorded with.
        ///
        /// Relies on an invariant every `CheckScope` construction path upholds: a non-nil
        /// `effectiveProjectRoot` means the records came from project state, which sync wrote
        /// with the project prefix. Global-only packs get their own scope rather than being
        /// folded into a project one, so the two never mix.
        var hookPathPrefix: String {
            effectiveProjectRoot != nil
                ? Constants.HookCommand.projectDirectory
                : Constants.HookCommand.globalDirectory
        }

        func makeCollisionContext(environment: Environment) -> (any CollisionFilesystemContext)? {
            let trackedFiles = PackArtifactRecord.allTrackedFiles(from: artifactsByPack.values)
            if let root = effectiveProjectRoot {
                return ProjectCollisionContext(projectPath: root, trackedFiles: trackedFiles)
            }
            return GlobalCollisionContext(environment: environment, trackedFiles: trackedFiles)
        }
    }

    let environment: Environment
    let projectRootOverride: URL?

    init(
        fixMode: Bool,
        skipConfirmation: Bool = false,
        packFilter: String? = nil,
        globalOnly: Bool = false,
        registry: TechPackRegistry,
        environment: Environment = Environment(),
        projectRootOverride: URL? = nil,
        shell: (any ShellRunning)? = nil,
        claudeCLI: (any ClaudeCLI)? = nil
    ) {
        self.fixMode = fixMode
        self.skipConfirmation = skipConfirmation
        self.packFilter = packFilter
        self.globalOnly = globalOnly
        self.registry = registry
        self.environment = environment
        self.projectRootOverride = projectRootOverride
        self.shell = shell ?? ShellRunner(environment: environment)
        self.claudeCLI = claudeCLI
        output = CLIOutput(warningCounter: warningCounter)
    }

    @discardableResult
    mutating func run() throws -> DoctorSummary {
        output.header("Managed Claude Stack — Doctor")

        let env = environment
        let registry = registry

        // Resolve globally-configured pack IDs from global state.
        // This reflects packs actively synced to the global scope, not just
        // registered (available) packs. A pack in registry.yaml but not in
        // global-state.json's configuredPacks has been unsynced and shouldn't
        // trigger doctor checks.
        let globallyConfiguredPackIDs: Set<String>
        let globalArtifactsByPack: [String: PackArtifactRecord]
        do {
            let globalState = try ProjectState(stateFile: env.globalStateFile)
            if globalState.exists {
                // Global state file exists — use its configured packs (may be empty)
                globallyConfiguredPackIDs = globalState.configuredPacks
                var artifacts: [String: PackArtifactRecord] = [:]
                for packID in globalState.configuredPacks {
                    if let record = globalState.artifacts(for: packID) {
                        artifacts[packID] = record
                    }
                }
                globalArtifactsByPack = artifacts
            } else {
                // No global state file yet — fall back to registry for backward compat
                globalArtifactsByPack = [:]
                let packRegistry = PackRegistryFile(path: env.packsRegistry)
                do {
                    globallyConfiguredPackIDs = try Set((packRegistry.load()).packs.map(\.identifier))
                } catch {
                    output.warn("Could not read pack registry: \(error.localizedDescription) — no packs will be checked")
                    globallyConfiguredPackIDs = []
                }
            }
        } catch {
            // Corrupt state file — fall back to registry
            globalArtifactsByPack = [:]
            output.warn("Could not read global state: \(error.localizedDescription) — falling back to pack registry")
            let packRegistry = PackRegistryFile(path: env.packsRegistry)
            do {
                globallyConfiguredPackIDs = try Set((packRegistry.load()).packs.map(\.identifier))
            } catch {
                output.warn("Could not read pack registry: \(error.localizedDescription) — no packs will be checked")
                globallyConfiguredPackIDs = []
            }
        }

        // Detect project root
        let projectRoot = projectRootOverride ?? ProjectDetector.findProjectRoot()

        // Resolve check scopes (project, global, or both)
        let scopes = resolveCheckScopes(
            projectRoot: projectRoot,
            globallyConfiguredPackIDs: globallyConfiguredPackIDs,
            globalArtifactsByPack: globalArtifactsByPack
        )

        // Display resolved packs per scope
        for scope in scopes {
            if !scope.packIDs.isEmpty {
                output.dimmed("Packs (\(scope.label)): \(scope.packIDs.sorted().joined(separator: ", "))")
            } else {
                output.dimmed("No packs detected (\(scope.label))")
            }
        }

        // === Layered check collection ===

        var allChecks: [CollectedCheck] = []
        var allPackIDs = Set<String>()
        let availablePacks = registry.availablePacks

        // Warn for pack IDs that produced no pack — unconditional, not just under `--pack`: the
        // scope line above lists the ID either way, so a pack that failed to load would otherwise
        // be skipped in silence. The cause is not determined here, so the message names both.
        let availableIDs = registry.availablePackIDs
        var hasUnloadedFilteredPack = false
        for scope in scopes {
            for id in scope.packIDs.sorted() where !availableIDs.contains(id) {
                output.warn("Pack \"\(id)\" is not registered or failed to load \u{2014} no checks will be run for it")
                // A pack the caller named explicitly would otherwise read as healthy; inferred ones only warn.
                if packFilter != nil {
                    hasUnloadedFilteredPack = true
                }
            }
        }

        // Layer 1+2: Derived + supplementary checks from installed components (per scope)
        for scope in scopes {
            allPackIDs.formUnion(scope.packIDs)

            let scopePacks = DestinationCollisionResolver.resolveCollisions(
                packs: availablePacks.filter { scope.packIDs.contains($0.identifier) },
                output: output, filesystemContext: scope.makeCollisionContext(environment: env)
            )

            // Derived and artifact-record checks verify what sync installs or recorded, so a re-sync
            // can repair them. Pack-authored checks can assert anything, so they never trigger one.
            for pack in scopePacks {
                for component in pack.components {
                    if let derived = component.deriveDoctorCheck(projectRoot: scope.effectiveProjectRoot, environment: env) {
                        allChecks.append((check: derived, syncTarget: scope.syncTarget))
                    }
                    allChecks += component.supplementaryChecks(scope.effectiveProjectRoot, env)
                        .map { (check: $0, syncTarget: nil) }
                }
                allChecks += pack.supplementaryDoctorChecks(projectRoot: scope.effectiveProjectRoot)
                    .map { (check: $0, syncTarget: nil) }

                if let artifacts = scope.artifactsByPack[pack.identifier] {
                    allChecks += artifactChecks(for: artifacts, pack: pack, scope: scope, env: env)
                }
            }
        }

        // Layers 3-5: Standalone and project-scoped checks (scope-independent)
        var nonComponentChecks: [any DoctorCheck] = []
        nonComponentChecks += standaloneDoctorChecks()
        if !globalOnly, let root = projectRoot {
            // Only add project-scoped checks if mcs was used in this project
            let claudeLocalExists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(Constants.FileNames.claudeLocalMD).path
            )
            let mcsProjectExists = FileManager.default.fileExists(
                atPath: root.appendingPathComponent(Constants.FileNames.claudeDirectory)
                    .appendingPathComponent(Constants.FileNames.mcsProject).path
            )
            if claudeLocalExists || mcsProjectExists {
                let context = ProjectDoctorContext(projectRoot: root, registry: registry)
                nonComponentChecks += ProjectDoctorChecks.checks(context: context)
            }
            // Packs configured in this project *and* globally. Self-skips when no global
            // scope exists, so it costs nothing on machines that never ran `--global`.
            nonComponentChecks += ScopeDuplicationCheck.checks(
                projectRoot: root,
                registry: registry,
                environment: env,
                packFilter: packFilterIDs
            )
        }

        // Global-scoped template freshness check (always runs, self-skips if no global CLAUDE.md)
        nonComponentChecks.append(CLAUDEMDFreshnessCheck(
            fileURL: env.globalClaudeMD,
            stateLoader: { try ProjectState(stateFile: env.globalStateFile) },
            registry: registry,
            displayName: "CLAUDE.md freshness (global)",
            syncHint: "mcs sync --global"
        ))

        allChecks += nonComponentChecks.map { (check: $0, syncTarget: nil) }

        // Group by section
        let grouped = Dictionary(grouping: allChecks, by: \.check.section)
        let sectionOrder = [
            "Dependencies", "MCP Servers", "Plugins", "Skills", "Commands",
            "Hooks", "Installed Files", "Settings", "Gitignore", "Project", "Templates",
        ]

        for section in sectionOrder {
            guard let checks = grouped[section], !checks.isEmpty else { continue }
            output.header(section)
            runChecks(checks)
        }

        // Also run checks for any sections not in the predefined order
        for (section, checks) in grouped where !sectionOrder.contains(section) {
            output.header(section)
            runChecks(checks)
        }

        // Summary (before fixes, so the user sees the full picture first).
        // Fix-phase warnings (below) must not alter the reported total; only `remainingIssues` updates after fixes.
        var summary = DoctorSummary(
            passed: passCount,
            warnings: warningCounter.count,
            issues: failCount,
            remainingIssues: failCount,
            hasUnloadedFilteredPack: hasUnloadedFilteredPack
        )
        output.header("Summary")
        output.doctorSummary(
            passed: summary.passed,
            fixed: 0,
            warnings: summary.warnings,
            issues: summary.issues
        )

        // Phase 2: Confirm and execute pending fixes (after summary)
        if fixMode {
            executePendingFixes()
            summary.remainingIssues = failCount - fixedCount
            if fixedCount > 0 {
                output.plain("")
                output.success("Applied \(fixedCount) fix\(fixedCount == 1 ? "" : "es").")
            }
        } else {
            printRepairHint()
        }

        return summary
    }

    private func printRepairHint() {
        let ownFixCount = pendingFixes.count { $0.check.fixCommandPreview != nil }
        let resyncCount = planResyncs(pendingFixes.filter { $0.check.fixCommandPreview == nil })
            .planned.reduce(0) { $0 + $1.checks.count }
        let repairable = ownFixCount + resyncCount
        if repairable > 0 {
            output.plain("")
            output.info("Run 'mcs doctor --fix' to repair \(repairable) issue\(repairable == 1 ? "" : "s").")
        }
    }

    // MARK: - Scope resolution

    /// Resolves which packs to check and in which scope(s).
    ///
    /// Returns one or two scopes depending on context:
    /// - `--global`: single global scope
    /// - `--pack`: single scope with the filtered pack(s)
    /// - In project: project scope + global-only scope (packs not already in the project)
    /// - Not in project: single global scope
    private func resolveCheckScopes(
        projectRoot: URL?,
        globallyConfiguredPackIDs: Set<String>,
        globalArtifactsByPack: [String: PackArtifactRecord]
    ) -> [CheckScope] {
        // --pack flag: single scope, use globalOnly to determine effective root
        if let packIDs = packFilterIDs {
            let effectiveRoot = globalOnly ? nil : projectRoot
            // Load artifacts from the appropriate state
            var artifacts: [String: PackArtifactRecord] = [:]
            var configuredHere: Set<String> = []
            if let root = effectiveRoot {
                do {
                    let state = try ProjectState(projectRoot: root)
                    configuredHere = state.configuredPacks
                    if state.exists {
                        for id in packIDs {
                            if let record = state.artifacts(for: id) {
                                artifacts[id] = record
                            }
                        }
                    }
                } catch {
                    output.warn("Could not read project state: \(error.localizedDescription)")
                }
            } else {
                // Global scope — use pre-loaded artifacts
                configuredHere = globallyConfiguredPackIDs
                for id in packIDs {
                    if let record = globalArtifactsByPack[id] {
                        artifacts[id] = record
                    }
                }
            }
            return [CheckScope(
                packIDs: packIDs,
                effectiveProjectRoot: effectiveRoot,
                label: "--pack flag",
                artifactsByPack: artifacts,
                canResync: packIDs.isSubset(of: configuredHere)
            )]
        }

        // --global flag: single global scope
        if globalOnly {
            return [globalScope(
                globallyConfiguredPackIDs,
                artifactsByPack: globalArtifactsByPack
            )]
        }

        // In a project: resolve project packs, then append global-only packs
        if let root = projectRoot {
            let projectName = root.lastPathComponent
            var scopes: [CheckScope] = []
            var projectPackIDs: Set<String> = []

            if let projectScope = resolveProjectScope(root: root, projectName: projectName) {
                projectPackIDs = projectScope.packIDs
                scopes.append(projectScope)
            }

            // Append packs that are globally configured but not in the project scope
            let globalOnlyIDs = globallyConfiguredPackIDs.subtracting(projectPackIDs)
            if !globalOnlyIDs.isEmpty {
                scopes.append(globalScope(
                    globalOnlyIDs,
                    artifactsByPack: globalArtifactsByPack
                ))
            }

            // If nothing was found at all, fall back to the full global set
            if scopes.isEmpty {
                scopes.append(globalScope(
                    globallyConfiguredPackIDs,
                    artifactsByPack: globalArtifactsByPack
                ))
            }

            return scopes
        }

        // Not in a project — global packs only
        return [globalScope(
            globallyConfiguredPackIDs,
            artifactsByPack: globalArtifactsByPack
        )]
    }

    /// Resolves the project-scoped `CheckScope` for the given project root.
    /// Returns nil if no project packs can be determined.
    private func resolveProjectScope(root: URL, projectName: String) -> CheckScope? {
        // Tier 1: Project .mcs-project state file
        do {
            let state = try ProjectState(projectRoot: root)
            if state.exists, !state.configuredPacks.isEmpty {
                var artifactsByPack: [String: PackArtifactRecord] = [:]
                for packID in state.configuredPacks {
                    if let artifacts = state.artifacts(for: packID) {
                        artifactsByPack[packID] = artifacts
                    }
                }
                return CheckScope(
                    packIDs: state.configuredPacks,
                    effectiveProjectRoot: root,
                    label: "project: \(projectName)",
                    artifactsByPack: artifactsByPack
                )
            }
        } catch {
            output.warn("Could not read .mcs-project: \(error.localizedDescription) — falling back to section markers")
        }

        // Tier 2: Fallback — infer from CLAUDE.local.md section markers
        let claudeLocal = root.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        guard FileManager.default.fileExists(atPath: claudeLocal.path) else { return nil }

        let content: String
        do {
            content = try String(contentsOf: claudeLocal, encoding: .utf8)
        } catch {
            output.warn("Could not read \(Constants.FileNames.claudeLocalMD): \(error.localizedDescription)")
            return nil
        }

        let inferred = Set(TemplateComposer.parseSections(from: content).map(\.identifier))
        guard !inferred.isEmpty else { return nil }

        return CheckScope(
            packIDs: inferred,
            effectiveProjectRoot: root,
            label: "project: \(projectName) (inferred)",
            artifactsByPack: [:]
        )
    }

    /// Creates a global-scope `CheckScope` with the given pack IDs.
    private func globalScope(
        _ packIDs: Set<String>,
        artifactsByPack: [String: PackArtifactRecord]
    ) -> CheckScope {
        CheckScope(
            packIDs: packIDs,
            effectiveProjectRoot: nil,
            label: "global",
            artifactsByPack: artifactsByPack
        )
    }

    // MARK: - Artifact-record checks

    /// Builds doctor checks derived from a pack's stored artifact record.
    /// Covers file content hashes, hook commands, settings keys, and gitignore entries.
    private func artifactChecks(
        for artifacts: PackArtifactRecord,
        pack: any TechPack,
        scope: CheckScope,
        env: Environment
    ) -> [CollectedCheck] {
        var checks: [CollectedCheck] = []

        let baseURL = scope.effectiveProjectRoot ?? env.claudeDirectory
        for (relativePath, expectedHash) in artifacts.fileHashes {
            let fileURL = baseURL.appendingPathComponent(relativePath)
            checks.append((
                check: FileContentCheck(
                    name: "File content: \(relativePath)",
                    section: "Installed Files",
                    path: fileURL,
                    expectedHash: expectedHash
                ),
                syncTarget: scope.syncTarget
            ))
        }

        if !artifacts.hookCommands.isEmpty || !artifacts.settingsKeys.isEmpty {
            let settingsPath: URL = if let root = scope.effectiveProjectRoot {
                root.appendingPathComponent(Constants.FileNames.claudeDirectory)
                    .appendingPathComponent(Constants.FileNames.settingsLocal)
            } else {
                env.claudeSettings
            }
            if !artifacts.hookCommands.isEmpty {
                checks.append((
                    check: HookSettingsCheck(
                        expectations: hookExpectations(for: artifacts, pack: pack, scope: scope),
                        settingsPath: settingsPath,
                        packName: pack.displayName
                    ),
                    syncTarget: scope.syncTarget
                ))
                let interpreterBinaries = HookInterpreter.distinctCheckableBinaries(
                    inRegisteredCommands: artifacts.hookCommands,
                    directory: scope.hookPathPrefix
                )
                for binary in interpreterBinaries {
                    checks.append((
                        check: HookInterpreterCheck(
                            binary: binary,
                            packName: pack.displayName,
                            environment: env
                        ),
                        // Sync does not install hook interpreters.
                        syncTarget: nil
                    ))
                }
            }
            if !artifacts.settingsKeys.isEmpty {
                checks.append((
                    check: SettingsKeysCheck(
                        keys: artifacts.settingsKeys,
                        settingsPath: settingsPath,
                        packName: pack.displayName
                    ),
                    syncTarget: scope.syncTarget
                ))
                if let expectedHash = artifacts.settingsHash {
                    checks.append((
                        check: SettingsDriftCheck(
                            keys: artifacts.settingsKeys,
                            expectedHash: expectedHash,
                            settingsPath: settingsPath,
                            packName: pack.displayName
                        ),
                        syncTarget: scope.syncTarget
                    ))
                }
            }
        }

        if !artifacts.gitignoreEntries.isEmpty {
            checks.append((
                check: PackGitignoreCheck(
                    entries: artifacts.gitignoreEntries,
                    packName: pack.displayName,
                    environment: env
                ),
                syncTarget: scope.syncTarget
            ))
        }

        return checks
    }

    /// Pairs each recorded hook command with the `HookRegistration` of the component that declared
    /// it, so the check can verify *how* the hook was registered and not merely that it exists.
    ///
    /// The join key is the command string, rebuilt with `hookCommand(pathPrefix:)` — the same helper
    /// sync used to write it. `pack` is already collision-resolved here, so namespaced
    /// destinations match what sync actually installed. Commands with no matching component
    /// (hooks supplied via `settingsFile:`, or state files predating this check) get a nil
    /// registration and keep presence-only semantics.
    private func hookExpectations(
        for artifacts: PackArtifactRecord,
        pack: any TechPack,
        scope: CheckScope
    ) -> [ExpectedHook] {
        var registrationsByCommand: [String: HookRegistration] = [:]
        for component in pack.components {
            // Bind the registration explicitly rather than relying on `hookCommand(pathPrefix:)`
            // already having required one — same shape the sync-side join uses.
            if let registration = component.hookRegistration,
               let command = component.hookCommand(pathPrefix: scope.hookPathPrefix) {
                registrationsByCommand[command] = registration
            }
        }
        return artifacts.hookCommands.map {
            ExpectedHook(command: $0, registration: registrationsByCommand[$0])
        }
    }

    // MARK: - Standalone checks (not tied to any component)

    /// Checks that cannot be derived from any ComponentDefinition.
    private func standaloneDoctorChecks() -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []

        // Gitignore (core entries)
        checks.append(GitignoreCheck(environment: environment))

        // Project index (cross-project tracking)
        checks.append(ProjectIndexCheck(environment: environment))

        return checks
    }

    // MARK: - Check execution

    /// Phase 1: Diagnose all checks. Failures are collected into `pendingFixes`
    /// for later confirmation instead of being fixed immediately.
    private mutating func runChecks(_ checks: [CollectedCheck]) {
        for entry in checks {
            let result = entry.check.check()
            let name = entry.check.name

            switch result {
            case let .pass(msg):
                docPass(name, msg)
            case let .fail(msg):
                docFail(name, msg)
                pendingFixes.append(entry)
            case let .warn(msg):
                docWarn(name, msg)
            case let .skip(msg):
                docSkip(name, msg)
            }
        }
    }

    /// A scope re-sync planned for `--fix`: the scope's full configured set and the failed checks
    /// it should repair.
    private struct PlannedResync {
        let target: SyncTarget
        let run: UpdateScopeResolver.ScopeRun
        let checks: [any DoctorCheck]
    }

    /// Phase 2: Show a summary of pending fixes with their actual commands,
    /// prompt for confirmation, then execute.
    private mutating func executePendingFixes() {
        let ownFixes = pendingFixes.map(\.check).filter { $0.fixCommandPreview != nil }
        let (resyncs, hintOnly) = planResyncs(pendingFixes.filter { $0.check.fixCommandPreview == nil })

        // Runs before the prompt: a check with no preview has no fix of its own, so its `fix()`
        // only returns the `.notFixable` hint. A check that mutates must declare a preview.
        for check in hintOnly {
            report(check.name, check.fix())
        }

        guard !ownFixes.isEmpty || !resyncs.isEmpty else { return }

        output.plain("")
        output.sectionHeader("Available fixes")

        for check in ownFixes {
            output.plain("    • \(check.name): \(check.fixCommandPreview!)")
        }
        for resync in resyncs {
            let packIDs = resync.run.configuredPackIDs.sorted()
            let fixes = resync.checks.map(\.name).joined(separator: ", ")
            output.plain("    • Re-sync \(resync.run.label): packs \(packIDs.joined(separator: ", ")) — fixes: \(fixes)")
            if let firstPack = packIDs.first {
                let preview = "mcs sync\(resync.run.isGlobal ? " --global" : "") --pack \(firstPack) --dry-run"
                output.dimmed("      Resets managed files you edited in this scope. Preview: \(preview)")
            }
        }

        output.plain("")
        let count = ownFixes.count + resyncs.count
        let fixLabel = count == 1 ? "fix" : "fixes"
        if !skipConfirmation {
            guard output.askYesNo("Apply \(count) \(fixLabel)?", default: false) else {
                output.dimmed("  Skipped all fixes.")
                return
            }
        }

        output.plain("")
        for check in ownFixes {
            report(check.name, check.fix())
        }
        guard !resyncs.isEmpty else { return }
        // An injected CLI stands in for the real binary; only the real one needs installing.
        if claudeCLI == nil, !ensureClaudeCLI(shell: shell, environment: environment, output: output) {
            for check in resyncs.flatMap(\.checks) {
                docFixFailed(check.name, "re-sync needs the Claude Code CLI")
            }
            return
        }
        for resync in resyncs {
            applyResync(resync)
        }
    }

    /// Splits failures without an own fix into per-scope re-syncs and hint-only checks. A scope
    /// with no recorded configured packs has nothing to re-sync from, so its checks get hints too.
    private func planResyncs(
        _ entries: [CollectedCheck]
    ) -> (planned: [PlannedResync], hintOnly: [any DoctorCheck]) {
        var targets: [SyncTarget] = []
        var checksByTarget: [SyncTarget: [any DoctorCheck]] = [:]
        var hintOnly: [any DoctorCheck] = []
        for entry in entries {
            guard let target = entry.syncTarget else {
                hintOnly.append(entry.check)
                continue
            }
            if checksByTarget[target] == nil {
                targets.append(target)
            }
            checksByTarget[target, default: []].append(entry.check)
        }

        let resolver = UpdateScopeResolver(environment: environment, output: output)
        var planned: [PlannedResync] = []
        for target in targets {
            let checks = checksByTarget[target] ?? []
            do {
                if let run = try resolver.scopeRun(projectRoot: target.projectRoot) {
                    planned.append(PlannedResync(target: target, run: run, checks: checks))
                } else {
                    hintOnly += checks
                }
            } catch {
                output.warn("Could not read sync state for \(target.label): \(error.localizedDescription)")
                hintOnly += checks
            }
        }
        return (planned, hintOnly)
    }

    /// Re-syncs one scope, then re-runs its failed checks so a check the re-sync could not repair
    /// reports as still failing rather than fixed.
    ///
    /// The run is resolved again here rather than reused from the prompt: an own fix applied just
    /// before (`ScopeDuplicationCheck` unconfiguring a pack) may have changed the configured set,
    /// and re-syncing the stale set would reinstall what that fix removed.
    private mutating func applyResync(_ resync: PlannedResync) {
        let run: UpdateScopeResolver.ScopeRun
        do {
            guard let current = try UpdateScopeResolver(environment: environment, output: output)
                .scopeRun(projectRoot: resync.target.projectRoot)
            else {
                for check in resync.checks {
                    docFixFailed(check.name, "\(resync.target.label) no longer has configured packs to re-sync")
                }
                return
            }
            run = current
            if current.configuredPackIDs != resync.run.configuredPackIDs {
                let packs = current.configuredPackIDs.sorted().joined(separator: ", ")
                output.dimmed("  \(current.label) changed since the prompt; re-syncing packs \(packs)")
            }
        } catch {
            for check in resync.checks {
                docFixFailed(check.name, "could not read sync state: \(error.localizedDescription)")
            }
            return
        }

        do {
            let blocked = try ScopeReapplier.reapplyScope(
                run,
                skippedPackIDs: [],
                registry: registry,
                dryRun: false,
                env: environment,
                shell: shell,
                output: output,
                claudeCLI: claudeCLI
            )
            if blocked {
                for check in resync.checks {
                    docFixFailed(check.name, "scope was not re-synced")
                }
                return
            }
        } catch let error as PromptResolutionError {
            error.lines.forEach { output.error($0) }
        } catch {
            output.error("Re-sync of \(run.label) failed: \(error.localizedDescription)")
        }

        // A throw can leave the scope partly written, so the checks report what is on disk now.
        output.plain("")
        for check in resync.checks {
            switch check.check() {
            case let .pass(msg):
                docFixed(check.name, msg)
            case let .skip(msg):
                docSkip(check.name, msg)
            // The check still holds the expectation recorded before the re-sync, so a pack whose
            // source changed since then warns about drift even though the repair worked.
            case let .warn(msg):
                docFixed(check.name, "restored; differs from the last recorded state (\(msg))")
            case let .fail(msg):
                docFixFailed(check.name, "still failing after re-sync: \(msg)")
            }
        }
    }

    private mutating func report(_ name: String, _ result: FixResult) {
        switch result {
        case let .fixed(msg):
            docFixed(name, msg)
        case let .failed(msg):
            docFixFailed(name, msg)
        case let .notFixable(msg):
            output.warn("    ↳ \(name): \(msg)")
        }
    }

    // MARK: - Output helpers

    private mutating func docPass(_ name: String, _ msg: String) {
        passCount += 1
        output.success("✓ \(name): \(msg)")
    }

    private mutating func docFail(_ name: String, _ msg: String) {
        failCount += 1
        output.error("✗ \(name): \(msg)")
    }

    private mutating func docWarn(_ name: String, _ msg: String) {
        // warningCounter increments inside output.warn — single source of truth.
        output.warn("⚠ \(name): \(msg)")
    }

    private mutating func docSkip(_ name: String, _ msg: String) {
        output.dimmed("○ \(name): \(msg)")
    }

    private mutating func docFixed(_ name: String, _ msg: String) {
        fixedCount += 1
        output.success("    ✓ \(name): \(msg)")
    }

    private mutating func docFixFailed(_ name: String, _ msg: String) {
        output.error("    ✗ \(name): \(msg)")
    }
}
