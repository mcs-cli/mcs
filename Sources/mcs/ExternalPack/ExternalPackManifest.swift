import Foundation
import Yams

// MARK: - Manifest Root

/// Codable model for `techpack.yaml` — the declarative manifest for external tech packs.
struct ExternalPackManifest: Codable {
    let schemaVersion: Int
    let identifier: String
    let displayName: String
    let description: String
    let author: String?
    let minMCSVersion: String?
    let components: [ExternalComponentDefinition]?
    let templates: [ExternalTemplateDefinition]?
    let prompts: [PromptDefinition]?
    let configureProject: ExternalConfigureProject?
    let supplementaryDoctorChecks: [ExternalDoctorCheckDefinition]?
}

// MARK: - Loading

extension ExternalPackManifest {
    /// Load and decode a `techpack.yaml` file from disk.
    static func load(from url: URL) throws -> ExternalPackManifest {
        let data = try Data(contentsOf: url)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidEncoding
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(ExternalPackManifest.self, from: yamlString)
    }
}

// MARK: - Validation

extension ExternalPackManifest {
    /// Validate the manifest for structural correctness.
    func validate() throws {
        // Schema version
        guard schemaVersion == 1 else {
            throw ManifestError.unsupportedSchemaVersion(schemaVersion)
        }

        // Identifier: non-empty, lowercase alphanumeric + hyphens only
        let identifierPattern = #"^[a-z0-9][a-z0-9-]*$"#
        guard !identifier.isEmpty,
              identifier.range(of: identifierPattern, options: .regularExpression) != nil
        else {
            throw ManifestError.invalidIdentifier(identifier)
        }

        // Component ID prefix and dependency resolution
        var seenComponentIDs = Set<String>()
        if let components {
            let expectedPrefix = "\(identifier)."
            for component in components {
                guard component.id.hasPrefix(expectedPrefix) else {
                    throw ManifestError.componentIDPrefixViolation(
                        componentID: component.id,
                        expectedPrefix: expectedPrefix
                    )
                }
                guard !seenComponentIDs.contains(component.id) else {
                    throw ManifestError.duplicateComponentID(component.id)
                }
                seenComponentIDs.insert(component.id)

                // Validate hookEvent against known Claude Code hook events
                if let hookEvent = component.hookEvent {
                    guard Constants.Hooks.validEvents.contains(hookEvent) else {
                        throw ManifestError.invalidHookEvent(
                            componentID: component.id,
                            hookEvent: hookEvent
                        )
                    }
                }

                // Validate hook handler metadata
                if let timeout = component.hookTimeout, timeout <= 0 {
                    throw ManifestError.invalidHookMetadata(
                        componentID: component.id,
                        reason: "hookTimeout must be positive (got \(timeout))"
                    )
                }
                let hasHookMetadata = component.hookTimeout != nil
                    || component.hookAsync != nil
                    || component.hookStatusMessage != nil
                if hasHookMetadata, component.hookEvent == nil {
                    throw ManifestError.invalidHookMetadata(
                        componentID: component.id,
                        reason: "hookTimeout/hookAsync/hookStatusMessage require hookEvent to be set"
                    )
                }
            }

            // Validate intra-pack dependency references resolve to existing component IDs
            for component in components {
                for dep in component.dependencies ?? [] {
                    if dep.hasPrefix(expectedPrefix), !seenComponentIDs.contains(dep) {
                        throw ManifestError.unresolvedDependency(
                            componentID: component.id,
                            dependency: dep
                        )
                    }
                }
            }
        }

        // Template section identifiers must be prefixed with pack identifier
        if let templates {
            for template in templates {
                guard template.sectionIdentifier.hasPrefix("\(identifier).") else {
                    throw ManifestError.templateSectionMismatch(
                        sectionIdentifier: template.sectionIdentifier,
                        packIdentifier: identifier
                    )
                }
                for dep in template.dependencies ?? [] {
                    guard seenComponentIDs.contains(dep) else {
                        throw ManifestError.templateDependencyMismatch(
                            sectionIdentifier: template.sectionIdentifier,
                            componentID: dep
                        )
                    }
                }
            }
        }

        // Prompt key uniqueness
        if let prompts {
            var seenKeys = Set<String>()
            for prompt in prompts {
                guard !seenKeys.contains(prompt.key) else {
                    throw ManifestError.duplicatePromptKey(prompt.key)
                }
                seenKeys.insert(prompt.key)
            }
        }

        // Doctor check field validation
        if let checks = supplementaryDoctorChecks {
            for check in checks {
                try validateDoctorCheck(check)
            }
        }
        if let components {
            for component in components {
                if let checks = component.doctorChecks {
                    for check in checks {
                        try validateDoctorCheck(check)
                    }
                }
            }
        }
    }

