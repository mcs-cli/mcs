import ArgumentParser
import Foundation

/// Shared utilities for the `Configurator` and `SyncStrategy` implementations.
///
/// Eliminates duplication of common methods that both configurators need.
enum ConfiguratorSupport {
    /// The pack list a non-interactive entry point hands to `Configurator.configure`, and the
    /// configured packs it kept without being asked to.
    struct DesiredPackSet {
        let packs: [any TechPack]
        let keptExtras: [String]
    }

    /// Desired set for an entry point that names some packs (`mcs sync --pack`, `mcs bootstrap`).
    ///
    /// Additive by default: every pack already configured in the scope is unioned in, so naming
    /// one pack never unconfigures the rest. `prune` makes `requested` the exact set.
    ///
    /// An extra the registry cannot produce aborts the additive run. Dropping it from the list
    /// would make `configure` treat it as a deselection and unconfigure it without asking.
    static func additivePackSet(
        requested: [any TechPack],
        previouslyConfigured: Set<String>,
        prune: Bool,
        pruneCommand: String,
        registry: TechPackRegistry,
        output: CLIOutput
    ) throws -> DesiredPackSet {
        guard !prune else { return DesiredPackSet(packs: requested, keptExtras: []) }

        let extras = previouslyConfigured.subtracting(requested.map(\.identifier)).sorted()
        var resolvedExtras: [any TechPack] = []
        var unresolved: [String] = []
        for id in extras {
            if let pack = registry.pack(for: id) {
                resolvedExtras.append(pack)
            } else {
                unresolved.append(id)
            }
        }

        if !unresolved.isEmpty {
            for id in unresolved {
                output.error("Pack '\(id)' is configured here but missing from the registry.")
            }
            output.plain("  Re-add it with 'mcs pack add', or run '\(pruneCommand)' to remove it.")
            throw ExitCode.failure
        }

        return DesiredPackSet(packs: requested + resolvedExtras, keptExtras: extras)
    }

    /// Non-blocking footer after an additive run that kept configured packs it was not given, so
    /// the divergence stays visible without a prompt.
    static func reportKeptExtras(_ extras: [String], notIn source: String, remedy: String, output: CLIOutput) {
        guard !extras.isEmpty else { return }
        output.plain("")
        output.info("\(extras.count) configured pack(s) kept that are not \(source):")
        for id in extras {
            output.plain("  - \(id)")
        }
        output.plain("  \(remedy)")
    }

    /// Drop globally-blocked packs from a non-interactive pack set, reporting what was
    /// skipped. Skipping is safe precisely because a blocked pack is not configured
    /// here, so removing it from the desired set cannot unconfigure anything.
    ///
    /// Shared by every non-interactive project-scope entry point (`mcs sync --pack`,
    /// `mcs bootstrap`): the rule and its user-facing wording have one definition.
    static func filterGloballyBlocked(
        _ packs: [any TechPack],
        globallyInstalled: Set<String>,
        previouslyConfigured: Set<String>,
        output: CLIOutput,
        allowEmpty: Bool = false
    ) throws -> [any TechPack] {
        let blocked = globallyBlockedIDs(
            candidates: packs.map(\.identifier),
            globallyInstalled: globallyInstalled,
            previouslyConfigured: previouslyConfigured
        )
        guard !blocked.isEmpty else { return packs }

        // Display names, matching the picker's "Already installed globally" section.
        // The same packs must not be named differently depending on the flag used.
        let blockedNames = packs
            .filter { blocked.contains($0.identifier) }
            .map(\.displayName)
            .sorted()
        output.warn("Skipping \(blocked.count) pack(s) already installed globally:")
        output.plain("  \(blockedNames.joined(separator: ", "))")
        output.plain("  Run 'mcs sync --global' to manage them.")

        let remaining = packs.filter { !blocked.contains($0.identifier) }
        // Callers guarantee `packs` is non-empty, but filtering can leave it empty.
        // For an additive caller, syncing an empty desired set would unconfigure the
        // whole project — refuse. For a caller that has already computed an
        // authoritative desired set (e.g. `mcs bootstrap --prune` where the extras
        // it wants removed live outside this list), `allowEmpty` says the empty
        // result is legitimate and the caller will drive the removal itself.
        guard !remaining.isEmpty else {
            if allowEmpty { return [] }
            output.error("All requested packs are already installed globally. Nothing to sync.")
            throw ExitCode.failure
        }
        return remaining
    }

