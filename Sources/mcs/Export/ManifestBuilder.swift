import Foundation

/// Converts discovered configuration artifacts into a formatted techpack.yaml
/// string using shorthand syntax with proper key ordering, comments, and quoting.
///
/// Two-phase pipeline:
/// 1. `buildManifest()` — constructs a typed `ExternalPackManifest` (compile-time coupling to schema)
/// 2. `renderYAML()` — serializes the typed model to shorthand YAML with presentational formatting
struct ManifestBuilder {
    struct Metadata {
        let identifier: String
        let displayName: String
        let description: String
        let author: String?
    }

    struct BuildResult {
        /// The typed manifest model — use for programmatic assertions and schema coupling.
        let manifest: ExternalPackManifest
        /// The fully rendered techpack.yaml content as a string.
        let manifestYAML: String
        let filesToCopy: [FileCopy]
        /// Serialized JSON data for config/settings.json, or nil if no extra settings.
        let settingsToWrite: Data?
        let templateFiles: [TemplateFile]
    }

    struct FileCopy {
        let source: URL
        let destinationDir: String
        let filename: String
    }

    struct TemplateFile {
        let sectionIdentifier: String
        let filename: String
        let content: String
    }

    private struct CopyFileSpec {
        let files: [ConfigurationDiscovery.DiscoveredFile]
        let selected: Set<String>
        let idPrefix: String
        let componentType: ExternalComponentType
        let fileType: ExternalCopyFileType
        let descriptionFor: (ConfigurationDiscovery.DiscoveredFile) -> String
    }

    typealias Config = ConfigurationDiscovery.DiscoveredConfiguration

    struct BuildOptions {
        let selectedMCPServers: Set<String>
        let selectedHookFiles: Set<String>
        let selectedSkillFiles: Set<String>
        let selectedCommandFiles: Set<String>
        let selectedAgentFiles: Set<String>
        let selectedPlugins: Set<String>
        let selectedSections: Set<String>
        let includeUserContent: Bool
        let includeGitignore: Bool
        let includeSettings: Bool
    }

    /// Intermediate result from Phase 1 — avoids a 5-tuple return.
    private struct ManifestBuildOutput {
        let manifest: ExternalPackManifest
        let filesToCopy: [FileCopy]
        let settingsToWrite: Data?
        let templateFiles: [TemplateFile]
        /// Presentational side-channel — brew formula keyed by component ID.
        let brewHints: [String: String]
    }

    // MARK: - Build (Public Entry Point)

    func build(
        from config: Config,
        metadata: Metadata,
        options: BuildOptions
    ) -> BuildResult {
        // Phase 1: Build typed model
        let output = buildManifest(from: config, metadata: metadata, options: options)

        // Phase 2: Render to shorthand YAML
        let yaml = renderYAML(manifest: output.manifest, brewHints: output.brewHints)

        return BuildResult(
            manifest: output.manifest,
            manifestYAML: yaml,
            filesToCopy: output.filesToCopy,
            settingsToWrite: output.settingsToWrite,
            templateFiles: output.templateFiles
        )
    }

    // MARK: - Phase 1: Build Typed Manifest