    private func validateDoctorCheck(_ check: ExternalDoctorCheckDefinition) throws {
        switch check.type {
        case .commandExists:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "commandExists requires non-empty 'command'")
            }
        case .fileExists, .directoryExists:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
        case .fileContains, .fileNotContains:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
            guard let pattern = check.pattern, !pattern.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'pattern'")
            }
        case .shellScript:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "shellScript requires non-empty 'command'")
            }
        case .hookEventExists:
            guard let event = check.event, !event.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "hookEventExists requires non-empty 'event'")
            }
            guard Constants.Hooks.validEvents.contains(event) else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "hookEventExists has unknown event '\(event)'")
            }
        case .settingsKeyEquals:
            guard let keyPath = check.keyPath, !keyPath.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'keyPath'")
            }
            guard let expectedValue = check.expectedValue, !expectedValue.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'expectedValue'")
            }
        }
    }
}

// MARK: - Normalization

extension ExternalPackManifest {
    /// Returns a copy with short component IDs and intra-pack dependencies auto-prefixed
    /// with the pack identifier. Throws if any component ID or template section identifier
    /// contains a dot — pack authors must use short names and let the tool add the prefix.
    func normalized() throws -> ExternalPackManifest {
        let prefix = "\(identifier)."
        let normalizedComponents = try components?.map { component -> ExternalComponentDefinition in
            var c = component
            guard !c.id.contains(".") else {
                throw ManifestError.dotInRawID(c.id)
            }
            c.id = prefix + c.id
            c.dependencies = c.dependencies?.map { dep in
                dep.contains(".") ? dep : prefix + dep
            }
            return c
        }
        let normalizedTemplates = try templates?.map { template -> ExternalTemplateDefinition in
            var t = template
            guard !t.sectionIdentifier.contains(".") else {
                throw ManifestError.dotInRawID(t.sectionIdentifier)
            }
            t.sectionIdentifier = prefix + t.sectionIdentifier
            t.dependencies = try t.dependencies?.map { dep in
                guard !dep.contains(".") else {
                    throw ManifestError.dotInRawID(dep)
                }
                return prefix + dep
            }
            return t
        }
        return ExternalPackManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: displayName,
            description: description,
            author: author,
            minMCSVersion: minMCSVersion,
            components: normalizedComponents,
            templates: normalizedTemplates,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks
        )
    }
}

// MARK: - Errors