    /// Pack identifiers that may not be installed into a project because they are
    /// already installed globally.
    ///
    /// The block is a rule about *transitions*: a pack already configured here is
    /// never blocked. Blocking by bare identity would drop both-scope packs from the
    /// desired set, and `Configurator.configure` removes anything missing from it —
    /// with `confirmRemovals: false` on the `--all`/`--pack` path, silently.
    ///
    /// Shared by the interactive picker (which lists these separately, unselectable)
    /// and `SyncCommand`'s non-interactive filter, so the rule has one definition.
    static func globallyBlockedIDs(
        candidates: [String],
        globallyInstalled: Set<String>,
        previouslyConfigured: Set<String>
    ) -> Set<String> {
        Set(candidates.filter {
            globallyInstalled.contains($0) && !previouslyConfigured.contains($0)
        })
    }

    /// Warning lines naming the tracked projects that already configure packs newly entering
    /// the *global* scope. Empty when nothing applies.
    ///
    /// The mirror of `globallyBlockedIDs`: that rule stops a globally-installed pack being added
    /// to a project; this one reports the reverse move. Installing globally is legitimate, but it
    /// duplicates every hook and skill in the projects that already hold the pack — the global and
    /// project copies register as distinct settings entries and both fire.
    ///
    /// Keyed on `additions` rather than the whole selection, so re-syncing a pack the global scope
    /// already has stays silent, and `mcs update` — which re-applies each scope's existing set —
    /// never warns at all.
    ///
    /// Pure so the wording itself is testable: `CLIOutput` writes straight to stdout and the suite
    /// has no way to capture it. Element 0 is the `warn` header, the rest are plain detail lines;
    /// there is exactly one header however many packs are involved.
    ///
    /// - Parameter pathExists: Injected so tests never reach the real filesystem.
    static func projectDuplicationWarning(
        additions: Set<String>,
        displayNames: [String: String],
        index: ProjectIndex.IndexData,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        var details: [String] = []
        for packID in additions.sorted() {
            // The global scope carries its own index entry. It is the scope being installed
            // into, not a project that ends up with a duplicate.
            let paths = index.projects
                .filter { !$0.isGlobal && $0.packs.contains(packID) }
                .map(\.path)
                .filter(pathExists)
                .sorted()
            guard !paths.isEmpty else { continue }
            details.append("    \(displayNames[packID] ?? packID) → \(paths.joined(separator: ", "))")
        }
        guard !details.isEmpty else { return [] }

        return ["\(details.count) pack(s) being installed globally are already configured in other projects:"]
            + details
            + [
                "  Their hooks and skills will run twice there until the project copy is removed.",
                "  Run 'mcs doctor --fix' in those projects to drop the project copy.",
            ]
    }

    /// The reuse gate's per-key listing, one line per key, sorted.
    ///
    /// Values stay hidden unless the key is in `visibleValueKeys`: prompts commonly hold MCP
    /// credentials, and the gate is printed to a terminal the user may be sharing. Pure so the
    /// redaction itself is testable — `CLIOutput` writes straight to stdout with no capture seam.
    static func reusableKeysListing(
        reusableValues: [String: String],
        visibleValueKeys: Set<String>
    ) -> [String] {
        reusableValues.keys.sorted().map { key in
            guard visibleValueKeys.contains(key), let value = reusableValues[key] else {
                return "  \(key)"
            }
            return "  \(key): \(value)"
        }
    }

