import Foundation

/// Discovers existing Claude Code configuration artifacts from live config files.
/// This is the "read" side of the export wizard — it scans settings, MCP servers,
/// .claude/ directories, CLAUDE.md sections, and gitignore to build a complete
/// picture of what's currently configured.
struct ConfigurationDiscovery {
    let environment: Environment
    let output: CLIOutput

    // MARK: - Discovered Artifact Models

    struct DiscoveredConfiguration {
        var mcpServers: [DiscoveredMCPServer] = []
        var hookFiles: [DiscoveredFile] = []
        var skillFiles: [DiscoveredFile] = []
        var commandFiles: [DiscoveredFile] = []
        var agentFiles: [DiscoveredFile] = []
        var plugins: [String] = []
        var claudeSections: [DiscoveredClaudeSection] = []
        var claudeUserContent: String?
        var gitignoreEntries: [String] = []
        /// Remaining settings (non-hook, non-plugin) as serialized JSON data.
        /// Stored as `Data` for Sendable compliance.
        var remainingSettingsData: Data?

        var isEmpty: Bool {
            mcpServers.isEmpty && hookFiles.isEmpty && skillFiles.isEmpty
                && commandFiles.isEmpty && agentFiles.isEmpty && plugins.isEmpty && claudeSections.isEmpty
                && claudeUserContent == nil && gitignoreEntries.isEmpty
                && remainingSettingsData == nil
        }
    }

    struct DiscoveredMCPServer {
        let name: String
        let command: String?
        let args: [String]
        let env: [String: String]
        let url: String?
        let scope: String

        var isHTTP: Bool {
            url != nil
        }
    }

    struct DiscoveredFile {
        let filename: String
        let absolutePath: URL
        let hookRegistration: HookRegistration?

        init(filename: String, absolutePath: URL, hookRegistration: HookRegistration? = nil) {
            self.filename = filename
            self.absolutePath = absolutePath
            self.hookRegistration = hookRegistration
        }
    }

    struct DiscoveredClaudeSection {
        let sectionIdentifier: String
        let content: String
    }

    // MARK: - Scope Configuration

    /// Where to discover: global (~/.claude/) or project (<project>/.claude/).
    enum Scope {
        case global
        case project(URL)
    }

    // MARK: - Discovery

    /// Discover all configuration artifacts for the given scope.
    func discover(scope: Scope) -> DiscoveredConfiguration {
        var config = DiscoveredConfiguration()

        let settingsPath: URL
        let claudeFilePath: URL
        let hooksDir: URL
        let skillsDir: URL
        let commandsDir: URL
        let agentsDir: URL

        switch scope {
        case .global:
            settingsPath = environment.claudeSettings
            claudeFilePath = environment.globalClaudeMD
            hooksDir = environment.hooksDirectory
            skillsDir = environment.skillsDirectory
            commandsDir = environment.commandsDirectory
            agentsDir = environment.agentsDirectory
        case let .project(projectRoot):
            let claudeDir = projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory)
            settingsPath = claudeDir.appendingPathComponent(Constants.FileNames.settingsLocal)
            claudeFilePath = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
            hooksDir = claudeDir.appendingPathComponent("hooks")
            skillsDir = claudeDir.appendingPathComponent("skills")
            commandsDir = claudeDir.appendingPathComponent("commands")
            agentsDir = claudeDir.appendingPathComponent("agents")
        }

        // 1. Discover MCP servers from ~/.claude.json
        discoverMCPServers(scope: scope, into: &config)

        // 2. Discover settings (hooks, plugins, remaining keys)
        let hookDirectory = switch scope {
        case .global: Constants.HookCommand.globalDirectory
        case .project: Constants.HookCommand.projectDirectory
        }
        let hookCommands = discoverSettings(
            at: settingsPath,
            hookDirectory: hookDirectory,
            into: &config
        )

        // 3. Discover files in .claude/ subdirectories
        discoverFiles(in: hooksDir, hookCommands: hookCommands, into: &config)
        config.skillFiles = listFiles(in: skillsDir)
        config.commandFiles = listFiles(in: commandsDir)
        config.agentFiles = listFiles(in: agentsDir)

        // 4. Discover CLAUDE.md content
        discoverClaudeContent(at: claudeFilePath, into: &config)

        // 5. Discover gitignore entries (global scope only)
        if case .global = scope {
            discoverGitignoreEntries(into: &config)
        }

