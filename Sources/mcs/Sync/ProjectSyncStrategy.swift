import Foundation

/// Project-scoped sync strategy.
///
/// Targets `<project>/.claude/` for file installation, uses project-relative
/// paths for artifact tracking, creates `settings.local.json` from scratch,
/// and composes `CLAUDE.local.md` at the project root.
struct ProjectSyncStrategy: SyncStrategy {
    let scope: SyncScope
    let environment: Environment
    let projectPath: URL

    init(projectPath: URL, environment: Environment) {
        self.projectPath = projectPath
        scope = .project(at: projectPath, environment: environment)
        self.environment = environment
    }

    // MARK: - Template Values

    func resolveBuiltInValues(shell: any ShellRunning, output: CLIOutput) -> [String: String] {
        let repoName = resolveRepoName(shell: shell, output: output)
        let projectDirName = resolveProjectDirName(shell: shell)
        return [
            "REPO_NAME": repoName,
            "PROJECT_DIR_NAME": projectDirName,
        ]
    }

    func makeConfigContext(output: CLIOutput, resolvedValues: [String: String]) -> ProjectConfigContext {
        ProjectConfigContext(
            projectPath: projectPath,
            repoName: resolvedValues["REPO_NAME"] ?? projectPath.lastPathComponent,
            output: output,
            resolvedValues: resolvedValues
        )
    }

    // MARK: - Collision Context

    func makeCollisionContext(trackedFiles: Set<String>) -> (any CollisionFilesystemContext)? {
        ProjectCollisionContext(projectPath: projectPath, trackedFiles: trackedFiles)
    }

    // MARK: - Artifact Installation

