import Foundation

/// Reports a pack configured in *both* the global scope and the current project, where its
/// artifacts are installed twice and take effect twice.
///
/// `mcs sync` blocks a globally-installed pack from being *added* to a project
/// (`ConfiguratorSupport.globallyBlockedIDs`), but deliberately leaves a pack already present in
/// both scopes selectable — blocking it would drop it from the desired pack set, which
/// `mcs sync --all` converges on with no prompt, silently unconfiguring it. That transition-only
/// rule means pre-existing duplicates persist, and this check is what finds them.
///
/// `fix()` removes the project-scoped copy and keeps the global one, but only once it can prove
/// the removal is lossless — see the obstacle gates below.
struct ScopeDuplicationCheck: DoctorCheck {
    let packID: String
    let projectRoot: URL
    let registry: TechPackRegistry
    let environment: Environment

    /// Computed once by `checks(...)` and reused by `check()` and `fixCommandPreview`, which the
    /// runner reads four times in total within one pass. Diagnosing is not free — two state
    /// decodes, a disk read per template, and a hash of every installed file — and nothing mutates
    /// project state between those reads. `fix()` re-derives instead, because the user is prompted
    /// in between and the filesystem may have moved on.
    private let diagnosis: Diagnosis

    var name: String {
        "Scope duplication: \(packID)"
    }

    var section: String {
        "Project"
    }

    /// Non-nil only when the removal is provably lossless. A nil preview makes `DoctorRunner`
    /// treat the check as unfixable and surface `fix()`'s `.notFixable` reason as a hint instead.
    var fixCommandPreview: String? {
        guard case .duplicated(_, nil) = diagnosis else { return nil }
        return "remove the project-scoped copy of '\(packID)' (keeps global)"
    }

    // MARK: - Check

    func check() -> CheckResult {
        switch diagnosis {
        case let .resolved(result):
            result
        case let .duplicated(summary, blocked):
            .fail(
                "also installed globally — \(summary) duplicated; "
                    + (blocked ?? "run 'mcs doctor --fix' to remove the project copy")
            )
        }
    }

    // MARK: - Fix

    func fix() -> FixResult {
        // Re-derived rather than reusing the stored diagnosis: the user was prompted in between,
        // and an edit made since then must still block the removal.
        let inputs: Inputs?
        do {
            inputs = try Self.makeInputs(
                packID: packID, projectRoot: projectRoot,
                registry: registry, environment: environment
            )
        } catch {
            return .failed("could not read state: \(error.localizedDescription)")
        }
        guard let inputs, case let .duplicated(_, blocked) = Self.diagnose(inputs) else {
            return .notFixable("no longer duplicated — re-run 'mcs doctor'")
        }
        if let blocked {
            return .notFixable(blocked)
        }

        let output = CLIOutput()
        let shell = ShellRunner(environment: environment)
        var state = inputs.projectState

        let configurator = Configurator(
            environment: environment,
            output: output,
            shell: shell,
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: projectRoot, environment: environment)
        )
        // Default `refCountScope` (nil → this project's path): the global scope still counts, so
        // brew packages, plugins and gitignore entries report `.stillNeeded` and stay in place.
        // Passing `packRemoveSentinel` here would exclude every scope and remove them.
        configurator.unconfigurePack(packID, state: &state)

        do {
            try state.save()
        } catch {
            return .failed("could not write .mcs-project: \(error.localizedDescription)")
        }

        // `unconfigurePack` keeps the pack in state whenever cleanup was partial (the shrinking-set
        // pattern) or the settings file could not be parsed. Leave the project index alone in that
        // case so reference counting stays conservative.
        guard !state.configuredPacks.contains(packID) else {
            return .failed("some artifacts could not be removed — re-run 'mcs sync' to retry")
        }

        pruneProjectIndex(output: output)

