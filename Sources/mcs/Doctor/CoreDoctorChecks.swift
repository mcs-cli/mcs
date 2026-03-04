import Foundation

// MARK: - Check implementations

//
// ## fix() Responsibility Boundaries
//
// `doctor --fix` handles only:
// - **Cleanup**: Removing deprecated components (MCP servers, plugins)
// - **Migration**: One-time data moves (state files)
// - **Trivial repairs**: Permission fixes (chmod), gitignore additions (idempotent)
//
// `doctor --fix` does NOT handle:
// - **Additive operations**: Installing packages, registering servers, copying hooks/skills/commands.
//   These are `mcs sync`'s responsibility.
//
// This separation keeps `doctor --fix` predictable and non-destructive.

struct CommandCheck: DoctorCheck {
    let name: String
    let section: String
    let command: String
    var isOptional: Bool = false

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        if shell.commandExists(command) {
            return .pass("installed")
        }
        if isOptional {
            return .warn("not found (optional)")
        }
        return .fail("not found")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to install dependencies")
    }
}

struct MCPServerCheck: DoctorCheck {
    let name: String
    let section = "MCP Servers"
    let serverName: String
    let projectRoot: URL?

    init(name: String, serverName: String, projectRoot: URL? = nil) {
        self.name = name
        self.serverName = serverName
        self.projectRoot = projectRoot
    }

    func check() -> CheckResult {
        let claudeJSONPath = Environment().claudeJSON
        guard FileManager.default.fileExists(atPath: claudeJSONPath.path) else {
            return .fail("~/.claude.json not found")
        }
        let data: Data
        do {
            data = try Data(contentsOf: claudeJSONPath)
        } catch {
            return .fail("cannot read ~/.claude.json: \(error.localizedDescription)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("~/.claude.json contains invalid JSON")
        }
        // Check project-scoped servers first (stored under projects[path].mcpServers)
        if let root = projectRoot,
           let projects = json[Constants.JSONKeys.projects] as? [String: Any],
           let projectEntry = projects[root.path] as? [String: Any],
           let projectMCP = projectEntry[Constants.JSONKeys.mcpServers] as? [String: Any],
           projectMCP[serverName] != nil {
            return .pass("registered")
        }
        // Fall back to global/user-scoped servers
        if let mcpServers = json[Constants.JSONKeys.mcpServers] as? [String: Any],
           mcpServers[serverName] != nil {
            return .pass("registered")
        }
        return .fail("not registered")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to register MCP servers")
    }
}

struct PluginCheck: DoctorCheck {
    let pluginRef: PluginRef
    var name: String {
        pluginRef.bareName
    }

    var section: String {
        "Plugins"
    }

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .fail("settings.json not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsURL)
        } catch {
            return .fail("settings.json is invalid: \(error.localizedDescription)")
        }
        if settings.enabledPlugins?[pluginRef.bareName] == true {
            return .pass("enabled")
        }
        return .fail("not enabled")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to install plugins")
    }
}

struct FileExistsCheck: DoctorCheck {
    let name: String
    let section: String
    let path: URL
    let fallbackPath: URL?

    init(name: String, section: String, path: URL, fallbackPath: URL? = nil) {
        self.name = name
        self.section = section
        self.path = path
        self.fallbackPath = fallbackPath
    }

    func check() -> CheckResult {
        if FileManager.default.fileExists(atPath: path.path) {
            return .pass("present")
        }
        if let fallback = fallbackPath, FileManager.default.fileExists(atPath: fallback.path) {
            return .pass("present (global)")
        }
        return .fail("missing")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to install")
    }
}

/// Checks that an installed file's content matches its expected SHA-256 hash.
/// Skips if the file is absent (existence is already covered by `FileExistsCheck`).
/// Reports `.warn` on content drift (file modified since last sync).
struct FileContentCheck: DoctorCheck {
    let name: String
    let section: String
    let path: URL
    let expectedHash: String

    func check() -> CheckResult {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .skip("missing (checked separately)")
        }
        do {
            let currentHash = try FileHasher.sha256(of: path)
            if currentHash == expectedHash {
                return .pass("content matches")
            }
            return .warn("modified since last sync")
        } catch {
            return .fail("could not read file: \(error.localizedDescription)")
        }
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore original content")
    }
}

struct HookCheck: DoctorCheck {
    let hookName: String
    var isOptional: Bool = false

