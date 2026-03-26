import Foundation

/// Shared utilities for the `Configurator` and `SyncStrategy` implementations.
///
/// Eliminates duplication of common methods that both configurators need.
enum ConfiguratorSupport {
    /// Build a `ComponentExecutor` from the common dependencies.
    static func makeExecutor(
        environment: Environment,
        output: CLIOutput,
        shell: any ShellRunning,
        claudeCLI: (any ClaudeCLI)? = nil
    ) -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell,
            claudeCLI: claudeCLI ?? ClaudeIntegration(shell: shell)
        )
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
    static func dryRunSummary(
        packs: [any TechPack],
        state: ProjectState,
        header: String,
        output: CLIOutput,
        artifactSummary: (_ pack: any TechPack) -> Void,
        removalSummary: (_ artifacts: PackArtifactRecord) -> Void
    ) {
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
            return
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
    }

    /// Present per-pack component multi-select and return excluded component IDs.
    ///
    /// - Parameter componentsProvider: Extracts the relevant components from a pack.
    ///   Defaults to all components. Callers can supply a custom filter if needed.
    static func selectComponentExclusions(
        packs: [any TechPack],
        previousState: ProjectState,
        output: CLIOutput,
        componentsProvider: (any TechPack) -> [ComponentDefinition] = { $0.components }
    ) -> [String: Set<String>] {
        var exclusions: [String: Set<String>] = [:]

        for pack in packs {
            let components = componentsProvider(pack)
            guard components.count > 1 else { continue }

            output.plain("")
            output.info("Components for \(pack.displayName):")

            let previousExcluded = previousState.excludedComponents(for: pack.identifier)

            let items = components.enumerated().map { index, component in
                SelectableItem(
                    number: index + 1,
                    name: component.displayName,
                    description: component.description,
                    isSelected: !previousExcluded.contains(component.id)
                )
            }

            let requiredItems = components
                .filter(\.isRequired)
                .map { RequiredItem(name: $0.displayName) }

            var groups = [SelectableGroup(
                title: pack.displayName,
                items: items,
                requiredItems: requiredItems
            )]

            let selectedNumbers = output.multiSelect(groups: &groups)

            var excluded = Set<String>()
            for (index, component) in components.enumerated() {
                if !selectedNumbers.contains(index + 1), !component.isRequired {
                    excluded.insert(component.id)
                }
            }

            if !excluded.isEmpty {
                exclusions[pack.identifier] = excluded
            }
        }

        return exclusions
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
    /// The hook command prefix is parameterized via `hookCommandPrefix`.
    ///
    /// - Returns: Whether any content was added and the per-pack contributed settings keys.
    static func mergePackComponentsIntoSettings(
        packs: [any TechPack],
        excludedComponents: [String: Set<String>],
        settings: inout Settings,
        hookCommandPrefix: String,
        resolvedValues: [String: String],
        output: CLIOutput
    ) -> (hasContent: Bool, contributedKeys: [String: [String]]) {
        var hasContent = false
        var contributedKeys: [String: [String]] = [:]

        for pack in packs {
            let excluded = excludedComponents[pack.identifier] ?? []
            for component in pack.components {
                guard !excluded.contains(component.id) else { continue }

                if component.type == .hookFile,
                   let reg = component.hookRegistration,
                   case let .copyPackFile(_, destination, .hook) = component.installAction {
                    let command = "\(hookCommandPrefix)\(destination)"
                    if settings.addHookEntry(
                        event: reg.event,
                        command: command,
                        timeout: reg.timeout,
                        isAsync: reg.isAsync,
                        statusMessage: reg.statusMessage
                    ) {
                        hasContent = true
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

                if case let .settingsMerge(source) = component.installAction, let source {
                    do {
                        let packSettings = try Settings.load(from: source, substituting: resolvedValues)
                        if !packSettings.extraJSON.isEmpty {
                            contributedKeys[pack.identifier, default: []].append(contentsOf: packSettings.extraJSON.keys)
                        }
                        settings.merge(with: packSettings)
                        hasContent = true
                    } catch {
                        output.warn(
                            "Could not load settings from \(pack.displayName)/\(source.lastPathComponent): \(error.localizedDescription)"
                        )
                    }
                }
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

    /// Scan all `copyPackFile` sources (and optionally template content) for
    /// `__PLACEHOLDER__` tokens not covered by resolved values.
    /// Returns bare keys (without `__` delimiters) sorted alphabetically.
    static func scanForUndeclaredPlaceholders(
        packs: [any TechPack],
        resolvedValues: [String: String],
        includeTemplates: Bool = false,
        onWarning: ((String) -> Void)? = nil
    ) -> [String] {
        var undeclared = Set<String>()
        let resolvedKeys = Set(resolvedValues.keys)

        let collectUndeclared = { (placeholder: String) in
            let key = stripPlaceholderDelimiters(placeholder)
            if !resolvedKeys.contains(key) {
                undeclared.insert(key)
            }
        }

        for pack in packs {
            for component in pack.components {
                switch component.installAction {
                case let .copyPackFile(source, _, _):
                    findPlaceholdersInSource(source).forEach(collectUndeclared)

                case let .settingsMerge(source):
                    if let source {
                        findPlaceholdersInSource(source).forEach(collectUndeclared)
                    }

                case let .mcpServer(config):
                    for text in config.env.values {
                        TemplateEngine.findUnreplacedPlaceholders(in: text).forEach(collectUndeclared)
                    }
                    TemplateEngine.findUnreplacedPlaceholders(in: config.command).forEach(collectUndeclared)
                    for text in config.args {
                        TemplateEngine.findUnreplacedPlaceholders(in: text).forEach(collectUndeclared)
                    }

                default:
                    break
                }
            }

            if includeTemplates {
                do {
                    for template in try pack.templates {
                        TemplateEngine.findUnreplacedPlaceholders(in: template.templateContent)
                            .forEach(collectUndeclared)
                    }
                } catch {
                    onWarning?("Could not scan templates for \(pack.displayName): \(error.localizedDescription)")
                }
            }
        }

        return undeclared.sorted()
    }
}