        return .fixed("removed project-scoped '\(packID)' (global copy kept)")
    }

    /// Drop this pack from this project's entry in `~/.mcs/projects.yaml`.
    /// Failure warns rather than fails, mirroring `Configurator.saveStateAndUpdateIndex`.
    private func pruneProjectIndex(output: CLIOutput) {
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
        do {
            var data = try indexFile.load()
            indexFile.removePack(packID, fromProject: projectRoot.path, in: &data)
            try indexFile.save(data)
        } catch {
            output.warn("Could not update project index: \(error.localizedDescription)")
            output.warn("Cross-project resource tracking may be inaccurate. Re-run 'mcs sync' to retry.")
        }
    }

    // MARK: - Diagnosis

    private enum Diagnosis {
        /// Nothing to report; the reason is already a final result.
        case resolved(CheckResult)
        /// `blocked` is nil when the project copy can be removed without losing anything.
        case duplicated(summary: String, blocked: String?)
    }

    /// Everything a diagnosis reads, gathered once.
    private struct Inputs {
        let pack: any TechPack
        let projectRoot: URL
        let environment: Environment
        let projectState: ProjectState
        let globalState: ProjectState

        var packID: String {
            pack.identifier
        }
    }

    /// Load both scopes' state. Returns nil when the pack is unknown to the registry or no longer
    /// configured in both scopes — either way there is nothing to diagnose.
    private static func makeInputs(
        packID: String,
        projectRoot: URL,
        registry: TechPackRegistry,
        environment: Environment
    ) throws -> Inputs? {
        guard let pack = registry.pack(for: packID) else { return nil }
        let projectState = try ProjectState(projectRoot: projectRoot)
        let globalState = try ProjectState(stateFile: environment.globalStateFile)
        guard projectState.configuredPacks.contains(packID),
              globalState.configuredPacks.contains(packID)
        else {
            return nil
        }
        return Inputs(
            pack: pack, projectRoot: projectRoot, environment: environment,
            projectState: projectState, globalState: globalState
        )
    }

    private static func diagnose(_ inputs: Inputs) -> Diagnosis {
        let pack = inputs.pack
        let projectExcluded = inputs.projectState.excludedComponents(for: inputs.packID)
        let globalExcluded = inputs.globalState.excludedComponents(for: inputs.packID)

        // One partition, read from both sides: components shared with the global scope are
        // candidates for duplication, and the rest are what removing the project copy would lose.
        let globalIDs = Set(pack.components.filter { !globalExcluded.contains($0.id) }.map(\.id))
        let projectComponents = pack.components.filter { !projectExcluded.contains($0.id) }
        let duplicatedComponents = projectComponents.filter {
            globalIDs.contains($0.id) && duplicatesAcrossScopes($0.installAction)
        }
        let projectOnly = projectComponents.filter { !globalIDs.contains($0.id) }

        let duplicatedSectionCount: Int
        do {
            let templates = try pack.templates
            duplicatedSectionCount = sectionIdentifiers(templates, excluding: projectExcluded)
                .intersection(sectionIdentifiers(templates, excluding: globalExcluded))
                .count
        } catch {
            return .resolved(.warn(
                "could not load templates for '\(inputs.packID)': \(error.localizedDescription)"
            ))
        }

        guard !duplicatedComponents.isEmpty || duplicatedSectionCount > 0 else {
            return .resolved(.pass("configured in both scopes, but no artifacts overlap"))
        }

        // First obstacle wins — each gate names something the user must resolve before the
        // project copy can be removed without losing anything.
        let blocked = divergentComponentsObstacle(projectOnly)
            ?? divergentPromptObstacle(inputs)
            ?? editedFileObstacle(inputs)

        return .duplicated(
            summary: summarize(components: duplicatedComponents, sectionCount: duplicatedSectionCount),
            blocked: blocked
        )
    }

    /// Whether installing this action in both scopes leaves two copies that both take effect.
    ///
    /// Only `copyPackFile` does. Its files land in `<project>/.claude/` and `~/.claude/`
    /// independently, and a hook component's settings entry embeds the scope's hook directory
    /// (`Constants.HookCommand.projectDirectory` / `.globalDirectory`) — the interpreter is
    /// resolved per component and is the same in both scopes, but the directory differs, so the
    /// two entries are distinct strings that both fire. Everything else either shadows (project
    /// `settings.local.json` over global
    /// `settings.json`, MCP `local` over `user`), is installed once (the project scope skips brew
    /// packages and plugins entirely), writes one idempotent line (gitignore), or is a one-shot
    /// side effect rather than a standing artifact (`shellCommand`).
    ///
    /// Deliberately exhaustive: a new install action should not silently default to "harmless".
    private static func duplicatesAcrossScopes(_ action: ComponentInstallAction) -> Bool {
        switch action {
        case .copyPackFile:
            true
        case .mcpServer, .plugin, .brewInstall, .shellCommand, .settingsMerge, .gitignoreEntries:
            false
        }
    }

    private static func sectionIdentifiers(
        _ templates: [TemplateContribution],
        excluding excluded: Set<String>
    ) -> Set<String> {
        Set(templates.excludingDependencies(on: excluded).map(\.sectionIdentifier))
    }

    private static func summarize(components: [ComponentDefinition], sectionCount: Int) -> String {
        let counts = components.reduce(into: [ComponentType: Int]()) { $0[$1.type, default: 0] += 1 }
        var parts = ComponentType.allCases.compactMap { type in
            counts[type].map { counted($0, type.rawValue.lowercased()) }
        }
        if sectionCount > 0 {
            parts.append(counted(sectionCount, "CLAUDE.md sections"))
        }
        return parts.joined(separator: ", ")
    }

    /// Only file-copy component types reach this (skills, hooks, commands, agents,
    /// configurations), so trimming a trailing "s" is a safe singular.
    private static func counted(_ count: Int, _ plural: String) -> String {
        count == 1 && plural.hasSuffix("s") ? "\(count) \(plural.dropLast())" : "\(count) \(plural)"
    }

    // MARK: - Obstacles to a lossless removal

    /// The global scope must install everything the project scope does. Divergent `--customize`
    /// choices mean removal would delete a component nothing else provides.
    private static func divergentComponentsObstacle(_ projectOnly: [ComponentDefinition]) -> String? {
        guard !projectOnly.isEmpty else { return nil }
        let names = projectOnly.map(\.displayName).sorted().joined(separator: ", ")
        return "the project scope installs \(names), which the global scope excludes — "
            + "remove it with 'mcs sync' instead"
    }

    /// Both scopes must have answered the pack's prompts identically, or removal would silently
    /// switch this project onto the global answer. The project's key set is used deliberately — a
    /// `fileDetect` prompt is dropped in global scope, so the global value is absent and correctly
    /// reads as divergent.
    private static func divergentPromptObstacle(_ inputs: Inputs) -> String? {
        let projectValues = inputs.projectState.resolvedValues ?? [:]
        let globalValues = inputs.globalState.resolvedValues ?? [:]
        let context = ProjectSyncStrategy(
            projectPath: inputs.projectRoot, environment: inputs.environment
        ).makeConfigContext(output: CLIOutput(), resolvedValues: projectValues, priorValues: [:])

        let divergent = inputs.pack.declaredPrompts(context: context)
            .map(\.key)
            .filter { projectValues[$0] != globalValues[$0] }
            .sorted()
        guard !divergent.isEmpty else { return nil }
        return "the two scopes answered \(divergent.joined(separator: ", ")) differently — "
            + "removing the project copy would switch it to the global answer"
    }

    /// Refuse to delete files the user has edited. `unconfigurePack` removes tracked files without
    /// consulting the recorded hash, so drift here is data loss. An unreadable file cannot be
    /// proven untouched, so it counts as at risk rather than being deleted.
    private static func editedFileObstacle(_ inputs: Inputs) -> String? {
        guard let record = inputs.projectState.artifacts(for: inputs.packID) else { return nil }

        let atRisk = record.fileHashes.compactMap { relativePath, expectedHash -> String? in
            let fileURL = inputs.projectRoot.appendingPathComponent(relativePath)
            switch FileHasher.drift(of: fileURL, expecting: expectedHash) {
            case .matches, .missing, .directory:
                return nil
            case .changed:
                return relativePath
            case let .unreadable(error):
                return "\(relativePath) (unreadable: \(error.localizedDescription))"
            }
        }

        guard !atRisk.isEmpty else { return nil }
        return "\(atRisk.sorted().joined(separator: ", ")) changed since install — "
            + "removing the project copy would discard those edits"
    }

    // MARK: - Factory

    /// One check per pack configured in *both* the project and the global scope.
    ///
    /// Reads global state directly rather than reusing `DoctorRunner`'s `globallyConfiguredPackIDs`,
    /// which falls back to the pack *registry* when the global state file is absent — reusing it
    /// would report every project pack as a duplicate on a machine that never ran
    /// `mcs sync --global`.
    static func checks(
        projectRoot: URL,
        registry: TechPackRegistry,
        environment: Environment,
        packFilter: Set<String>?
    ) -> [any DoctorCheck] {
        let globalPacks: Set<String>
        let projectPacks: Set<String>
        do {
            let globalState = try ProjectState(stateFile: environment.globalStateFile)
            // No global scope has ever been synced, so nothing can be duplicated.
            guard globalState.exists else { return [] }
            globalPacks = globalState.configuredPacks
            projectPacks = try ProjectState(projectRoot: projectRoot).configuredPacks
        } catch {
            // Corrupt state is already reported by `ProjectStateFileCheck` with a specific fix.
            // A second, vaguer complaint about the same file would only add noise.
            return []
        }

        var duplicated = globalPacks.intersection(projectPacks)
        if let packFilter {
            duplicated.formIntersection(packFilter)
        }

        return duplicated.sorted().map { packID in
            ScopeDuplicationCheck(
                packID: packID, projectRoot: projectRoot,
                registry: registry, environment: environment,
                diagnosis: initialDiagnosis(
                    packID: packID, projectRoot: projectRoot,
                    registry: registry, environment: environment
                )
            )
        }
    }

    private static func initialDiagnosis(
        packID: String,
        projectRoot: URL,
        registry: TechPackRegistry,
        environment: Environment
    ) -> Diagnosis {
        do {
            // Both scopes were just confirmed to list this pack, so a nil here means the registry
            // does not know it — a pack synced from a source that has since been removed.
            guard let inputs = try makeInputs(
                packID: packID, projectRoot: projectRoot,
                registry: registry, environment: environment
            ) else {
                return .resolved(.skip("pack '\(packID)' is not registered"))
            }
            return diagnose(inputs)
        } catch {
            return .resolved(.warn("could not read pack state: \(error.localizedDescription)"))
        }
    }
}