    func installArtifacts(
        _ pack: any TechPack,
        previousArtifacts _: PackArtifactRecord?,
        excludedIDs: Set<String>,
        resolvedValues: [String: String],
        preloadedTemplates: [TemplateContribution]?,
        executor: inout ComponentExecutor,
        shell: any ShellRunning,
        output: CLIOutput
    ) -> PackArtifactRecord {
        var artifacts = PackArtifactRecord()

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
            case let .mcpServer(config):
                let resolved = config.substituting(resolvedValues)
                if executor.installMCPServer(resolved) {
                    artifacts.mcpServers.append(MCPServerRef(
                        name: resolved.name,
                        scope: resolved.resolvedScope
                    ))
                    output.success("  \(component.displayName) registered")
                }

            case let .copyPackFile(source, destination, fileType):
                let result = executor.installProjectFile(
                    source: source,
                    destination: destination,
                    fileType: fileType,
                    projectPath: projectPath,
                    resolvedValues: resolvedValues
                )
                artifacts.files.append(contentsOf: result.paths)
                artifacts.fileHashes.merge(result.hashes) { _, new in new }
                if component.type == .hookFile,
                   component.hookRegistration != nil,
                   fileType == .hook {
                    artifacts.hookCommands.append("\(scope.hookCommandPrefix)\(destination)")
                }
                if !result.paths.isEmpty {
                    output.success("  \(component.displayName) installed")
                }

            case let .gitignoreEntries(entries):
                if executor.addGitignoreEntries(entries) {
                    artifacts.gitignoreEntries.append(contentsOf: entries)
                }

            case .brewInstall, .plugin:
                break

            case let .shellCommand(command):
                let result = shell.shell(command)
                if !result.succeeded {
                    output.warn("  \(component.displayName) failed: \(String(result.stderr.prefix(200)))")
                }

            case .settingsMerge:
                break
            }
        }

        if let templates = preloadedTemplates {
            artifacts.templateSections = templates.map(\.sectionIdentifier)
        } else {
            artifacts.templateSections = pack.templateSectionIdentifiers
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
        var settings = Settings()

        // Collect top-level keys to prevent Layer 3 re-injection of stale extraJSON keys
        let allPreviousKeys = previousSettingsKeys.values.flatMap(\.self)
        let dropKeys = Set(allPreviousKeys.filter { !$0.contains(".") })

        var (hasContent, contributedKeys) = ConfiguratorSupport.mergePackComponentsIntoSettings(
            packs: packs,
            excludedComponents: excludedComponents,
            settings: &settings,
            hookCommandPrefix: scope.hookCommandPrefix,
            resolvedValues: resolvedValues,
            output: output
        )

        // Inject first-party update check hook if enabled
        let config = MCSConfig.load(from: environment.mcsConfigFile, output: output)
        if config.isUpdateCheckEnabled {
            if UpdateChecker.addHook(to: &settings) { hasContent = true }
        }

        if hasContent {
            do {
                try settings.save(to: scope.settingsPath, dropKeys: dropKeys)
                output.success("Composed settings.local.json")
            } catch {
                output.error("Could not write settings.local.json: \(error.localizedDescription)")
                output.error("Hooks and plugins will not be active. Re-run '\(scope.syncHint)' after fixing the issue.")
                throw MCSError.fileOperationFailed(
                    path: Constants.FileNames.settingsLocal,
                    reason: error.localizedDescription
                )
            }
        } else if FileManager.default.fileExists(atPath: scope.settingsPath.path) {
            do {
                try FileManager.default.removeItem(at: scope.settingsPath)
                output.dimmed("Removed empty settings.local.json")
            } catch {
                output.warn("Could not remove stale settings.local.json: \(error.localizedDescription)")
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

    // MARK: - CLAUDE.local.md Composition

    @discardableResult
    func composeClaude(
        packs: [any TechPack],
        preloadedTemplates: [String: [TemplateContribution]],
        values: [String: String],
        output: CLIOutput
    ) throws -> Set<String>? {
        let allContributions = ConfiguratorSupport.gatherTemplateContributions(
            packs: packs, preloadedTemplates: preloadedTemplates, output: output
        )

        guard !allContributions.isEmpty else {
            output.info("No template sections to add — skipping \(scope.claudeFilePath.lastPathComponent)")
            return nil
        }

        let fm = FileManager.default
        let existingContent: String? = fm.fileExists(atPath: scope.claudeFilePath.path)
            ? try String(contentsOf: scope.claudeFilePath, encoding: .utf8)
            : nil

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existingContent,
            contributions: allContributions,
            values: values
        )

        for warning in result.warnings {
            output.warn(warning)
        }

        if fm.fileExists(atPath: scope.claudeFilePath.path) {
            var backup = Backup()
            try backup.backupFile(at: scope.claudeFilePath)
        }
        try result.content.write(to: scope.claudeFilePath, atomically: true, encoding: .utf8)
        output.success("Generated \(scope.claudeFilePath.lastPathComponent)")

        return Set(allContributions.map(\.sectionIdentifier))
    }

    // MARK: - File Path Derivation

    func fileRelativePath(destination: String, fileType: CopyFileType) -> String {
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)
        let destURL = baseDir.appendingPathComponent(destination)
        return PathContainment.relativePath(
            of: destURL.path,
            within: projectPath.path
        )
    }

    // MARK: - File Removal

    func removeFileArtifact(relativePath: String, output: CLIOutput) -> Bool {
        let fm = FileManager.default
        guard let fullPath = PathContainment.safePath(
            relativePath: relativePath,
            within: projectPath
        ) else {
            output.warn("Path '\(relativePath)' escapes project directory — clearing from tracking")
            return true
        }

        guard fm.fileExists(atPath: fullPath.path) else { return true }

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

    private func resolveRepoName(shell: any ShellRunning, output: CLIOutput) -> String {
        let remoteResult = shell.run(
            shell.environment.gitPath,
            arguments: ["-C", projectPath.path, "remote", "get-url", "origin"]
        )
        if remoteResult.succeeded, !remoteResult.stdout.isEmpty {
            if let parsed = ConfiguratorSupport.parseRepoName(from: remoteResult.stdout) {
                return parsed
            }
            output.warn(
                "Could not parse repo name from remote URL '\(remoteResult.stdout)'"
                    + " — falling back to directory name"
            )
        }
        return resolveProjectDirName(shell: shell)
    }

    private func resolveProjectDirName(shell: any ShellRunning) -> String {
        let gitResult = shell.run(
            shell.environment.gitPath,
            arguments: ["-C", projectPath.path, "rev-parse", "--show-toplevel"]
        )
        if gitResult.succeeded, !gitResult.stdout.isEmpty {
            return URL(fileURLWithPath: gitResult.stdout).lastPathComponent
        }
        return projectPath.lastPathComponent
    }
}