    // swiftlint:disable:next function_body_length
    private func buildManifest(
        from config: Config,
        metadata: Metadata,
        options: BuildOptions
    ) -> ManifestBuildOutput {
        var components: [ExternalComponentDefinition] = []
        var prompts: [ExternalPromptDefinition] = []
        var filesToCopy: [FileCopy] = []
        var templateFiles: [TemplateFile] = []
        var settingsToWrite: Data?
        var brewHints: [String: String] = [:]

        // ── MCP Servers ───────────────────────────────────────────────────────
        var seenPromptKeys: [String: Int] = [:]
        for server in config.mcpServers where options.selectedMCPServers.contains(server.name) {
            let id = "mcp-\(sanitizeID(server.name))"

            // Detect brew dependency hint via Homebrew symlink resolution
            if let command = server.command, let formula = Homebrew.detectFormula(for: command) {
                brewHints[id] = formula
            }

            // Process env vars — replace sensitive ones with placeholders
            var processedEnv: [String: String] = [:]
            let sensitiveNames = Set(server.sensitiveEnvVarNames)
            for key in server.env.keys.sorted() {
                let value = server.env[key]!
                if sensitiveNames.contains(key) {
                    let count = seenPromptKeys[key, default: 0] + 1
                    seenPromptKeys[key] = count
                    let promptKey = count == 1 ? key : "\(key)_\(count)"
                    processedEnv[key] = "__\(promptKey)__"
                    prompts.append(ExternalPromptDefinition(
                        key: promptKey,
                        type: .input,
                        label: "Enter value for \(key) (used by \(server.name) MCP server)",
                        defaultValue: nil,
                        options: nil,
                        detectPatterns: nil,
                        scriptCommand: nil
                    ))
                } else {
                    processedEnv[key] = value
                }
            }

            let scope: ExternalScope? = server.scope != "local"
                ? ExternalScope(rawValue: server.scope) : nil

            let mcpConfig = if server.isHTTP {
                ExternalMCPServerConfig(
                    name: server.name,
                    command: nil,
                    args: nil,
                    env: processedEnv.isEmpty ? nil : processedEnv,
                    transport: .http,
                    url: server.url,
                    scope: scope
                )
            } else {
                ExternalMCPServerConfig(
                    name: server.name,
                    command: server.command,
                    args: server.args.isEmpty ? nil : server.args,
                    env: processedEnv.isEmpty ? nil : processedEnv,
                    transport: nil,
                    url: nil,
                    scope: scope
                )
            }

            components.append(ExternalComponentDefinition(
                id: id,
                displayName: id,
                description: "\(server.name) MCP server",
                type: .mcpServer,
                installAction: .mcpServer(mcpConfig)
            ))
        }

        // ── Hooks / Skills / Commands ────────────────────────────────────────
        let copyFileSpecs: [CopyFileSpec] = [
            CopyFileSpec(
                files: config.hookFiles, selected: options.selectedHookFiles,
                idPrefix: "hook", componentType: .hookFile, fileType: .hook,
                descriptionFor: { "Hook script for \($0.hookEvent ?? "unknown event")" }
            ),
            CopyFileSpec(
                files: config.skillFiles, selected: options.selectedSkillFiles,
                idPrefix: "skill", componentType: .skill, fileType: .skill,
                descriptionFor: { "\($0.filename) skill" }
            ),
            CopyFileSpec(
                files: config.commandFiles, selected: options.selectedCommandFiles,
                idPrefix: "cmd", componentType: .command, fileType: .command,
                descriptionFor: {
                    "/\($0.filename.hasSuffix(".md") ? String($0.filename.dropLast(3)) : $0.filename) command"
                }
            ),
            CopyFileSpec(
                files: config.agentFiles, selected: options.selectedAgentFiles,
                idPrefix: "agent", componentType: .agent, fileType: .agent,
                descriptionFor: { "\($0.filename) subagent" }
            ),
        ]

        for spec in copyFileSpecs {
            let directory = "\(spec.fileType.rawValue)s"
            for file in spec.files where spec.selected.contains(file.filename) {
                let id = "\(spec.idPrefix)-\(sanitizeID(file.filename))"
                components.append(ExternalComponentDefinition(
                    id: id,
                    displayName: id,
                    description: spec.descriptionFor(file),
                    type: spec.componentType,
                    hookEvent: file.hookEvent,
                    installAction: .copyPackFile(ExternalCopyPackFileConfig(
                        source: "\(directory)/\(file.filename)",
                        destination: file.filename,
                        fileType: spec.fileType
                    ))
                ))
                filesToCopy.append(FileCopy(
                    source: file.absolutePath,
                    destinationDir: directory,
                    filename: file.filename
                ))
            }
        }

        // ── Plugins ───────────────────────────────────────────────────────────
        for plugin in config.plugins where options.selectedPlugins.contains(plugin) {
            let id = "plugin-\(sanitizeID(plugin))"
            components.append(ExternalComponentDefinition(
                id: id,
                displayName: id,
                description: "\(plugin.split(separator: "@").first.map(String.init) ?? plugin) plugin",
                type: .plugin,
                installAction: .plugin(name: plugin)
            ))
        }

        // ── Settings ──────────────────────────────────────────────────────────
        if options.includeSettings, let data = config.remainingSettingsData {
            components.append(ExternalComponentDefinition(
                id: "settings",
                displayName: "settings",
                description: "Additional settings (env vars, permissions, etc.)",
                type: .configuration,
                isRequired: true,
                installAction: .settingsFile(source: "config/settings.json")
            ))
            settingsToWrite = data
        }

        // ── Gitignore ─────────────────────────────────────────────────────────
        if options.includeGitignore, !config.gitignoreEntries.isEmpty {
            components.append(ExternalComponentDefinition(
                id: "gitignore",
                displayName: "gitignore",
                description: "Global gitignore entries",
                type: .configuration,
                isRequired: true,
                installAction: .gitignoreEntries(entries: config.gitignoreEntries)
            ))
        }

        // ── Templates ─────────────────────────────────────────────────────────
        var templates: [ExternalTemplateDefinition] = []

        for section in config.claudeSections where options.selectedSections.contains(section.sectionIdentifier) {
            let filename = sanitizeFilename(section.sectionIdentifier) + ".md"
            let shortID = shortIdentifier(section.sectionIdentifier, packID: metadata.identifier)
            templates.append(ExternalTemplateDefinition(
                sectionIdentifier: shortID,
                placeholders: nil,
                contentFile: "templates/\(filename)"
            ))
            templateFiles.append(TemplateFile(
                sectionIdentifier: section.sectionIdentifier,
                filename: filename,
                content: section.content
            ))
        }

        if options.includeUserContent, let userContent = config.claudeUserContent {
            templates.append(ExternalTemplateDefinition(
                sectionIdentifier: "custom",
                placeholders: nil,
                contentFile: "templates/custom.md"
            ))
            templateFiles.append(TemplateFile(
                sectionIdentifier: "\(metadata.identifier).custom",
                filename: "custom.md",
                content: userContent
            ))
        }

        // ── Assemble manifest ─────────────────────────────────────────────────
        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: metadata.identifier,
            displayName: metadata.displayName,
            description: metadata.description,
            author: metadata.author,
            minMCSVersion: nil,
            components: components.isEmpty ? nil : components,
            templates: templates.isEmpty ? nil : templates,
            prompts: prompts.isEmpty ? nil : prompts,
            configureProject: nil,
            supplementaryDoctorChecks: nil
        )