    /// Emit `projectDuplicationWarning`, doing nothing outside the global scope.
    ///
    /// The scope gate lives here rather than at each call site: only a global install can create
    /// this duplication, so every caller needs the same check, and a future one that forgot it
    /// would print a nonsensical "installed globally" notice during a project sync.
    ///
    /// Advisory only: it never filters the pack set — `Configurator.configure` treats that set as a
    /// complete desired state and unconfigures anything missing from it — and never writes to the
    /// index, stale entries included. An unreadable index degrades to a notice rather than failing
    /// the sync; `ProjectIndexCheck` is what reports a broken index.
    static func warnProjectDuplication(
        isGlobalScope: Bool,
        additions: Set<String>,
        packs: [any TechPack],
        environment: Environment,
        output: CLIOutput
    ) {
        // Ordered so a project-scope sync and a no-op global sync both return before any disk read.
        guard isGlobalScope, !additions.isEmpty else { return }

        let index: ProjectIndex.IndexData
        do {
            index = try ProjectIndex(path: environment.projectsIndexFile).load()
        } catch {
            output.warn("Could not read project index: \(error.localizedDescription)")
            output.plain("  Skipping the check for packs already configured in other projects.")
            return
        }

        let displayNames = Dictionary(
            packs.map { ($0.identifier, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        let lines = projectDuplicationWarning(
            additions: additions,
            displayNames: displayNames,
            index: index
        )
        guard let header = lines.first else { return }

        output.plain("")
        output.warn(header)
        for line in lines.dropFirst() {
            output.plain(line)
        }
    }

    /// Ensure global gitignore core entries are present.
    static func ensureGitignoreEntries(shell: any ShellRunning) throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }

    /// Display a dry-run summary of what sync would do.
    ///
    /// Shared orchestration for both project and global dry-run flows.
    /// Callers provide scope-specific closures for artifact and removal display.
    ///
    /// Returns the pack IDs newly entering this scope, so a caller needing the same diff reuses
    /// this one rather than re-deriving it and risking the two disagreeing.
    @discardableResult
    static func dryRunSummary(
        packs: [any TechPack],
        state: ProjectState,
        header: String,
        output: CLIOutput,
        artifactSummary: (_ pack: any TechPack) -> Void,
        removalSummary: (_ artifacts: PackArtifactRecord) -> Void
    ) -> Set<String> {
        let selectedIDs = Set(packs.map(\.identifier))
        let previousIDs = state.configuredPacks

        let removals = previousIDs.subtracting(selectedIDs)
        let additions = selectedIDs.subtracting(previousIDs)
        let updates = selectedIDs.intersection(previousIDs)

        output.header(header)

        if removals.isEmpty, additions.isEmpty, updates.isEmpty, packs.isEmpty {
            output.plain("")
            output.info("No packs selected. Nothing would change.")
            output.plain("")
            output.dimmed("No changes made (dry run).")
            return additions
        }

        // Show additions
        for pack in packs where additions.contains(pack.identifier) {
            output.plain("")
            output.success("+ \(pack.displayName) (new)")
            artifactSummary(pack)
        }

        // Show removals
        for packID in removals.sorted() {
            output.plain("")
            output.warn("- \(packID) (remove)")
            if let artifacts = state.artifacts(for: packID) {
                removalSummary(artifacts)
            } else {
                output.dimmed("  No artifact record available")
            }
        }

        // Show updates (unchanged packs that would be refreshed)
        for pack in packs where updates.contains(pack.identifier) {
            output.plain("")
            output.info("~ \(pack.displayName) (update)")
            artifactSummary(pack)
        }

        output.plain("")
        let totalChanges = additions.count + removals.count
        if totalChanges == 0 {
            output.info("\(updates.count) pack(s) would be refreshed, no additions or removals.")
        } else {
            var parts: [String] = []
            if !additions.isEmpty { parts.append("+\(additions.count) added") }
            if !removals.isEmpty { parts.append("-\(removals.count) removed") }
            if !updates.isEmpty { parts.append("~\(updates.count) updated") }
            output.info(parts.joined(separator: ", "))
        }
        output.plain("")
        output.dimmed("No changes made (dry run).")
        return additions
    }

    // MARK: - Template Contribution Gathering

    /// Collect template contributions from preloaded templates, warning about packs
    /// whose templates failed to load.
    static func gatherTemplateContributions(
        packs: [any TechPack],
        preloadedTemplates: [String: [TemplateContribution]],
        output: CLIOutput
    ) -> [TemplateContribution] {
        var all: [TemplateContribution] = []
        for pack in packs {
            if let templates = preloadedTemplates[pack.identifier] {
                all.append(contentsOf: templates)
            } else if !pack.templateSectionIdentifiers.isEmpty {
                output.warn("Skipping templates for \(pack.displayName) (failed to load earlier)")
            }
        }
        return all
    }

    // MARK: - Settings Composition Helpers

    /// Merge hook entries, plugin enablements, and settings files from pack components into settings.
    ///
    /// Shared by both project and global `composeSettings` — the inner loop is identical.
    /// The hook directory is parameterized via `hookPathPrefix`.
    ///
    /// Runs in two passes on purpose. `Settings.merge` deduplicates hook groups by command and
    /// keeps the entry already present, so whichever source lands first wins. Derived entries must
    /// be that source: they carry the engine's own scope-correct command path, and they are the
    /// only ones doctor can verify against a `HookRegistration`. A single pass would decide it by
    /// the order components happen to appear in `techpack.yaml`.
    ///
    /// - Returns: Whether any content was added and the per-pack contributed settings keys.
    static func mergePackComponentsIntoSettings(
        packs: [any TechPack],
        settings: inout Settings,
        hookPathPrefix: String,
        resolvedValues: [String: String],
        output: CLIOutput
    ) -> (hasContent: Bool, contributedKeys: [String: [String]]) {
        var hasContent = false
        var contributedKeys: [String: [String]] = [:]

        let packComponents: [(pack: any TechPack, component: ComponentDefinition)] = packs.flatMap { pack in
            pack.components.map { (pack, $0) }
        }

        // Pass 1: entries derived from component definitions.
        for (pack, component) in packComponents {
            if let reg = component.hookRegistration,
               let command = component.hookCommand(pathPrefix: hookPathPrefix) {
                if settings.addHookEntry(
                    event: reg.event,
                    command: command,
                    matcher: reg.matcher,
                    timeout: reg.timeout,
                    isAsync: reg.isAsync,
                    statusMessage: reg.statusMessage
                ) {
                    hasContent = true
                    // Echo anything but the default interpreter, so a value that was inferred
                    // rather than declared is visible rather than magic.
                    if let invocation = component.hookInvocation,
                       !HookInterpreter.isDefault(invocation.interpreter) {
                        output.dimmed("  \(reg.event.rawValue): \(command)")
                    }
                }
            }

            if case let .plugin(name) = component.installAction {
                let ref = PluginRef(name)
                var plugins = settings.enabledPlugins ?? [:]
                if plugins[ref.bareName] == nil {
                    plugins[ref.bareName] = true
                }
                settings.enabledPlugins = plugins
                hasContent = true
                contributedKeys[pack.identifier, default: []].append("enabledPlugins.\(ref.bareName)")
            }
        }

        // Pass 2: pack-supplied settings files, merged on top of the derived entries.
        for (pack, component) in packComponents {
            guard case let .settingsMerge(source) = component.installAction, let source else { continue }
            do {
                let packSettings = try Settings.load(from: source, substituting: resolvedValues)
                if !packSettings.extraJSON.isEmpty {
                    contributedKeys[pack.identifier, default: []].append(contentsOf: packSettings.extraJSON.keys)
                }
                for dropped in settings.merge(with: packSettings) {
                    output.warn(
                        "\(pack.displayName): hook group for '\(dropped.command)' under \(dropped.event)"
                            + " was not merged — \(source.lastPathComponent) declares matcher"
                            + " \(describeMatcher(dropped.incomingMatcher)) but"
                            + " \(describeMatcher(dropped.installedMatcher)) is already registered"
                    )
                }
                hasContent = true
            } catch {
                output.warn(
                    "Could not load settings from \(pack.displayName)/\(source.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return (hasContent, contributedKeys)
    }

    /// Compute per-pack SHA-256 hashes of contributed settings values from the on-disk file.
    ///
    /// Reads the settings file once and hashes each pack's key-value pairs independently.
    /// Returns an empty dictionary if no content was written or the file cannot be read.
    static func computeSettingsHashes(
        hasContent: Bool,
        contributedKeys: [String: [String]],
        settingsPath: URL,
        output: CLIOutput
    ) -> [String: String] {
        guard hasContent else { return [:] }
        let savedData: Data
        do {
            savedData = try Data(contentsOf: settingsPath)
        } catch {
            output.warn("Could not read settings for drift hash: \(error.localizedDescription)")
            return [:]
        }
        let savedJSON: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: savedData) as? [String: Any] else {
                output.warn("Settings file is not a JSON object — skipping drift hash")
                return [:]
            }
            savedJSON = parsed
        } catch {
            output.warn("Could not parse settings for drift hash: \(error.localizedDescription)")
            return [:]
        }
        var hashes: [String: String] = [:]
        for (packID, keys) in contributedKeys {
            if let hash = SettingsHasher.hash(keyPaths: keys, in: savedJSON) {
                hashes[packID] = hash
            }
        }
        return hashes
    }

    // MARK: - Repo Name Parsing

    /// Parse the repository name from a git remote URL.
    ///
    /// Handles any URL with a scheme (`://`) and SCP-style SSH formats:
    /// - `https://github.com/user/repo.git` → `repo`
    /// - `git@github.com:user/repo.git` → `repo`
    /// - `ssh://git@github.com/user/repo.git` → `repo`
    /// - `file:///Users/dev/repos/my-repo.git` → `my-repo`
    /// - `https://github.com/user/repo` (no `.git`) → `repo`
    ///
    /// Returns `nil` if the URL cannot be parsed.
    static func parseRepoName(from remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lastComponent: String

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { return nil }
            lastComponent = url.lastPathComponent
        } else if let colonIndex = trimmed.firstIndex(of: ":") {
            // SCP-style: git@host:user/repo.git
            let afterColon = trimmed[trimmed.index(after: colonIndex)...]
            guard let last = afterColon.split(separator: "/").last else { return nil }
            lastComponent = String(last)
        } else {
            return nil
        }

        guard !lastComponent.isEmpty, lastComponent != "/" else { return nil }

        let name = lastComponent.strippingGitSuffix
        return name.isEmpty ? nil : name
    }

    // MARK: - Placeholder Scanning

    /// Find all `__PLACEHOLDER__` tokens in a file or directory of files.
    /// Recurses into subdirectories. Reads as Data first to distinguish
    /// I/O errors from binary files (which are legitimately skipped).
    static func findPlaceholdersInSource(_ source: URL) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { return [] }

        guard isDir.boolValue else {
            guard let data = try? Data(contentsOf: source),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return TemplateEngine.findUnreplacedPlaceholders(in: text)
        }

        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            results.append(contentsOf: TemplateEngine.findUnreplacedPlaceholders(in: text))
        }
        return results
    }

