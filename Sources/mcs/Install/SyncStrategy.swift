import Foundation

/// Strategy protocol capturing the behavioral differences between
/// project-scoped and global-scoped sync.
///
/// Each method maps to a point in the multi-phase convergence flow where
/// the logic (not just data) differs between scopes. Trivially
/// parameterizable differences live in `SyncScope` instead.
protocol SyncStrategy {
    /// The scope-specific data (paths, flags) for this strategy.
    var scope: SyncScope { get }

    /// Resolve built-in template values.
    ///
    /// Project scope resolves `REPO_NAME` and `PROJECT_DIR_NAME` from git.
    /// Global scope returns an empty dictionary.
    func resolveBuiltInValues(shell: any ShellRunning, output: CLIOutput) -> [String: String]

    /// Build the `ProjectConfigContext` for template value resolution.
    func makeConfigContext(output: CLIOutput, resolvedValues: [String: String]) -> ProjectConfigContext

    /// Install artifacts for a single pack.
    ///
    /// Project scope uses `ComponentExecutor.installProjectFile` with project-relative paths.
    /// Global scope uses `ComponentExecutor.installCopyPackFile` with `~/.claude/`-relative paths,
    /// overrides MCP scope to `"user"`, and carries forward brew/plugin ownership.
    ///
    /// - Returns: A `PackArtifactRecord` tracking what was installed.
    func installArtifacts(
        _ pack: any TechPack,
        previousArtifacts: PackArtifactRecord?,
        excludedIDs: Set<String>,
        resolvedValues: [String: String],
        preloadedTemplates: [TemplateContribution]?,
        executor: inout ComponentExecutor,
        shell: any ShellRunning,
        output: CLIOutput
    ) -> PackArtifactRecord

    /// Compose the settings file from all selected packs.
    ///
    /// Project scope creates `settings.local.json` from scratch, deletes it when empty.
    /// Global scope loads existing `settings.json`, strips managed hooks, and preserves user content.
    ///
    /// - Parameter previousSettingsKeys: Settings keys tracked in the previous sync's artifact records.
    ///   Global scope uses these to strip stale keys before recomposing; both scopes derive
    ///   `dropKeys` from them to prevent Layer 3 re-injection during `Settings.save()`.
    /// - Returns: A mapping of pack ID to contributed extraJSON key paths,
    ///   and per-pack SHA-256 hashes of the contributed values for drift detection.
    func composeSettings(
        packs: [any TechPack],
        excludedComponents: [String: Set<String>],
        previousSettingsKeys: [String: [String]],
        resolvedValues: [String: String],
        output: CLIOutput
    ) throws -> (contributedKeys: [String: [String]], settingsHashes: [String: String])

    /// Compose the CLAUDE markdown file from template contributions.
    ///
    /// Project scope warns on unreplaced placeholders.
    /// Global scope presents a three-way prompt (proceed/skip/stop).
    ///
    /// - Returns: The set of section identifiers actually written,
    ///   or `nil` if no contributions existed (nothing to reconcile).
    @discardableResult
    func composeClaude(
        packs: [any TechPack],
        preloadedTemplates: [String: [TemplateContribution]],
        values: [String: String],
        output: CLIOutput
    ) throws -> Set<String>?

    /// Build a filesystem context for collision resolution.
    ///
    /// Returns a `CollisionFilesystemContext` that enables the resolver to detect
    /// pre-existing user files at `copyPackFile` destinations.
    /// Every conformance must implement this — returning `nil` disables user-file protection
    /// and hook namespacing (only cross-pack collisions are resolved).
    func makeCollisionContext(trackedFiles: Set<String>) -> (any CollisionFilesystemContext)?

    /// Derive the relative file path that artifact tracking records for a `copyPackFile` component.
    ///
    /// Global scope computes relative to `~/.claude/`.
    /// Project scope computes relative to the project root.
    func fileRelativePath(destination: String, fileType: CopyFileType) -> String