        return ManifestBuildOutput(
            manifest: manifest,
            filesToCopy: filesToCopy,
            settingsToWrite: settingsToWrite,
            templateFiles: templateFiles,
            brewHints: brewHints
        )
    }

    // MARK: - Phase 2: Render YAML from Typed Model

    private func renderYAML(manifest: ExternalPackManifest, brewHints: [String: String]) -> String {
        var yaml = YAMLRenderer()

        // ── Header ────────────────────────────────────────────────────────────
        yaml.comment("Generated by `mcs export` — review and customize before sharing.")
        yaml.comment("Schema reference: https://github.com/bguidolim/mcs/blob/main/docs/techpack-schema.md")
        yaml.comment("Guide: https://github.com/bguidolim/mcs/blob/main/docs/creating-tech-packs.md")
        yaml.blank()

        // ── Metadata (always first) ───────────────────────────────────────────
        yaml.keyValue("schemaVersion", manifest.schemaVersion)
        yaml.keyValue("identifier", manifest.identifier)
        yaml.keyValue("displayName", manifest.displayName, quoted: true)
        yaml.keyValue("description", manifest.description, quoted: true)
        if let author = manifest.author {
            yaml.keyValue("author", author, quoted: true)
        }

        // ── Components ────────────────────────────────────────────────────────
        if let components = manifest.components {
            yaml.blank()
            yaml.sectionDivider("Components")
            yaml.line("components:")

            let groupOrder: [(label: String, filter: (ExternalComponentDefinition) -> Bool)] = [
                ("MCP Servers", { $0.type == .mcpServer }),
                ("Hooks", { $0.type == .hookFile }),
                ("Skills", { $0.type == .skill }),
                ("Commands", { $0.type == .command }),
                ("Agents", { $0.type == .agent }),
                ("Plugins", { $0.type == .plugin }),
                ("Configuration", { $0.type == .configuration }),
            ]

            for (label, filter) in groupOrder {
                let matching = components.filter(filter)
                if !matching.isEmpty {
                    yaml.blank()
                    yaml.comment("  ── \(label) " + String(repeating: "─", count: max(0, 65 - label.count)), indent: 2)
                    for comp in matching {
                        renderComponent(comp, brewHints: brewHints, to: &yaml)
                    }
                }
            }
        }

        // ── Templates ─────────────────────────────────────────────────────────
        if let templates = manifest.templates {
            yaml.blank()
            yaml.sectionDivider("Templates — CLAUDE.local.md sections")
            yaml.line("templates:")
            for template in templates {
                yaml.line("  - sectionIdentifier: \(yamlQuote(template.sectionIdentifier))")
                yaml.line("    contentFile: \(yamlQuote(template.contentFile))")
            }
        }

        // ── Prompts ───────────────────────────────────────────────────────────
        if let prompts = manifest.prompts {
            yaml.blank()
            yaml.sectionDivider("Prompts — resolved interactively during `mcs sync`")
            yaml.line("prompts:")
            for prompt in prompts {
                yaml.line("  - key: \(yamlQuote(prompt.key))")
                yaml.line("    type: \(prompt.type.rawValue)")
                if let label = prompt.label {
                    yaml.line("    label: \(yamlQuote(label))")
                }
            }
        }

        // ── Doctor Checks ─────────────────────────────────────────────────────
        yaml.blank()
        yaml.sectionDivider("Doctor Checks — `mcs doctor` health verification")
        yaml.comment("Most components get auto-derived doctor checks — no config needed:")
        yaml.comment("  brew:       → checks if command is on PATH")
        yaml.comment("  mcp:        → checks if MCP server is registered")
        yaml.comment("  plugin:     → checks if plugin is enabled")
        yaml.comment("  hook:       → checks if hook file exists")
        yaml.comment("  skill:      → checks if skill directory exists")
        yaml.comment("  command:    → checks if command file exists")
        yaml.comment("  agent:      → checks if agent file exists")
        yaml.comment("  shell:      → NO auto-check (add doctorChecks: manually)")
        yaml.comment("")
        yaml.comment("Add pack-level checks for prerequisites not tied to a component:")
        yaml.comment("supplementaryDoctorChecks:")
        yaml.comment("  - type: commandExists")
        yaml.comment("    name: Xcode Command Line Tools")
        yaml.comment("    section: Prerequisites")
        yaml.comment("    command: xcode-select")
        yaml.comment("    fixCommand: \"xcode-select --install\"")
        yaml.comment("")
        yaml.comment("Check types: commandExists, fileExists, directoryExists, fileContains,")
        yaml.comment("  fileNotContains, shellScript, hookEventExists, settingsKeyEquals")
        yaml.comment("See: https://github.com/bguidolim/mcs/blob/main/docs/techpack-schema.md#doctor-checks")

        // ── TODOs ─────────────────────────────────────────────────────────────
        yaml.blank()
        yaml.sectionDivider("TODO — Review before sharing")
        yaml.comment("- [ ] Review component descriptions and add displayName where helpful")
        yaml.comment("- [ ] Add `dependencies:` between components if needed (e.g. MCP server depends on brew package)")
        yaml.comment("- [ ] Add `isRequired: true` to components that should always be installed")
        yaml.comment("- [ ] Add brew dependencies for MCP server runtimes (node, uv, python3)")
        yaml.comment("- [ ] Add `supplementaryDoctorChecks:` for pack-level health checks (see above)")
        yaml.comment("- [ ] Add `configureProject:` script if project-level setup is needed")
        yaml.comment("- [ ] Move `prompts:` section before `components:` for readability")
        yaml.comment("- [ ] Add `placeholders:` to templates that use __PLACEHOLDER__ tokens")

        return yaml.output
    }

    // MARK: - Component Renderer

    private func renderComponent(
        _ comp: ExternalComponentDefinition,
        brewHints: [String: String],
        to yaml: inout YAMLRenderer
    ) {
        // Skip .generic file components — no YAML shorthand key exists for this type
        if case let .copyPackFile(config) = comp.installAction,
           config.fileType == .generic || config.fileType == nil {
            return
        }

        // Brew hint comment (presentational only)
        if let brewPackage = brewHints[comp.id] {
            yaml.comment("  TODO: Consider adding a `brew: \(brewPackage)` dependency component", indent: 2)
        }

        yaml.line("  - id: \(comp.id)")
        yaml.line("    description: \(yamlQuote(comp.description))")

        // isRequired
        if comp.isRequired == true {
            yaml.line("    isRequired: true")
        }

        // hookEvent
        if let hookEvent = comp.hookEvent {
            yaml.line("    hookEvent: \(yamlQuote(hookEvent))")
        } else if comp.type == .hookFile {
            yaml.comment("    TODO: Add hookEvent (e.g. SessionStart, PreToolUse, Stop)", indent: 4)
        }

        // Install action → shorthand key (exhaustive switch = compile-time safety)
        switch comp.installAction {
        case let .mcpServer(config):
            yaml.line("    mcp:")
            if config.transport == .http, let url = config.url {
                yaml.line("      url: \(yamlQuote(url))")
            } else {
                if let command = config.command {
                    yaml.line("      command: \(yamlQuote(command))")
                }
                if let args = config.args, !args.isEmpty {
                    yaml.line("      args:")
                    for arg in args {
                        yaml.line("        - \(yamlQuote(arg))")
                    }
                }
            }
            if let env = config.env, !env.isEmpty {
                yaml.line("      env:")
                for key in env.keys.sorted() {
                    yaml.line("        \(key): \(yamlQuote(env[key]!))")
                }
            }
            if let scope = config.scope, scope != .local {
                yaml.line("      scope: \(scope.rawValue)")
            }

        case let .brewInstall(package):
            yaml.line("    brew: \(package)")

        case let .plugin(name):
            yaml.line("    plugin: \(yamlQuote(name))")

        case let .copyPackFile(config):
            let key: String
            switch config.fileType {
            case .hook: key = "hook"
            case .skill: key = "skill"
            case .command: key = "command"
            case .agent: key = "agent"
            case .generic, .none:
                preconditionFailure("Export does not produce .generic file components")
            }
            yaml.line("    \(key):")
            yaml.line("      source: \(yamlQuote(config.source))")
            yaml.line("      destination: \(yamlQuote(config.destination))")

        case let .settingsFile(source):
            yaml.line("    settingsFile: \(yamlQuote(source))")

        case let .gitignoreEntries(entries):
            yaml.line("    gitignore:")
            for entry in entries {
                yaml.line("      - \(yamlQuote(entry))")
            }

        case let .shellCommand(command):
            yaml.line("    type: \(comp.type.rawValue)")
            yaml.line("    shell: \(yamlQuote(command))")

        case .settingsMerge:
            break
        }

        yaml.blank()
    }

    // MARK: - Helpers

    private func sanitizeID(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "@", with: "-")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func shortIdentifier(_ fullID: String, packID: String) -> String {
        let prefix = "\(packID)."
        if fullID.hasPrefix(prefix) {
            return String(fullID.dropFirst(prefix.count))
        }
        if let dotIndex = fullID.lastIndex(of: ".") {
            return String(fullID[fullID.index(after: dotIndex)...])
        }
        return fullID
    }

    private func sanitizeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }
}

