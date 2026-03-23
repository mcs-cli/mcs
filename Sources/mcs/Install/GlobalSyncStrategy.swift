import Foundation

/// Global-scoped sync strategy.
///
/// Targets `~/.claude/` for file installation, overrides MCP scope to `"user"`,
/// loads existing `settings.json` preserving user content, and composes
/// `~/.claude/CLAUDE.md` with a three-way placeholder prompt.
struct GlobalSyncStrategy: SyncStrategy {
    let scope: SyncScope
    let environment: Environment

    init(environment: Environment) {
        scope = .global(environment: environment)
        self.environment = environment
    }

    // MARK: - Template Values

    func resolveBuiltInValues(shell _: any ShellRunning, output _: CLIOutput) -> [String: String] {
        [:]
    }

    func makeConfigContext(output: CLIOutput, resolvedValues: [String: String]) -> ProjectConfigContext {
        ProjectConfigContext(
            projectPath: environment.homeDirectory,
            repoName: "",
            output: output,
            resolvedValues: resolvedValues,
            isGlobalScope: true
        )
    }

    // MARK: - Artifact Installation

    func installArtifacts(
        _ pack: any TechPack,
        previousArtifacts: PackArtifactRecord?,
        excludedIDs: Set<String>,
        resolvedValues: [String: String],
        preloadedTemplates: [TemplateContribution]?,
        executor: inout ComponentExecutor,
        shell: any ShellRunning,
        output: CLIOutput
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()
        // Carry forward ownership records from previous sync
        artifacts.brewPackages = previousArtifacts?.brewPackages ?? []
        artifacts.plugins = previousArtifacts?.plugins ?? []

        for component in pack.components {
            if excludedIDs.contains(component.id) {
                output.dimmed("  \(component.displayName) excluded, skipping")
                continue
            }

            if ComponentExecutor.isAlreadyInstalled(component) {
                output.dimmed("  \(component.displayName) already installed, skipping")
                continue
            }

            switch component.installAction {
            case let .brewInstall(package):
                output.dimmed("  Installing \(component.displayName)...")
                if executor.installBrewPackage(package) {
                    artifacts.recordBrewPackage(package)
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) failed to install")
                }

            case let .mcpServer(config):
                let resolved = config.substituting(resolvedValues)
                let globalConfig = MCPServerConfig(
                    name: resolved.name,
                    command: resolved.command,
                    args: resolved.args,
                    env: resolved.env,
                    scope: Constants.MCPScope.user
                )
                if executor.installMCPServer(globalConfig) {
                    artifacts.mcpServers.append(MCPServerRef(
                        name: resolved.name,
                        scope: Constants.MCPScope.user
                    ))
                    output.success("  \(component.displayName) registered (scope: user)")
                }

            case let .plugin(name):
                output.dimmed("  Installing plugin \(component.displayName)...")
                if executor.installPlugin(name) {
                    artifacts.recordPlugin(name)
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) failed to install")
                }

            case let .copyPackFile(source, destination, fileType):
                let result = executor.installCopyPackFile(
                    source: source,
                    destination: destination,
                    fileType: fileType,
                    resolvedValues: resolvedValues
                )
                if result.success {
                    let relativePath = fileRelativePath(destination: destination, fileType: fileType)
                    artifacts.files.append(relativePath)
                    artifacts.fileHashes.merge(result.hashes) { _, new in new }
                    if component.type == .hookFile,
                       component.hookRegistration != nil,
                       fileType == .hook {
                        artifacts.hookCommands.append("\(scope.hookCommandPrefix)\(destination)")
                    }
                    output.success("  \(component.displayName) installed")
                }

            case let .gitignoreEntries(entries):
                if executor.addGitignoreEntries(entries) {
                    artifacts.gitignoreEntries.append(contentsOf: entries)
                }

            case let .shellCommand(command):
                output.dimmed("  Running \(component.displayName)...")
                let result = shell.shell(command)
                if result.succeeded {
                    output.success("  \(component.displayName) installed")
                } else {
                    output.warn("  \(component.displayName) requires manual installation:")
                    output.plain("    \(command)")
                    if !result.stderr.isEmpty {
                        output.dimmed("  Error: \(String(result.stderr.prefix(200)))")
                    }
                    output.dimmed("  Run the command above in your terminal, then re-run '\(scope.syncHint)'.")
                }

            case .settingsMerge:
                break
            }
        }

        // Track template sections from pre-loaded cache only — if loading failed earlier,
        // we must not record sections that were never written (unlike project scope, which
        // falls back to pack.templateSectionIdentifiers as a best-effort record).
        if let templates = preloadedTemplates {
            artifacts.templateSections = templates.map(\.sectionIdentifier)
        }

        return artifacts
    }

    // MARK: - Settings Composition

    func composeSettings(
        packs: [any TechPack],
        excludedComponents: [String: Set<String>],
        previousSettingsKeys: [String: [String]],
        resolvedValues: [String: String],
        output: CLIOutput
    ) throws -> (contributedKeys: [String: [String]], settingsHashes: [String: String]) {
        var settings: Settings
        do {
            settings = try Settings.load(from: scope.settingsPath)
        } catch {
            output.error("Could not parse \(scope.settingsPath.path): \(error.localizedDescription)")
            output.error("Fix the JSON syntax or rename the file, then re-run '\(scope.syncHint)'.")
            throw MCSError.fileOperationFailed(
                path: scope.settingsPath.path,
                reason: "Invalid JSON: \(error.localizedDescription)"
            )
        }

        // Strip mcs-managed hook entries before re-composing
        if var hooks = settings.hooks {
            for (event, groups) in hooks {
                hooks[event] = groups.filter { group in
                    guard let cmd = group.hooks?.first?.command else { return true }
                    return !cmd.hasPrefix(scope.hookCommandPrefix)
                }
            }
            hooks = hooks.filter { !$0.value.isEmpty }
            settings.hooks = hooks.isEmpty ? nil : hooks
        }

        // Strip previously-tracked settings keys (enabledPlugins + settingsMerge extraJSON)
        // before re-composing, so removed components don't leave stale entries.
        let allPreviousKeys = previousSettingsKeys.values.flatMap(\.self)
        if !allPreviousKeys.isEmpty {
            settings.removeKeys(allPreviousKeys)
        }

        // Collect top-level keys to pass as dropKeys, preventing Layer 3 re-injection
        let dropKeys = Set(allPreviousKeys.filter { !$0.contains(".") })

        let (hasContent, contributedKeys) = ConfiguratorSupport.mergePackComponentsIntoSettings(
            packs: packs,
            excludedComponents: excludedComponents,
            settings: &settings,
            hookCommandPrefix: scope.hookCommandPrefix,
            resolvedValues: resolvedValues,
            output: output
        )

        if hasContent {
            do {
                try settings.save(to: scope.settingsPath, dropKeys: dropKeys)
                output.success("Composed settings.json (global)")
            } catch {
                output.error("Could not write settings.json: \(error.localizedDescription)")
                output.error("Hooks and plugins will not be active. Re-run '\(scope.syncHint)' after fixing the issue.")
                throw MCSError.fileOperationFailed(
                    path: scope.settingsPath.path,
                    reason: error.localizedDescription
                )
            }
        }

        let settingsHashes = ConfiguratorSupport.computeSettingsHashes(
            hasContent: hasContent,
            contributedKeys: contributedKeys,
            settingsPath: scope.settingsPath,
            output: output
        )

        return (contributedKeys, settingsHashes)
    }

    // MARK: - CLAUDE.md Composition

    @discardableResult
    func composeClaude(
        packs: [any TechPack],
        preloadedTemplates: [String: [TemplateContribution]],
        values: [String: String],
        output: CLIOutput
    ) throws -> Set<String>? {
        var allContributions = ConfiguratorSupport.gatherTemplateContributions(
            packs: packs, preloadedTemplates: preloadedTemplates, output: output
        )

        guard !allContributions.isEmpty else { return nil }

        // Check for unreplaced placeholders before writing
        var placeholdersBySectionID: [String: [String]] = [:]
        for contribution in allContributions {
            let rendered = TemplateEngine.substitute(
                template: contribution.templateContent,
                values: values,
                emitWarnings: false
            )
            let unreplaced = TemplateEngine.findUnreplacedPlaceholders(in: rendered)
            if !unreplaced.isEmpty {
                placeholdersBySectionID[contribution.sectionIdentifier] = unreplaced
            }
        }

        if !placeholdersBySectionID.isEmpty {
            output.warn("Global templates contain placeholders that cannot be resolved:")
            for (sectionID, placeholders) in placeholdersBySectionID.sorted(by: { $0.key < $1.key }) {
                output.warn("  \(placeholders.joined(separator: ", ")) in: \(sectionID)")
            }
            output.plain("")

            let choice = promptPlaceholderAction(output: output)
            switch choice {
            case .proceed:
                break
            case .skip:
                allContributions.removeAll { placeholdersBySectionID.keys.contains($0.sectionIdentifier) }
                if allContributions.isEmpty {
                    output.info("All template sections contained unresolved placeholders — skipping CLAUDE.md composition.")
                    return Set()
                }
            case .stop:
                throw MCSError.configurationFailed(
                    reason: "Aborted: templates contain unresolved placeholders. "
                        + "Remove project-scoped placeholders from global templates or provide values via pack prompts."
                )
            }
        }

        let fm = FileManager.default
        let existingContent: String? = fm.fileExists(atPath: scope.claudeFilePath.path)
            ? try String(contentsOf: scope.claudeFilePath, encoding: .utf8)
            : nil

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existingContent,
            contributions: allContributions,
            values: values,
            emitWarnings: false
        )

        for warning in result.warnings {
            output.warn(warning)
        }

        if fm.fileExists(atPath: scope.claudeFilePath.path) {
            var backup = Backup()
            try backup.backupFile(at: scope.claudeFilePath)
        }
        try result.content.write(to: scope.claudeFilePath, atomically: true, encoding: .utf8)
        output.success("Generated \(scope.claudeFilePath.lastPathComponent) (global)")

        return Set(allContributions.map(\.sectionIdentifier))
    }

    // MARK: - File Path Derivation

    func fileRelativePath(destination: String, fileType: CopyFileType) -> String {
        let destURL = fileType.destinationURL(in: environment, destination: destination)
        return PathContainment.relativePath(
            of: destURL.path,
            within: environment.claudeDirectory.path
        )
    }

    // MARK: - File Removal

    func removeFileArtifact(relativePath: String, output: CLIOutput) -> Bool {
        let fm = FileManager.default
        guard let fullPath = PathContainment.safePath(
            relativePath: relativePath,
            within: environment.claudeDirectory
        ) else {
            output.warn("Path '\(relativePath)' escapes claude directory — clearing from tracking")
            return true
        }

        guard fm.fileExists(atPath: fullPath.path) else {
            return true
        }

        do {
            try fm.removeItem(at: fullPath)
            output.dimmed("  Removed: \(relativePath)")
            return true
        } catch {
            output.warn("  Could not remove \(relativePath): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Helpers

    private enum PlaceholderAction {
        case proceed, skip, stop
    }

    private func promptPlaceholderAction(output: CLIOutput) -> PlaceholderAction {
        output.plain("  [p]roceed — include sections with unresolved placeholders")
        output.plain("  [s]kip    — omit sections containing unresolved placeholders")
        output.plain("  s[t]op    — abort global sync")
        while true {
            let answer = output.promptInline("Choose", default: "p").lowercased()
            switch answer.first {
            case "p": return .proceed
            case "s": return .skip
            case "t": return .stop
            default:
                output.plain("  Please enter p, s, or t.")
            }
        }
    }
}