    /// Strip `__` delimiters from a placeholder token (e.g. `__FOO__` → `FOO`).
    static func stripPlaceholderDelimiters(_ token: String) -> String {
        String(token.dropFirst(2).dropLast(2))
    }

    /// Every `__PLACEHOLDER__` key the packs' `copyPackFile` sources, settings files, MCP
    /// configs and (optionally) templates reference, as bare keys (without `__` delimiters).
    static func referencedPlaceholderKeys(
        packs: [any TechPack],
        includeTemplates: Bool = false,
        onWarning: ((String) -> Void)? = nil
    ) -> Set<String> {
        var referenced = Set<String>()

        let collectReferenced = { (placeholder: String) in
            _ = referenced.insert(stripPlaceholderDelimiters(placeholder))
        }

        for pack in packs {
            for component in pack.components {
                switch component.installAction {
                case let .copyPackFile(source, _, _):
                    findPlaceholdersInSource(source).forEach(collectReferenced)

                case let .settingsMerge(source):
                    if let source {
                        findPlaceholdersInSource(source).forEach(collectReferenced)
                    }

                case let .mcpServer(config):
                    for text in config.env.values {
                        TemplateEngine.findUnreplacedPlaceholders(in: text).forEach(collectReferenced)
                    }
                    TemplateEngine.findUnreplacedPlaceholders(in: config.command).forEach(collectReferenced)
                    for text in config.args {
                        TemplateEngine.findUnreplacedPlaceholders(in: text).forEach(collectReferenced)
                    }

                default:
                    break
                }
            }

            if includeTemplates {
                do {
                    for template in try pack.templates {
                        TemplateEngine.findUnreplacedPlaceholders(in: template.templateContent)
                            .forEach(collectReferenced)
                    }
                } catch {
                    onWarning?("Could not scan templates for \(pack.displayName): \(error.localizedDescription)")
                }
            }
        }

        return referenced
    }
}