// MARK: - YAML Quoting

/// Determines if a YAML string value needs quoting and returns the properly formatted value.
private func yamlQuote(_ value: String) -> String {
    let needsQuoting = value.isEmpty
        || value.hasPrefix("@")
        || value.hasPrefix("-")
        || value.hasPrefix("*")
        || value.hasPrefix("&")
        || value.hasPrefix("{")
        || value.hasPrefix("[")
        || value.hasPrefix("!")
        || value.hasPrefix("%")
        || value.hasPrefix("__")
        || value.contains(": ")
        || value.contains("#")
        || value.contains("\"")
        || value.contains("'")
        || value.contains("\n")
        || value.contains("\t")
        || ["true", "false", "yes", "no", "null", "~"].contains(value.lowercased())

    if needsQuoting {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
    return value
}

// MARK: - YAML Renderer

/// Simple YAML text builder with support for comments, sections, and proper formatting.
struct YAMLRenderer {
    private var lines: [String] = []

    var output: String {
        lines.joined(separator: "\n") + "\n"
    }

    mutating func line(_ text: String) {
        lines.append(text)
    }

    mutating func blank() {
        lines.append("")
    }

    mutating func comment(_ text: String, indent: Int = 0) {
        let prefix = String(repeating: " ", count: indent)
        lines.append("\(prefix)# \(text)")
    }

    mutating func sectionDivider(_ title: String) {
        lines.append("# ---------------------------------------------------------------------------")
        lines.append("# \(title)")
        lines.append("# ---------------------------------------------------------------------------")
    }

    mutating func keyValue(_ key: String, _ value: String, quoted: Bool = false) {
        lines.append("\(key): \(quoted ? yamlQuote(value) : value)")
    }

    mutating func keyValue(_ key: String, _ value: Int) {
        lines.append("\(key): \(value)")
    }
}