        return config
    }

    // MARK: - MCP Server Discovery

    private func discoverMCPServers(scope: Scope, into config: inout DiscoveredConfiguration) {
        let claudeJSONPath = environment.claudeJSON
        guard FileManager.default.fileExists(atPath: claudeJSONPath.path) else { return }

        let data: Data
        do {
            data = try Data(contentsOf: claudeJSONPath)
        } catch {
            output.warn("Could not read \(claudeJSONPath.lastPathComponent): \(error.localizedDescription)")
            return
        }

        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                output.warn("Could not parse \(claudeJSONPath.lastPathComponent) as JSON — unexpected format")
                return
            }
            json = parsed
        } catch {
            output.warn("Could not parse \(claudeJSONPath.lastPathComponent): \(error.localizedDescription)")
            return
        }

        switch scope {
        case .global:
            // Read top-level mcpServers (global/user scope)
            if let servers = json[Constants.JSONKeys.mcpServers] as? [String: Any] {
                for (name, value) in servers {
                    if let serverDict = value as? [String: Any] {
                        config.mcpServers.append(parseMCPServer(name: name, dict: serverDict, scope: Constants.MCPScope.user))
                    }
                }
            }
        case let .project(projectRoot):
            if let projects = json[Constants.JSONKeys.projects] as? [String: Any],
               let matchedKey = ProjectDetector.resolveProjectKey(from: projectRoot, in: Set(projects.keys)),
               let projectEntry = projects[matchedKey] as? [String: Any],
               let servers = projectEntry[Constants.JSONKeys.mcpServers] as? [String: Any] {
                for (name, value) in servers {
                    if let serverDict = value as? [String: Any] {
                        config.mcpServers.append(parseMCPServer(name: name, dict: serverDict, scope: Constants.MCPScope.local))
                    }
                }
            }
        }

        config.mcpServers.sort { $0.name < $1.name }
    }

    private func parseMCPServer(name: String, dict: [String: Any], scope: String) -> DiscoveredMCPServer {
        let command = dict["command"] as? String
        let args = dict["args"] as? [String] ?? []
        let envDict = dict["env"] as? [String: String] ?? [:]
        let url = dict["url"] as? String

        return DiscoveredMCPServer(
            name: name,
            command: command,
            args: args,
            env: envDict,
            url: url,
            scope: scope
        )
    }

    // MARK: - Settings Discovery

    /// Discovers settings and returns hook command → metadata mappings for file correlation.
    @discardableResult
    private func discoverSettings(
        at settingsPath: URL,
        hookDirectory: String,
        into config: inout DiscoveredConfiguration
    ) -> [String: HookRegistration]? {
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsPath)
        } catch {
            output.warn("Could not load \(settingsPath.lastPathComponent): \(error.localizedDescription)")
            return nil
        }

        // Extract plugins
        if let plugins = settings.enabledPlugins {
            config.plugins = plugins.filter(\.value).map(\.key).sorted()
        }

        // Build remaining settings (excluding hooks and enabledPlugins, which
        // auto-derive from components). Serialize as JSON Data for Sendable safety.
        var remaining: [String: Any] = [:]
        for (key, data) in settings.extraJSON {
            do {
                let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
                remaining[key] = value
            } catch {
                output.warn("Could not deserialize settings key '\(key)': \(error.localizedDescription)")
            }
        }
        if !remaining.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: remaining, options: [.prettyPrinted, .sortedKeys])
                config.remainingSettingsData = data
            } catch {
                output.warn("Could not serialize remaining settings: \(error.localizedDescription)")
            }
        }

        // Extract hook command → event/metadata mappings for file correlation
        guard let hooks = settings.hooks else { return nil }

        var commandToReg: [String: HookRegistration] = [:]
        for (event, groups) in hooks {
            for group in groups {
                for entry in group.hooks ?? [] {
                    guard let command = entry.command else { continue }
                    if let hookEvent = Constants.HookEvent(rawValue: event) {
                        commandToReg[command] = HookRegistration(
                            event: hookEvent,
                            matcher: group.matcher,
                            timeout: entry.timeout,
                            isAsync: entry.isAsync,
                            statusMessage: entry.statusMessage,
                            interpreter: Self.interpreter(
                                ofHookCommand: command,
                                directory: hookDirectory
                            )
                        )
                    } else {
                        output.warn("Skipping hook with unknown event '\(event)' — mcs may need to be updated")
                    }
                }
            }
        }
        return commandToReg.isEmpty ? nil : commandToReg
    }

    /// The interpreter portion of a registered hook command, or nil when it is the default or the
    /// command is not a managed hook invocation.
    ///
    /// Delegates the parse to `HookInterpreter`, which requires the trailing token to be a hook
    /// path. That requirement is what keeps an unrelated multi-token entry — `mcs check-updates
    /// --hook`, or a `python3 -m pkg.hook` pointing elsewhere — from being exported as a bogus
    /// `hookInterpreter`. Without any of this, exporting a live `node …/gate.ts` hook would emit a
    /// manifest that re-registers it under bash.
    private static func interpreter(ofHookCommand command: String, directory: String) -> String? {
        guard let interpreter = HookInterpreter.interpreter(
            ofRegisteredCommand: command,
            directory: directory
        ),
            !HookInterpreter.isDefault(interpreter),
            HookInterpreter.rejectionReason(for: interpreter) == nil
        else { return nil }
        return interpreter
    }

    // MARK: - File Discovery

    private func discoverFiles(in hooksDir: URL, hookCommands: [String: HookRegistration]?, into config: inout DiscoveredConfiguration) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hooksDir.path) else { return }

        let files = hookFiles(in: hooksDir)

        let commandToReg = hookCommands ?? [:]

        for file in files {
            let filename = file.lastPathComponent
            // Try to match this file to a hook event via settings commands
            let matchedReg = commandToReg.first { command, _ in
                command.contains(filename)
            }?.value

            config.hookFiles.append(DiscoveredFile(
                filename: filename,
                absolutePath: file,
                hookRegistration: matchedReg
            ))
        }
    }

    /// Hook scripts under `hooksDir`, including the `<pack-id>/` subdirectories sync installs into.
    ///
    /// A flat listing misses every hook mcs itself placed: `DestinationCollisionResolver` always
    /// namespaces hooks, so a synced hook never sits at the top level. Files are returned by
    /// basename, which is what a settings command references and what the exported manifest uses
    /// as its destination — so a basename appearing twice is reported and skipped rather than
    /// producing a manifest with duplicate destinations.
    private func hookFiles(in hooksDir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: hooksDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            output.warn("Could not read hooks directory at \(hooksDir.path)")
            return []
        }

        var byName: [String: URL] = [:]
        var ordered: [URL] = []
        for case let url as URL in enumerator {
            do {
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
            } catch {
                output.warn("  Could not read file type for \(url.lastPathComponent) — skipping")
                continue
            }
            let name = url.lastPathComponent
            if let existing = byName[name] {
                let shown = PathContainment.relativePath(of: url.path, within: hooksDir.path)
                let kept = PathContainment.relativePath(of: existing.path, within: hooksDir.path)
                output.warn(
                    "  Two hooks are named '\(name)' ('\(kept)' and '\(shown)') — exporting the"
                        + " first; rename one to export both"
                )
                continue
            }
            byName[name] = url
            ordered.append(url)
        }
        return ordered.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func listFiles(in directory: URL) -> [DiscoveredFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
            )
        } catch {
            output.warn("Could not read directory \(directory.lastPathComponent): \(error.localizedDescription)")
            return []
        }

        return files
            .filter { url in
                let name = url.lastPathComponent
                guard !name.hasPrefix(".") else { return false }
                guard let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else {
                    output.warn("  Skipping entry with unreadable attributes: \(name)")
                    return false
                }
                // Skip broken symlinks — they can't be copied to the output pack
                if vals.isSymbolicLink == true {
                    let resolved = url.resolvingSymlinksInPath()
                    if !fm.fileExists(atPath: resolved.path) {
                        output.warn("  Skipping broken symlink: \(name)")
                        return false
                    }
                }
                // Skip non-file, non-directory entries (sockets, device files, etc.)
                if vals.isRegularFile != true, vals.isDirectory != true {
                    return false
                }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { DiscoveredFile(filename: $0.lastPathComponent, absolutePath: $0) }
    }

    // MARK: - CLAUDE.md Discovery

    private func discoverClaudeContent(at path: URL, into config: inout DiscoveredConfiguration) {
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        let content: String
        do {
            content = try String(contentsOf: path, encoding: .utf8)
        } catch {
            output.warn("Could not read \(path.lastPathComponent): \(error.localizedDescription)")
            return
        }

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Parse managed sections
        let sections = TemplateComposer.parseSections(from: content)
        for section in sections {
            config.claudeSections.append(DiscoveredClaudeSection(
                sectionIdentifier: section.identifier,
                content: section.content
            ))
        }

        // Extract user content (outside any section markers)
        let userContent = TemplateComposer.extractUserContent(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContent.isEmpty {
            config.claudeUserContent = userContent
        }
    }

    // MARK: - Gitignore Discovery

    private func discoverGitignoreEntries(into config: inout DiscoveredConfiguration) {
        let gitignoreManager = GitignoreManager(shell: ShellRunner(environment: environment))
        let gitignoreURL = gitignoreManager.resolveGlobalGitignorePath()

        guard FileManager.default.fileExists(atPath: gitignoreURL.path) else { return }

        let content: String
        do {
            content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        } catch {
            output.warn("Could not read global gitignore: \(error.localizedDescription)")
            return
        }

        // Filter out mcs core entries (those are auto-managed)
        let coreEntries = Set(GitignoreManager.coreEntries)
        let entries = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !coreEntries.contains($0) }

        config.gitignoreEntries = entries
    }
}

// MARK: - Sensitive Env Var Detection

extension ConfigurationDiscovery.DiscoveredMCPServer {
    /// Names of env vars that likely contain secrets.
    static let sensitivePatterns = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY"]

    /// Returns env var names that appear to contain sensitive values.
    var sensitiveEnvVarNames: [String] {
        env.keys.filter { name in
            let upper = name.uppercased()
            return Self.sensitivePatterns.contains { upper.contains($0) }
        }.sorted()
    }
}