    var name: String {
        hookName
    }

    var section: String {
        "Hooks"
    }

    func check() -> CheckResult {
        let hookPath = Environment().hooksDirectory.appendingPathComponent(hookName)
        guard FileManager.default.fileExists(atPath: hookPath.path) else {
            return isOptional ? .skip("not installed (optional)") : .fail("missing")
        }
        guard FileManager.default.isExecutableFile(atPath: hookPath.path) else {
            return .fail("not executable")
        }
        return .pass("present and executable")
    }

    func fix() -> FixResult {
        let env = Environment()
        let hookPath = env.hooksDirectory.appendingPathComponent(hookName)
        let fm = FileManager.default

        // Only fix permissions — additive operations (installing/replacing hooks) are
        // handled by `mcs sync`.
        guard fm.fileExists(atPath: hookPath.path) else {
            return .notFixable("Run 'mcs sync' to install hooks")
        }

        if !fm.isExecutableFile(atPath: hookPath.path) {
            do {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath.path)
                return .fixed("made executable")
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        return .notFixable("Run 'mcs sync' to reinstall hooks")
    }
}

struct GitignoreCheck: DoctorCheck {
    var name: String {
        "Global gitignore"
    }

    var section: String {
        "Gitignore"
    }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        let gitignoreManager = GitignoreManager(shell: shell)
        let gitignorePath = gitignoreManager.resolveGlobalGitignorePath()
        guard FileManager.default.fileExists(atPath: gitignorePath.path),
              let content = try? String(contentsOf: gitignorePath, encoding: .utf8)
        else {
            return .fail("global gitignore not found")
        }
        let allEntries = GitignoreManager.coreEntries
        var missing: [String] = []
        for entry in allEntries where !content.contains(entry) {
            missing.append(entry)
        }
        if missing.isEmpty {
            return .pass("all entries present")
        }
        return .fail("missing entries: \(missing.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        let shell = ShellRunner(environment: Environment())
        let gitignoreManager = GitignoreManager(shell: shell)
        do {
            try gitignoreManager.addCoreEntries()
            return .fixed("added missing entries")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct ProjectIndexCheck: DoctorCheck {
    var name: String {
        "Project index"
    }

    var section: String {
        "Project"
    }

    func check() -> CheckResult {
        let env = Environment()
        let indexFile = ProjectIndex(path: env.projectsIndexFile)
        let data: ProjectIndex.IndexData
        do {
            data = try indexFile.load()
        } catch {
            return .fail("~/.mcs/projects.yaml is corrupt: \(error.localizedDescription) — delete and re-run 'mcs sync'")
        }
        if data.projects.isEmpty {
            return .warn("no projects tracked — run 'mcs sync' to populate")
        }

        let fm = FileManager.default
        var stale: [String] = []
        for entry in data.projects {
            guard entry.path != ProjectIndex.globalSentinel else { continue }
            if !fm.fileExists(atPath: entry.path) {
                stale.append(entry.path)
            }
        }

        let projectCount = data.projects.count
        if stale.isEmpty {
            return .pass("\(projectCount) scope(s) tracked")
        }
        return .fail("\(stale.count) stale path(s) in \(projectCount) tracked scope(s)")
    }

    func fix() -> FixResult {
        let env = Environment()
        let indexFile = ProjectIndex(path: env.projectsIndexFile)
        var data: ProjectIndex.IndexData
        do {
            data = try indexFile.load()
        } catch {
            return .notFixable("Could not read project index: \(error.localizedDescription)")
        }
        let pruned = indexFile.pruneStale(in: &data)
        if pruned.isEmpty {
            return .notFixable("No stale entries found")
        }
        do {
            try indexFile.save(data)
            return .fixed("removed \(pruned.count) stale entry/entries")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct CommandFileCheck: DoctorCheck {
    let name: String
    let section = "Commands"
    let path: URL

    /// The marker that managed command files contain.
    static let managedMarker = "<!-- mcs:managed -->"

    func check() -> CheckResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return .fail("missing")
        }
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return .fail("could not read file")
        }
        if content.contains("__BRANCH_PREFIX__") {
            return .warn("present but contains unreplaced __BRANCH_PREFIX__ placeholder")
        }
        if !content.contains(Self.managedMarker) {
            return .warn("missing managed marker — run 'mcs sync' to reinstall")
        }
        return .pass("present")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to install and fill placeholders")
    }
}