/// Errors that can occur during manifest loading or validation.
enum ManifestError: Error, Equatable, LocalizedError {
    case invalidEncoding
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier(String)
    case componentIDPrefixViolation(componentID: String, expectedPrefix: String)
    case duplicateComponentID(String)
    case templateSectionMismatch(sectionIdentifier: String, packIdentifier: String)
    case duplicatePromptKey(String)
    case invalidDoctorCheck(name: String, reason: String)
    case dotInRawID(String)
    case templateDependencyMismatch(sectionIdentifier: String, componentID: String)
    case unresolvedDependency(componentID: String, dependency: String)
    case invalidHookEvent(componentID: String, hookEvent: String)
    case invalidHookMetadata(componentID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "Manifest file is not valid UTF-8"
        case let .unsupportedSchemaVersion(version):
            "Unsupported schema version: \(version) (expected 1)"
        case let .invalidIdentifier(id):
            "Invalid pack identifier '\(id)': must be non-empty, lowercase alphanumeric with hyphens"
        case let .componentIDPrefixViolation(componentID, expectedPrefix):
            "Component ID '\(componentID)' must start with '\(expectedPrefix)'"
        case let .duplicateComponentID(id):
            "Duplicate component ID: '\(id)'"
        case let .templateSectionMismatch(section, pack):
            "Template section '\(section)' must be prefixed with '\(pack).' (e.g. '\(pack).main')"
        case let .templateDependencyMismatch(section, component):
            "Template '\(section)' depends on component '\(component)' which does not exist in the pack"
        case let .duplicatePromptKey(key):
            "Duplicate prompt key: '\(key)'"
        case let .invalidDoctorCheck(name, reason):
            "Invalid doctor check '\(name)': \(reason)"
        case let .dotInRawID(id):
            "ID '\(id)' must not contain dots — use a short name and the pack prefix will be added automatically"
        case let .unresolvedDependency(componentID, dependency):
            "Component '\(componentID)' depends on '\(dependency)' which does not exist in the pack"
        case let .invalidHookEvent(componentID, hookEvent):
            "Component '\(componentID)' has unknown hookEvent '\(hookEvent)'"
        case let .invalidHookMetadata(componentID, reason):
            "Component '\(componentID)': \(reason)"
        }
    }
}

// MARK: - Components

/// Declarative definition of an installable component within an external pack.
///
/// Supports two authoring styles:
///
/// **Verbose** (all fields explicit):
/// ```yaml
/// - id: node
///   displayName: Node.js
///   description: JavaScript runtime
///   type: brewPackage
///   installAction:
///     type: brewInstall
///     package: node
/// ```
///
/// **Shorthand** (type + installAction inferred from a single key):
/// ```yaml
/// - id: node
///   description: JavaScript runtime
///   brew: node
/// ```
///
/// Shorthand keys: `brew`, `mcp`, `plugin`, `shell`, `hook`, `command`,
/// `skill`, `settingsFile`, `gitignore`. See `ShorthandKeys` for details.
struct ExternalComponentDefinition: Codable {
    var id: String
    let displayName: String
    let description: String
    let type: ExternalComponentType
    var dependencies: [String]?
    let isRequired: Bool?
    /// Claude Code hook event name (e.g. "SessionStart", "PreToolUse") for `hookFile` components.
    /// When set, the engine auto-registers this hook in `settings.local.json`.
    /// The `hookTimeout`, `hookAsync`, and `hookStatusMessage` fields map to
    /// the corresponding Claude Code hook handler fields on the emitted entry.
    let hookEvent: String?
    let hookTimeout: Int?
    let hookAsync: Bool?
    let hookStatusMessage: String?
    let installAction: ExternalInstallAction
    let doctorChecks: [ExternalDoctorCheckDefinition]?

    // MARK: CodingKeys

    /// Standard keys matching stored properties (used by encode).
    enum CodingKeys: String, CodingKey {
        case id, displayName, description, type, dependencies, isRequired
        case hookEvent, hookTimeout, hookAsync, hookStatusMessage
        case installAction, doctorChecks
    }

    /// Shorthand install-action keys that replace `type` + `installAction`.
    enum ShorthandKeys: String, CodingKey {
        case brew // String — brew package name
        case mcp // Map — MCPShorthand (name inferred from id)
        case plugin // String — plugin full name
        case shell // String — shell command (requires explicit `type`)
        case hook // Map — CopyFileShorthand (fileType: .hook)
        case command // Map — CopyFileShorthand (fileType: .command)
        case skill // Map — CopyFileShorthand (fileType: .skill)
        case agent // Map — CopyFileShorthand (fileType: .agent)
        case settingsFile // String — source path
        case gitignore // [String] — gitignore entries
    }

