import Foundation

/// Orchestrates all doctor checks grouped by section, with optional fix mode.
///
/// **Scope of `--fix`**: Cleanup, migration, and trivial repairs only.
/// Additive operations (install/register/copy) are deferred to `mcs sync`.
/// See CoreDoctorChecks.swift header for the full responsibility boundary.
struct DoctorRunner {
    let fixMode: Bool
    /// Skip the confirmation prompt before executing fixes (e.g. `--yes` flag).
    let skipConfirmation: Bool
    /// Explicit pack filter. If nil, uses packs from project state or pack registry.
    let packFilter: String?
    /// When true, check only globally-configured packs (ignores project scope).
    let globalOnly: Bool
    let registry: TechPackRegistry

    private let output = CLIOutput()
    private var passCount = 0
    private var failCount = 0
    private var warnCount = 0
    private var fixedCount = 0
    /// Failed checks collected during diagnosis, to be fixed after confirmation.
    private var pendingFixes: [any DoctorCheck] = []

    /// A resolved scope for check collection. Each scope carries the pack IDs,
    /// effective project root, excluded components, and a display label.
    private struct CheckScope {
        let packIDs: Set<String>
        let effectiveProjectRoot: URL?
        let excludedComponentIDs: Set<String>
        let label: String
    }

    init(
        fixMode: Bool,
        skipConfirmation: Bool = false,
        packFilter: String? = nil,
        globalOnly: Bool = false,
        registry: TechPackRegistry
    ) {
        self.fixMode = fixMode
        self.skipConfirmation = skipConfirmation
        self.packFilter = packFilter
        self.globalOnly = globalOnly
        self.registry = registry
    }

