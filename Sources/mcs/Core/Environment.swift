import Foundation

/// Paths, architecture detection, and system environment information.
struct Environment {
    let homeDirectory: URL
    let claudeDirectory: URL
    let claudeJSON: URL
    let claudeSettings: URL
    let hooksDirectory: URL
    let skillsDirectory: URL
    let commandsDirectory: URL
    let agentsDirectory: URL

    /// mcs-internal state directory (`~/.mcs/`).
    /// Stores pack checkouts, registry, global state, and lock file.
    let mcsDirectory: URL

    let architecture: Architecture
    let brewPrefix: String
    let brewPath: String
    let gitPath: String

    enum Architecture: String {
        case arm64
        case x86_64
    }

    // Resolved once per process via dispatch-once semantics of `static let`.
    private static let resolvedGitPath: String = resolveCommand("git") ?? "/usr/bin/git"
    private static let resolvedBrewPath: String? = resolveCommand("brew")

    init(home: URL? = nil) {
        let home = home ?? URL(fileURLWithPath: Self.defaultHomeDirectory())
        homeDirectory = home

        let claudeDir = home.appendingPathComponent(Constants.FileNames.claudeDirectory)
        claudeDirectory = claudeDir
        claudeJSON = home.appendingPathComponent(Constants.FileNames.claudeJSON)
        claudeSettings = claudeDir.appendingPathComponent("settings.json")
        hooksDirectory = claudeDir.appendingPathComponent("hooks")
        skillsDirectory = claudeDir.appendingPathComponent("skills")
        commandsDirectory = claudeDir.appendingPathComponent("commands")
        agentsDirectory = claudeDir.appendingPathComponent("agents")

        mcsDirectory = home.appendingPathComponent(".mcs")

        #if arch(arm64)
        architecture = .arm64
        #else
        architecture = .x86_64
        #endif

        if let resolvedBrew = Self.resolvedBrewPath {
            brewPath = resolvedBrew
            brewPrefix = Self.brewPrefix(forBrewPath: resolvedBrew)
        } else {
            brewPrefix = Self.defaultBrewPrefix
            brewPath = "\(brewPrefix)/bin/brew"
        }

        gitPath = Self.resolvedGitPath
    }

    /// The Homebrew prefix implied by the path `brew` was found at.
    ///
    /// Symlinks are resolved first so a shim elsewhere on PATH (`~/.local/bin/brew` pointing at the
    /// real install) still yields the prefix formulae link into. The installer itself links
    /// `$PREFIX/bin/brew -> ../Homebrew/bin/brew` on Linux and Intel macOS, which resolves to the
    /// repository checkout rather than the prefix — hence the trailing `Homebrew` is stripped.
    static func brewPrefix(forBrewPath path: String) -> String {
        var prefix = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
        if prefix.lastPathComponent == "Homebrew" {
            prefix = prefix.deletingLastPathComponent()
        }
        return prefix.path
    }

    /// The user's home directory, `$HOME` first.
    ///
    /// Foundation's `NSHomeDirectory()` resolves the passwd entry on Darwin and corelibs alike and
    /// consults `$HOME` only when there is none, so `HOME=… mcs …` used to be ignored on every
    /// platform. Preferring a non-empty `$HOME` is what makes containers, `sudo -H`-style launchers
    /// and test sandboxes work. Takes the environment as a parameter so it can be tested as a pure
    /// function.
    static func defaultHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard let home = environment["HOME"], !home.isEmpty else {
            return NSHomeDirectory()
        }
        return home
    }

    /// Expands a leading `~` against `homeDirectory`, not the passwd entry Foundation's
    /// `expandingTildeInPath` reads — otherwise a `~/…` pack path or doctor check would resolve
    /// under a different home than `~/.mcs` whenever `$HOME` is overridden.
    func expandingTilde(_ path: String) -> String {
        if path == "~" {
            return homeDirectory.path
        }
        guard path.hasPrefix("~/") else { return path }
        return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
    }

    /// Where Homebrew installs itself when no `brew` is on PATH to ask.
    static var defaultBrewPrefix: String {
        #if canImport(Darwin) && arch(arm64)
        "/opt/homebrew"
        #elseif canImport(Darwin)
        "/usr/local"
        #else
        // Linuxbrew's documented multi-user prefix; unlike macOS it does not vary by architecture.
        "/home/linuxbrew/.linuxbrew"
        #endif
    }

    /// Directory where external tech pack checkouts live (`~/.mcs/packs/`).
    var packsDirectory: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.packsDirectory)
    }

    /// Whether the `MCS_DEBUG` env var is set. Used to gate developer-facing diagnostic
    /// emits (e.g. stderr writes for non-fatal failures that would otherwise be silent).
    /// Production runs are unaffected; CI and developer shells can opt in by exporting
    /// `MCS_DEBUG=1`.
    static var isDebugMode: Bool {
        ProcessInfo.processInfo.environment["MCS_DEBUG"] != nil
    }

    /// YAML registry of installed external packs (`~/.mcs/registry.yaml`).
    var packsRegistry: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.registryFilename)
    }

    /// Global state file tracking globally-installed packs and artifacts (`~/.mcs/global-state.json`).
    var globalStateFile: URL {
        mcsDirectory.appendingPathComponent(Constants.FileNames.globalState)
    }

    /// Global Claude instructions file (`~/.claude/CLAUDE.md`).
    var globalClaudeMD: URL {
        claudeDirectory.appendingPathComponent(Constants.FileNames.claudeMD)
    }

    /// Cross-project index mapping project paths to installed packs (`~/.mcs/projects.yaml`).
    var projectsIndexFile: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.projectsIndexFilename)
    }

    /// POSIX lock file for preventing concurrent mcs execution (`~/.mcs/lock`).
    var lockFile: URL {
        mcsDirectory.appendingPathComponent(Constants.FileNames.mcsLock)
    }

    /// Update check cache file (`~/.mcs/update-check.json`).
    var updateCheckCacheFile: URL {
        mcsDirectory.appendingPathComponent(Constants.FileNames.updateCheckCache)
    }

    /// User preferences file (`~/.mcs/config.yaml`).
    var mcsConfigFile: URL {
        mcsDirectory.appendingPathComponent(Constants.FileNames.mcsConfig)
    }

    /// True when `candidate` is inside `claudeDirectory` or equal to `homeDirectory`,
    /// gated on the `.claude.json` sibling existing (confirms a real Claude Code layout).
    func isInsideClaudeHome(_ candidate: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: claudeJSON.path) else {
            return false
        }
        if PathContainment.isContained(url: candidate, within: claudeDirectory) {
            return true
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath().path
        let resolvedHome = homeDirectory.resolvingSymlinksInPath().path
        return resolvedCandidate == resolvedHome
    }

    /// PATH string that includes the Homebrew bin directory.
    var pathWithBrew: String {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let brewBin = "\(brewPrefix)/bin"
        if currentPath.contains(brewBin) {
            return currentPath
        }
        return "\(brewBin):\(currentPath)"
    }

    /// Resolves a command name to its absolute path using `/usr/bin/which`.
    /// Uses `Process` directly to avoid a circular dependency on `ShellRunner`.
    private static func resolveCommand(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Constants.CLI.which)
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read pipe data before waitUntilExit to avoid deadlock when buffer fills.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty else { return nil }
        return path
    }
}