    // MARK: Memberwise init

    init(
        id: String,
        displayName: String,
        description: String,
        type: ExternalComponentType,
        dependencies: [String]? = nil,
        isRequired: Bool? = nil,
        hookEvent: String? = nil,
        hookTimeout: Int? = nil,
        hookAsync: Bool? = nil,
        hookStatusMessage: String? = nil,
        installAction: ExternalInstallAction,
        doctorChecks: [ExternalDoctorCheckDefinition]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.type = type
        self.dependencies = dependencies
        self.isRequired = isRequired
        self.hookEvent = hookEvent
        self.hookTimeout = hookTimeout
        self.hookAsync = hookAsync
        self.hookStatusMessage = hookStatusMessage
        self.installAction = installAction
        self.doctorChecks = doctorChecks
    }

    // MARK: Decode (shorthand + verbose)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shorthand = try decoder.container(keyedBy: ShorthandKeys.self)

        id = try container.decode(String.self, forKey: .id)
        description = try container.decode(String.self, forKey: .description)
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired)
        hookEvent = try container.decodeIfPresent(String.self, forKey: .hookEvent)
        hookTimeout = try container.decodeIfPresent(Int.self, forKey: .hookTimeout)
        hookAsync = try container.decodeIfPresent(Bool.self, forKey: .hookAsync)
        hookStatusMessage = try container.decodeIfPresent(String.self, forKey: .hookStatusMessage)
        doctorChecks = try container.decodeIfPresent([ExternalDoctorCheckDefinition].self, forKey: .doctorChecks)

        if let resolved = try Self.resolveShorthand(shorthand, componentId: id) {
            type = try resolved.type ?? container.decode(ExternalComponentType.self, forKey: .type)
            installAction = resolved.action
        } else {
            type = try container.decode(ExternalComponentType.self, forKey: .type)
            installAction = try container.decode(ExternalInstallAction.self, forKey: .installAction)
        }

        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
    }

    // MARK: Encode (always verbose)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(isRequired, forKey: .isRequired)
        try container.encodeIfPresent(hookEvent, forKey: .hookEvent)
        try container.encodeIfPresent(hookTimeout, forKey: .hookTimeout)
        try container.encodeIfPresent(hookAsync, forKey: .hookAsync)
        try container.encodeIfPresent(hookStatusMessage, forKey: .hookStatusMessage)
        try container.encode(installAction, forKey: .installAction)
        try container.encodeIfPresent(doctorChecks, forKey: .doctorChecks)
    }

    // MARK: - Shorthand Resolution

    private struct ResolvedShorthand {
        let type: ExternalComponentType?
        let action: ExternalInstallAction
    }

    private static func resolveShorthand(
        _ shorthand: KeyedDecodingContainer<ShorthandKeys>,
        componentId: String
    ) throws -> ResolvedShorthand? {
        if shorthand.contains(.brew) {
            let package = try shorthand.decode(String.self, forKey: .brew)
            return ResolvedShorthand(type: .brewPackage, action: .brewInstall(package: package))
        }
        if shorthand.contains(.mcp) {
            let config = try shorthand.decode(MCPShorthand.self, forKey: .mcp)
            let defaultName = componentId.split(separator: ".").last.map(String.init) ?? componentId
            return ResolvedShorthand(type: .mcpServer, action: .mcpServer(config.toExternalConfig(defaultName: defaultName)))
        }
        if shorthand.contains(.plugin) {
            let name = try shorthand.decode(String.self, forKey: .plugin)
            return ResolvedShorthand(type: .plugin, action: .plugin(name: name))
        }
        if shorthand.contains(.shell) {
            let command = try shorthand.decode(String.self, forKey: .shell)
            return ResolvedShorthand(type: nil, action: .shellCommand(command: command))
        }
        if shorthand.contains(.hook) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .hook)
            return ResolvedShorthand(type: .hookFile, action: .copyPackFile(config.toExternalConfig(fileType: .hook)))
        }
        if shorthand.contains(.command) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .command)
            return ResolvedShorthand(type: .command, action: .copyPackFile(config.toExternalConfig(fileType: .command)))
        }
        if shorthand.contains(.skill) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .skill)
            return ResolvedShorthand(type: .skill, action: .copyPackFile(config.toExternalConfig(fileType: .skill)))
        }
        if shorthand.contains(.agent) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .agent)
            return ResolvedShorthand(type: .agent, action: .copyPackFile(config.toExternalConfig(fileType: .agent)))
        }
        if shorthand.contains(.settingsFile) {
            let source = try shorthand.decode(String.self, forKey: .settingsFile)
            return ResolvedShorthand(type: .configuration, action: .settingsFile(source: source))
        }
        if shorthand.contains(.gitignore) {
            let entries = try shorthand.decode([String].self, forKey: .gitignore)
            return ResolvedShorthand(type: .configuration, action: .gitignoreEntries(entries: entries))
        }
        return nil
    }
}