    mutating func run() throws {
        output.header("Managed Claude Stack — Doctor")

        let env = Environment()
        let registry = registry

        // Resolve globally-configured pack IDs from global state.
        // This reflects packs actively synced to the global scope, not just
        // registered (available) packs. A pack in registry.yaml but not in
        // global-state.json's configuredPacks has been unsynced and shouldn't
        // trigger doctor checks.
        let globallyConfiguredPackIDs: Set<String>
        do {
            let globalState = try ProjectState(stateFile: env.globalStateFile)
            if globalState.exists {
                // Global state file exists — use its configured packs (may be empty)
                globallyConfiguredPackIDs = globalState.configuredPacks
            } else {
                // No global state file yet — fall back to registry for backward compat
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
        let projectRoot = ProjectDetector.findProjectRoot()

        // Resolve check scopes (project, global, or both)
        let scopes = resolveCheckScopes(
            projectRoot: projectRoot,
            globallyConfiguredPackIDs: globallyConfiguredPackIDs
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

        var allChecks: [(check: any DoctorCheck, isExcluded: Bool)] = []
        var allPackIDs = Set<String>()
        let availablePacks = registry.availablePacks

        // Layer 1+2: Derived + supplementary checks from installed components (per scope)
        for scope in scopes {
            allPackIDs.formUnion(scope.packIDs)

            let scopePacks = availablePacks.filter { scope.packIDs.contains($0.identifier) }

            for pack in scopePacks {
                for component in pack.components {
                    let excluded = scope.excludedComponentIDs.contains(component.id)
                    let checks = component.allDoctorChecks(projectRoot: scope.effectiveProjectRoot)
                    allChecks += checks.map { (check: $0, isExcluded: excluded) }
                }
                // Pack-level supplementary checks (cannot be derived from components)
                allChecks += pack.supplementaryDoctorChecks.map { (check: $0, isExcluded: false) }
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
        }

        // Global-scoped template freshness check (always runs, self-skips if no global CLAUDE.md)
        nonComponentChecks.append(CLAUDEMDFreshnessCheck(
            fileURL: env.globalClaudeMD,
            stateLoader: { try ProjectState(stateFile: env.globalStateFile) },
            registry: registry,
            displayName: "CLAUDE.md freshness (global)",
            syncHint: "mcs sync --global"
        ))

        allChecks += nonComponentChecks.map { (check: $0, isExcluded: false) }

        // Group by section
        let grouped = Dictionary(grouping: allChecks, by: \.check.section)
        let sectionOrder = [
            "Dependencies", "MCP Servers", "Plugins", "Skills", "Commands",
            "Hooks", "Settings", "Gitignore", "Project", "Templates",
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

        // Phase 2: Confirm and execute pending fixes
        if fixMode {
            executePendingFixes()
        }

        // Summary
        output.header("Summary")
        output.doctorSummary(
            passed: passCount,
            fixed: fixedCount,
            warnings: warnCount,
            issues: failCount
        )
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
        globallyConfiguredPackIDs: Set<String>
    ) -> [CheckScope] {
        // --pack flag: single scope, use globalOnly to determine effective root
        if let filter = packFilter {
            let packIDs = Set(filter.components(separatedBy: ","))
            return [CheckScope(
                packIDs: packIDs,
                effectiveProjectRoot: globalOnly ? nil : projectRoot,
                excludedComponentIDs: [],
                label: "--pack flag"
            )]
        }

        // --global flag: single global scope
        if globalOnly {
            return [globalScope(globallyConfiguredPackIDs)]
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
                scopes.append(globalScope(globalOnlyIDs))
            }

            // If nothing was found at all, fall back to the full global set
            if scopes.isEmpty {
                scopes.append(globalScope(globallyConfiguredPackIDs))
            }

            return scopes
        }

        // Not in a project — global packs only
        return [globalScope(globallyConfiguredPackIDs)]
    }

    /// Resolves the project-scoped `CheckScope` for the given project root.
    /// Returns nil if no project packs can be determined.
    private func resolveProjectScope(root: URL, projectName: String) -> CheckScope? {
        // Tier 1: Project .mcs-project state file
        do {
            let state = try ProjectState(projectRoot: root)
            if state.exists, !state.configuredPacks.isEmpty {
                let excludedIDs = Set(state.allExcludedComponents.values.flatMap(\.self))
                return CheckScope(
                    packIDs: state.configuredPacks,
                    effectiveProjectRoot: root,
                    excludedComponentIDs: excludedIDs,
                    label: "project: \(projectName)"
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
            excludedComponentIDs: [],
            label: "project: \(projectName) (inferred)"
        )
    }

    /// Creates a global-scope `CheckScope` with the given pack IDs.
    private func globalScope(_ packIDs: Set<String>) -> CheckScope {
        CheckScope(packIDs: packIDs, effectiveProjectRoot: nil, excludedComponentIDs: [], label: "global")
    }

    // MARK: - Standalone checks (not tied to any component)

    /// Checks that cannot be derived from any ComponentDefinition.
    private func standaloneDoctorChecks() -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []

        // Gitignore (core entries)
        checks.append(GitignoreCheck())

        // Project index (cross-project tracking)
        checks.append(ProjectIndexCheck())

        return checks
    }

    // MARK: - Check execution

    /// Phase 1: Diagnose all checks. Failures are collected into `pendingFixes`
    /// for later confirmation instead of being fixed immediately.
    private mutating func runChecks(_ checks: [(check: any DoctorCheck, isExcluded: Bool)]) {
        for entry in checks {
            let result = entry.check.check()
            let name = entry.check.name

            // Show excluded component failures/warnings as skipped
            // (user explicitly deselected via --customize)
            if entry.isExcluded, result.isFailOrWarn {
                docSkip(name, "excluded via --customize")
                continue
            }

            switch result {
            case let .pass(msg):
                docPass(name, msg)
            case let .fail(msg):
                docFail(name, msg)
                if fixMode {
                    pendingFixes.append(entry.check)
                }
            case let .warn(msg):
                docWarn(name, msg)
            case let .skip(msg):
                docSkip(name, msg)
            }
        }
    }

    /// Phase 2: Show a summary of pending fixes with their actual commands,
    /// prompt for confirmation, then execute.
    private mutating func executePendingFixes() {
        // Separate fixable checks (have a preview command) from unfixable ones.
        // Unfixable checks are shown as hints after the prompt, not in the confirmation list.
        let fixable = pendingFixes.filter { $0.fixCommandPreview != nil }
        let unfixable = pendingFixes.filter { $0.fixCommandPreview == nil }

        // Show unfixable hints immediately (no confirmation needed)
        for check in unfixable {
            let result = check.fix()
            if case let .notFixable(msg) = result {
                output.warn("  ↳ \(check.name): \(msg)")
            }
        }

        guard !fixable.isEmpty else { return }

        output.sectionHeader("Available fixes")

        for check in fixable {
            output.plain("  • \(check.name): \(check.fixCommandPreview!)")
        }

        let fixLabel = fixable.count == 1 ? "fix" : "fixes"
        if !skipConfirmation {
            guard output.askYesNo("Apply \(fixable.count) \(fixLabel)?", default: false) else {
                output.dimmed("Skipped all fixes.")
                return
            }
        }

        for check in fixable {
            switch check.fix() {
            case let .fixed(msg):
                docFixed(check.name, msg)
            case let .failed(msg):
                docFixFailed(check.name, msg)
            case let .notFixable(msg):
                output.warn("  ↳ \(check.name): \(msg)")
            }
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
        warnCount += 1
        output.warn("⚠ \(name): \(msg)")
    }

    private mutating func docSkip(_ name: String, _ msg: String) {
        output.dimmed("○ \(name): \(msg)")
    }

    private mutating func docFixed(_ name: String, _ msg: String) {
        fixedCount += 1
        failCount -= 1 // Convert fail to fixed
        output.success("  ✓ \(name): \(msg)")
    }

    private mutating func docFixFailed(_ name: String, _ msg: String) {
        output.error("  ✗ \(name): \(msg)")
    }
}
