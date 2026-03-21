import Foundation

/// Types of components that can be installed
enum ComponentType: String, CaseIterable {
    case mcpServer = "MCP Servers"
    case plugin = "Plugins"
    case skill = "Skills"
    case hookFile = "Hooks"
    case command = "Commands"
    case agent = "Agents"
    case brewPackage = "Dependencies"
    case configuration = "Configurations"
}

extension ComponentType {
    /// Maps component types to doctor check section headers.
    var doctorSection: String {
        rawValue
    }
}

/// Definition of an installable component
struct ComponentDefinition: Identifiable {
    let id: String // Unique identifier, e.g., "core.docs-mcp-server"
    let displayName: String // e.g., "docs-mcp-server"
    let description: String // Human-readable description
    let type: ComponentType
    let packIdentifier: String? // nil for core components
    let dependencies: [String] // IDs of components this depends on
    let isRequired: Bool // If true, always installed with its pack/core
    /// Claude Code hook event name (e.g. "SessionStart") for hookFile components.
    /// When set, the engine auto-registers this hook in settings.local.json.
    let hookEvent: String?
    let installAction: ComponentInstallAction

    /// Additional doctor checks that cannot be auto-derived from installAction.
    /// Used for components with .shellCommand or multi-step verification needs.
    let supplementaryChecks: [any DoctorCheck]

    init(
        id: String,
        displayName: String,
        description: String,
        type: ComponentType,
        packIdentifier: String?,
        dependencies: [String],
        isRequired: Bool,
        hookEvent: String? = nil,
        installAction: ComponentInstallAction,
        supplementaryChecks: [any DoctorCheck] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.type = type
        self.packIdentifier = packIdentifier
        self.dependencies = dependencies
        self.isRequired = isRequired
        self.hookEvent = hookEvent
        self.installAction = installAction
        self.supplementaryChecks = supplementaryChecks
    }
}

/// How to install a component
enum ComponentInstallAction {
    case mcpServer(MCPServerConfig)
    case plugin(name: String)
    case brewInstall(package: String)
    case shellCommand(command: String)
    case settingsMerge(source: URL?)
    case gitignoreEntries(entries: [String])
    case copyPackFile(source: URL, destination: String, fileType: CopyFileType)
}

/// File type for `copyPackFile` actions — determines the target directory.
enum CopyFileType: String {
    case skill
    case hook
    case command
    case agent
    case generic
}

extension CopyFileType {
    /// Relative subdirectory within `.claude/` (e.g. `"skills/"`, `"hooks/"`).
    /// Returns `""` for `.generic`.
    var subdirectory: String {
        switch self {
        case .skill: "skills/"
        case .hook: "hooks/"
        case .command: "commands/"
        case .agent: "agents/"
        case .generic: ""
        }
    }

    func baseDirectory(in environment: Environment) -> URL {
        switch self {
        case .skill: environment.skillsDirectory
        case .hook: environment.hooksDirectory
        case .command: environment.commandsDirectory
        case .agent: environment.agentsDirectory
        case .generic: environment.claudeDirectory
        }
    }

    func destinationURL(in environment: Environment, destination: String) -> URL {
        baseDirectory(in: environment).appendingPathComponent(destination)
    }

    /// Project-scoped base directory under `<project>/.claude/`.
    func projectBaseDirectory(projectPath: URL) -> URL {
        let claudeDir = projectPath.appendingPathComponent(Constants.FileNames.claudeDirectory)
        switch self {
        case .skill: return claudeDir.appendingPathComponent("skills")
        case .hook: return claudeDir.appendingPathComponent("hooks")
        case .command: return claudeDir.appendingPathComponent("commands")
        case .agent: return claudeDir.appendingPathComponent("agents")
        case .generic: return claudeDir
        }
    }
}

/// Configuration for an MCP server
struct MCPServerConfig {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
    /// MCP scope: "local" (per-user, per-project — default), "project" (team-shared), or "user" (cross-project).
    let scope: String?

    init(name: String, command: String, args: [String], env: [String: String], scope: String? = nil) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.scope = scope
    }

    /// HTTP transport MCP server (no command, just URL)
    static func http(name: String, url: String, scope: String? = nil) -> MCPServerConfig {
        MCPServerConfig(name: name, command: "http", args: [url], env: [:], scope: scope)
    }

    /// The resolved scope, defaulting to "local" for per-project isolation.
    var resolvedScope: String {
        scope ?? "local"
    }

    /// Return a new config with `__KEY__` placeholders substituted in env values, command, and args.
    /// Name is preserved (used as lookup key in artifact tracking).
    func substituting(_ values: [String: String]) -> MCPServerConfig {
        guard !values.isEmpty else { return self }
        let sub = { (text: String) in TemplateEngine.substitute(template: text, values: values, emitWarnings: false) }
        return MCPServerConfig(
            name: name,
            command: sub(command),
            args: args.map(sub),
            env: env.mapValues(sub),
            scope: scope
        )
    }
}