// MARK: - Shorthand Helper Structs

/// Shorthand MCP server configuration — `name` defaults to the component id
/// but can be overridden (e.g. when the server name uses mixed case).
struct MCPShorthand: Codable {
    let name: String?
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let scope: ExternalScope?

    func toExternalConfig(defaultName: String) -> ExternalMCPServerConfig {
        ExternalMCPServerConfig(
            name: name ?? defaultName,
            command: command,
            args: args,
            env: env,
            transport: url != nil ? .http : nil,
            url: url,
            scope: scope
        )
    }
}

/// Shorthand copy-file configuration — `fileType` is inferred from the shorthand key.
struct CopyFileShorthand: Codable {
    let source: String
    let destination: String

    func toExternalConfig(fileType: ExternalCopyFileType) -> ExternalCopyPackFileConfig {
        ExternalCopyPackFileConfig(
            source: source,
            destination: destination,
            fileType: fileType
        )
    }
}

/// String-backed component type that maps to the internal `ComponentType`.
enum ExternalComponentType: String, Codable {
    case mcpServer
    case plugin
    case skill
    case hookFile
    case command
    case agent
    case brewPackage
    case configuration

    /// Convert to the internal `ComponentType`.
    var componentType: ComponentType {
        switch self {
        case .mcpServer: .mcpServer
        case .plugin: .plugin
        case .skill: .skill
        case .hookFile: .hookFile
        case .command: .command
        case .agent: .agent
        case .brewPackage: .brewPackage
        case .configuration: .configuration
        }
    }
}

// MARK: - Install Actions

/// String-backed install action type discriminator for YAML serialization.
enum ExternalInstallActionType: String, Codable {
    case mcpServer
    case plugin
    case brewInstall
    case shellCommand
    case gitignoreEntries
    case settingsMerge
    case settingsFile
    case copyPackFile
}

/// Declarative install action types that can be expressed in YAML.
enum ExternalInstallAction: Codable {
    case mcpServer(ExternalMCPServerConfig)
    case plugin(name: String)
    case brewInstall(package: String)
    case shellCommand(command: String)
    case gitignoreEntries(entries: [String])
    case settingsMerge
    case settingsFile(source: String)
    case copyPackFile(ExternalCopyPackFileConfig)

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case package
        case command
        case args
        case env
        case transport
        case url
        case scope
        case entries
        case source
        case destination
        case fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actionType = try container.decode(ExternalInstallActionType.self, forKey: .type)