    /// Remove a file artifact during pack unconfiguration.
    ///
    /// Project scope uses `ComponentExecutor.removeProjectFile`.
    /// Global scope uses `FileManager.removeItem` with `PathContainment` safety.
    ///
    /// - Returns: `true` if the file was removed or already absent.
    func removeFileArtifact(relativePath: String, output: CLIOutput) -> Bool

    /// Print what a pack would install (for dry-run artifact display).
    func printArtifactSummary(_ pack: any TechPack, output: CLIOutput)

    /// Print what a removal would clean up (for dry-run and confirmation display).
    func printRemovalSummary(_ artifacts: PackArtifactRecord, output: CLIOutput)
}

// MARK: - Default Implementations

extension SyncStrategy {
    /// Default removal summary — prints all non-empty artifact fields.
    ///
    /// Uses `scope.claudeFilePath.lastPathComponent` for template section labels.
    /// Empty arrays are naturally skipped (loop body never executes).
    func printRemovalSummary(_ artifacts: PackArtifactRecord, output: CLIOutput) {
        for server in artifacts.mcpServers {
            output.dimmed("      MCP server: \(server.name)")
        }
        for path in artifacts.files {
            output.dimmed("      File: \(path)")
        }
        for pkg in artifacts.brewPackages {
            output.dimmed("      Brew package: \(pkg)")
        }
        for plugin in artifacts.plugins {
            output.dimmed("      Plugin: \(PluginRef(plugin).bareName)")
        }
        let claudeFileName = scope.claudeFilePath.lastPathComponent
        for section in artifacts.templateSections {
            output.dimmed("      \(claudeFileName) section: \(section)")
        }
        for cmd in artifacts.hookCommands {
            output.dimmed("      Hook: \(cmd)")
        }
    }

    /// Default artifact summary — prints what a pack would install.
    ///
    /// Uses `scope.mcpScopeOverride`, `scope.fileDisplayPrefix`, and
    /// `scope.claudeFilePath.lastPathComponent` to parameterize display.
    func printArtifactSummary(_ pack: any TechPack, output: CLIOutput) {
        let mcpServers = pack.components.compactMap { component -> String? in
            if case let .mcpServer(config) = component.installAction {
                let displayScope = scope.mcpScopeOverride ?? config.resolvedScope
                return "+\(config.name) (\(displayScope))"
            }
            return nil
        }
        if !mcpServers.isEmpty {
            output.dimmed("  MCP servers:  \(mcpServers.joined(separator: ", "))")
        }

        let files = pack.components.compactMap { component -> String? in
            if case let .copyPackFile(_, destination, fileType) = component.installAction {
                return "+\(scope.fileDisplayPrefix)\(fileType.subdirectory)\(destination)"
            }
            return nil
        }
        if !files.isEmpty {
            output.dimmed("  Files:        \(files.joined(separator: ", "))")
        }

        let brewPackages = pack.components.compactMap { component -> String? in
            if case let .brewInstall(package) = component.installAction {
                return package
            }
            return nil
        }
        if !brewPackages.isEmpty {
            let suffix = scope.isGlobalScope ? "" : " (global)"
            output.dimmed("  Brew:         \(brewPackages.joined(separator: ", "))\(suffix)")
        }

        let plugins = pack.components.compactMap { component -> String? in
            if case let .plugin(name) = component.installAction {
                return PluginRef(name).bareName
            }
            return nil
        }
        if !plugins.isEmpty {
            let suffix = scope.isGlobalScope ? "" : " (global)"
            output.dimmed("  Plugins:      \(plugins.joined(separator: ", "))\(suffix)")
        }

        let templateSections = pack.templateSectionIdentifiers.map { "+\($0) section" }
        if !templateSections.isEmpty {
            let claudeFileName = scope.claudeFilePath.lastPathComponent
            output.dimmed("  Templates:    \(templateSections.joined(separator: ", ")) in \(claudeFileName)")
        }

        let settingsFiles = pack.components.compactMap { component -> String? in
            if case let .settingsMerge(source) = component.installAction, source != nil {
                return "+settings merge from \(component.displayName)"
            }
            return nil
        }
        if !settingsFiles.isEmpty {
            output.dimmed("  Settings:     \(settingsFiles.joined(separator: ", "))")
        }
    }
}
