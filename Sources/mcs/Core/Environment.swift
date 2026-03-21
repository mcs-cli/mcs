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
        let home = home ?? URL(fileURLWithPath: NSHomeDirectory())
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
            brewPrefix = URL(fileURLWithPath: resolvedBrew)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent().deletingLastPathComponent().path
        } else {
            #if arch(arm64)
                brewPrefix = "/opt/homebrew"
            #else
                brewPrefix = "/usr/local"
            #endif
            brewPath = "\(brewPrefix)/bin/brew"
        }

        gitPath = Self.resolvedGitPath
    }

    /// Directory where external tech pack checkouts live (`~/.mcs/packs/`).
    var packsDirectory: URL {
        mcsDirectory.appendingPathComponent(Constants.ExternalPacks.packsDirectory)
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