        switch actionType {
        case .mcpServer:
            let config = try ExternalMCPServerConfig(from: decoder)
            self = .mcpServer(config)
        case .plugin:
            let name = try container.decode(String.self, forKey: .name)
            self = .plugin(name: name)
        case .brewInstall:
            let package = try container.decode(String.self, forKey: .package)
            self = .brewInstall(package: package)
        case .shellCommand:
            let command = try container.decode(String.self, forKey: .command)
            self = .shellCommand(command: command)
        case .gitignoreEntries:
            let entries = try container.decode([String].self, forKey: .entries)
            self = .gitignoreEntries(entries: entries)
        case .settingsMerge:
            self = .settingsMerge
        case .settingsFile:
            let source = try container.decode(String.self, forKey: .source)
            self = .settingsFile(source: source)
        case .copyPackFile:
            let config = try ExternalCopyPackFileConfig(from: decoder)
            self = .copyPackFile(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .mcpServer(config):
            try container.encode(ExternalInstallActionType.mcpServer, forKey: .type)
            try config.encode(to: encoder)
        case let .plugin(name):
            try container.encode(ExternalInstallActionType.plugin, forKey: .type)
            try container.encode(name, forKey: .name)
        case let .brewInstall(package):
            try container.encode(ExternalInstallActionType.brewInstall, forKey: .type)
            try container.encode(package, forKey: .package)
        case let .shellCommand(command):
            try container.encode(ExternalInstallActionType.shellCommand, forKey: .type)
            try container.encode(command, forKey: .command)
        case let .gitignoreEntries(entries):
            try container.encode(ExternalInstallActionType.gitignoreEntries, forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .settingsMerge:
            try container.encode(ExternalInstallActionType.settingsMerge, forKey: .type)
        case let .settingsFile(source):
            try container.encode(ExternalInstallActionType.settingsFile, forKey: .type)
            try container.encode(source, forKey: .source)
        case let .copyPackFile(config):
            try container.encode(ExternalInstallActionType.copyPackFile, forKey: .type)
            try config.encode(to: encoder)
        }
    }
}

// MARK: - MCP Server Config

/// Configuration for an MCP server declared in an external pack manifest.
struct ExternalMCPServerConfig: Codable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let transport: ExternalTransport?
    let url: String?
    let scope: ExternalScope?

    /// Convert to the internal `MCPServerConfig`.
    func toMCPServerConfig() -> MCPServerConfig {
        if transport == .http, let url {
            return .http(name: name, url: url, scope: scope?.rawValue)
        }
        return MCPServerConfig(
            name: name,
            command: command ?? "",
            args: args ?? [],
            env: env ?? [:],
            scope: scope?.rawValue
        )
    }
}

enum ExternalTransport: String, Codable {
    case stdio
    case http
}

enum ExternalScope: String, Codable {
    case local
    case user
    case project
}

// MARK: - Copy Pack File Config

/// Configuration for copying a file from the pack into the Claude directory.
struct ExternalCopyPackFileConfig: Codable {
    let source: String
    let destination: String
    let fileType: ExternalCopyFileType?
}

enum ExternalCopyFileType: String, Codable {
    case skill
    case hook
    case command
    case agent
    case generic
}

// MARK: - Templates

/// A template contribution declared in an external pack manifest.
struct ExternalTemplateDefinition: Codable {
    var sectionIdentifier: String
    let placeholders: [String]?
    let contentFile: String
    var dependencies: [String]?
}

// MARK: - Configure Project

/// Script-based project configuration hook.
struct ExternalConfigureProject: Codable {
    let script: String
}

// MARK: - Doctor Checks

/// A declarative doctor check definition for external packs.
struct ExternalDoctorCheckDefinition: Codable {
    let type: ExternalDoctorCheckType
    let name: String
    let section: String?
    let command: String?
    let args: [String]?
    let path: String?
    let pattern: String?
    let scope: ExternalDoctorCheckScope?
    let fixCommand: String?
    let fixScript: String?
    let event: String?
    let keyPath: String?
    let expectedValue: String?
    let isOptional: Bool?
}

enum ExternalDoctorCheckType: String, Codable {
    case commandExists
    case fileExists
    case directoryExists
    case fileContains
    case fileNotContains
    case shellScript
    case hookEventExists
    case settingsKeyEquals
}

enum ExternalDoctorCheckScope: String, Codable {
    case global
    case project
}
