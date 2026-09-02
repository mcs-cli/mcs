import Foundation

// MARK: - Check implementations

//
// ## fix() Responsibility Boundaries
//
// `doctor --fix` handles only:
// - **Cleanup**: Removing deprecated components (MCP servers, plugins)
// - **Migration**: One-time data moves (state files)
// - **Trivial repairs**: Permission fixes (chmod), gitignore additions (idempotent)
// - **Scope reconciliation**: Removing a pack from one scope when a provably equivalent copy
//   exists in another, by calling `Configurator.unconfigurePack` rather than re-implementing
//   removal. This is the one category that drives the sync engine, so it carries a higher bar:
//   the check must refuse the fix unless it can prove nothing is lost — see
//   `ScopeDuplicationCheck`, which gates on component subset, prompt-answer parity, and the
//   recorded hash of every file it would delete. Do not copy the pattern without the gates.
//
// `doctor --fix` does NOT handle:
// - **Additive operations**: Installing packages, registering servers, copying hooks/skills/commands.
//   These are `mcs sync`'s responsibility.
//
// This separation keeps `doctor --fix` predictable, and destructive only where it can show its work.

struct CommandCheck: DoctorCheck {
    let name: String
    let section: String
    let command: String
    var isOptional: Bool = false
    var environment: Environment = .init()

    func check() -> CheckResult {
        let shell = ShellRunner(environment: environment)
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

    let environment: Environment

    init(name: String, serverName: String, projectRoot: URL? = nil, environment: Environment = Environment()) {
        self.name = name
        self.serverName = serverName
        self.projectRoot = projectRoot
        self.environment = environment
    }

    func check() -> CheckResult {
        let claudeJSONPath = environment.claudeJSON
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
        if let root = projectRoot,
           let projects = json[Constants.JSONKeys.projects] as? [String: Any],
           let matchedKey = ProjectDetector.resolveProjectKey(from: root, in: Set(projects.keys)),
           let projectEntry = projects[matchedKey] as? [String: Any],
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
    let projectRoot: URL?
    let environment: Environment

    init(pluginRef: PluginRef, projectRoot: URL? = nil, environment: Environment = Environment()) {
        self.pluginRef = pluginRef
        self.projectRoot = projectRoot
        self.environment = environment
    }

    var name: String {
        pluginRef.bareName
    }

    var section: String {
        "Plugins"
    }

    func check() -> CheckResult {
        var projectSettingsError: String?

        // Tier 1: Project-scoped settings.local.json
        if let root = projectRoot {
            let projectSettingsURL = root
                .appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent(Constants.FileNames.settingsLocal)
            do {
                let projectSettings = try Settings.load(from: projectSettingsURL)
                if projectSettings.enabledPlugins?[pluginRef.bareName] == true {
                    return .pass("enabled (project)")
                }
            } catch {
                // Corrupt project settings — fall through to global, but note for diagnostics
                projectSettingsError = error.localizedDescription
            }
        }

        // Tier 2: Global settings.json
        let settingsURL = environment.claudeSettings
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            if projectSettingsError != nil {
                return .fail("settings.local.json is corrupt and settings.json not found")
            }
            return .fail("settings.json not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsURL)
        } catch {
            return .fail("settings.json is invalid: \(error.localizedDescription)")
        }
        if settings.enabledPlugins?[pluginRef.bareName] == true {
            if let errorDesc = projectSettingsError {
                return .warn("enabled (global) — settings.local.json is unreadable: \(errorDesc)")
            }
            return .pass("enabled")
        }
        if projectSettingsError != nil {
            return .fail("not enabled (settings.local.json is corrupt)")
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
        switch FileHasher.drift(of: path, expecting: expectedHash) {
        case .matches:
            .pass("content matches")
        case .missing:
            .skip("missing (checked separately)")
        case .directory:
            .skip("directory (contents checked individually)")
        case .changed:
            .warn("modified since last sync")
        case let .unreadable(error):
            .fail("could not read file: \(error.localizedDescription)")
        }
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore original content")
    }
}

struct HookCheck: DoctorCheck {
    let hookName: String
    var isOptional: Bool = false
    var environment: Environment = .init()

    var name: String {
        hookName
    }

    var section: String {
        "Hooks"
    }

    func check() -> CheckResult {
        let hookPath = environment.hooksDirectory.appendingPathComponent(hookName)
        guard FileManager.default.fileExists(atPath: hookPath.path) else {
            return isOptional ? .skip("not installed (optional)") : .fail("missing")
        }
        guard FileManager.default.isExecutableFile(atPath: hookPath.path) else {
            return .fail("not executable")
        }
        return .pass("present and executable")
    }

    func fix() -> FixResult {
        let hookPath = environment.hooksDirectory.appendingPathComponent(hookName)
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
    var environment: Environment = .init()

    var name: String {
        "Global gitignore"
    }

    var section: String {
        "Gitignore"
    }

    func check() -> CheckResult {
        let gitignoreManager = GitignoreManager(shell: ShellRunner(environment: environment))
        let lines: Set<String>
        do {
            guard let result = try gitignoreManager.readLines() else {
                return .fail("global gitignore not found")
            }
            lines = result
        } catch {
            return .fail("global gitignore unreadable: \(error.localizedDescription)")
        }
        let missing = GitignoreManager.coreEntries.filter { !lines.contains($0) }
        if missing.isEmpty {
            return .pass("all entries present")
        }
        return .fail("missing entries: \(missing.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        let gitignoreManager = GitignoreManager(shell: ShellRunner(environment: environment))
        do {
            try gitignoreManager.addCoreEntries()
            return .fixed("added missing entries")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct ProjectIndexCheck: DoctorCheck {
    var environment: Environment = .init()

    var name: String {
        "Project index"
    }

    var section: String {
        "Project"
    }

    func check() -> CheckResult {
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
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
        let indexFile = ProjectIndex(path: environment.projectsIndexFile)
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

/// A hook command a pack contributed, paired with what the pack declared for it.
struct ExpectedHook {
    let command: String

    /// Declared registration when the command still traces back to a component, which is the
    /// normal case — sync only records a hook command for a component that had a
    /// `HookRegistration`, so every freshly written record has one.
    ///
    /// nil means the recorded command no longer maps to any component in the pack: the component
    /// was removed or its destination renamed since the last sync. There is nothing to compare
    /// against, so the command falls back to presence-only verification rather than being
    /// reported as drift.
    let registration: HookRegistration?
}

/// Verifies that pack-contributed hook commands are still present in the settings file, and that
/// they are registered the way the declaring component said they should be.
///
/// A hook whose matcher does not match any tool Claude Code emits installs cleanly, registers, and
/// fires for nothing — the symptom is an empty log, which reads as "no problems" rather than
/// "never ran". Comparing the installed `event` and `matcher` against the component's
/// `HookRegistration` turns that silence into a reported finding.
///
/// Absence is a failure; a registration that differs from what was declared is a warning, because
/// `Settings.addHookEntry` rewrites a differing matcher on the next sync — so "run 'mcs sync'" is
/// a remedy that actually works, and a user who narrowed a matcher deliberately is not blocked.
///
/// This proves the declared matcher reached settings, **not** that it matches any tool name Claude
/// Code actually emits. Only a real session transcript proves that.
struct HookSettingsCheck: DoctorCheck {
    let expectations: [ExpectedHook]
    let settingsPath: URL
    let packName: String

    init(expectations: [ExpectedHook], settingsPath: URL, packName: String) {
        self.expectations = expectations
        self.settingsPath = settingsPath
        self.packName = packName
    }

    /// Presence-only verification, for callers with no declaration to compare against.
    init(commands: [String], settingsPath: URL, packName: String) {
        self.init(
            expectations: commands.map { ExpectedHook(command: $0, registration: nil) },
            settingsPath: settingsPath,
            packName: packName
        )
    }

    var name: String {
        "Hook entries (\(packName))"
    }

    var section: String {
        "Hooks"
    }

    func check() -> CheckResult {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            return .fail("settings file not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsPath)
        } catch {
            return .fail("cannot read settings: \(error.localizedDescription)")
        }

        // One traversal of the hook tree, then a lookup per expectation.
        let placementsByCommand = settings.hookPlacementsByCommand()
        var missing: [String] = []
        var drift: [String] = []
        for expectation in expectations {
            let placements = placementsByCommand[expectation.command] ?? []
            guard !placements.isEmpty else {
                missing.append(expectation.command)
                continue
            }
            if let registration = expectation.registration,
               let finding = driftFinding(
                   command: expectation.command,
                   registration: registration,
                   placements: placements
               ) {
                drift.append(finding)
            }
        }

        if !missing.isEmpty {
            // Append drift so a failure never swallows findings from other expectations.
            let details = ["missing hook commands: \(missing.joined(separator: ", "))"] + drift
            return .fail(details.joined(separator: "; "))
        }
        if !drift.isEmpty {
            return .warn("\(drift.joined(separator: "; ")) — run 'mcs sync'")
        }
        // Claim "as declared" only when every expectation actually had a declaration — a mixed set
        // would otherwise assert verification the presence-only entries never got.
        let allDeclared = !expectations.isEmpty && expectations.allSatisfy { $0.registration != nil }
        return .pass(allDeclared ? "all hook commands registered as declared" : "all hook commands present")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore or update hook entries")
    }

    // MARK: - Helpers

    /// Describes how `placements` differ from what was declared, or nil when they satisfy it.
    ///
    /// Extra registrations are not policed — a command may appear under events the pack never
    /// declared, which is the user's business. Only the declared registration must be present.
    private func driftFinding(
        command: String,
        registration: HookRegistration,
        placements: [Settings.HookPlacement]
    ) -> String? {
        let expectedEvent = registration.event.rawValue
        let underEvent = placements.filter { $0.event == expectedEvent }
        guard !underEvent.isEmpty else {
            let actual = Set(placements.map(\.event)).sorted().joined(separator: ", ")
            return "'\(command)' is registered under \(actual), pack declares \(expectedEvent)"
        }
        // Any group under the declared event carrying the declared matcher satisfies this: a
        // command can legitimately sit in more than one group, since `addHookEntry` matches on the
        // group's *first* entry and appends rather than replaces when it finds no match.
        let expected = normalizedMatcher(registration.matcher)
        guard !underEvent.contains(where: { normalizedMatcher($0.matcher) == expected }) else { return nil }
        let actual = underEvent.map { describeMatcher($0.matcher) }.joined(separator: ", ")
        return "'\(command)' has matcher \(actual) under \(expectedEvent),"
            + " pack declares \(describeMatcher(registration.matcher))"
    }
}

/// Verifies the binary a pack's hook commands are invoked with is resolvable.
///
/// A hook whose interpreter is missing installs cleanly, registers in settings, and dies the
/// moment Claude Code runs it — and the symptom is an empty log, which reads as "no problems
/// found" rather than "never ran". Only the binary is checked, never executed: running an
/// arbitrary interpreter during doctor risks hangs, and its arguments are the author's business.
struct HookInterpreterCheck: DoctorCheck {
    /// Path fragments belonging to per-shell version managers.
    ///
    /// A binary found here resolves in the user's terminal but often not in the environment
    /// Claude Code hands its hooks, which is a warning rather than a failure because mcs cannot
    /// tell the two environments apart from here.
    private static let versionManagerFragments = ["/.nvm/", "/.asdf/", "/mise/", "/.pyenv/", "/.rbenv/", "/.volta/", "/.fnm/"]

    let binary: String
    let packName: String
    var environment: Environment = .init()

    var name: String {
        "Hook interpreter: \(binary) (\(packName))"
    }

    var section: String {
        "Hooks"
    }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: environment)
        guard let resolved = shell.resolvedPath(of: binary) else {
            return .fail("not found — hooks using it will not run")
        }
        if let fragment = Self.versionManagerFragments.first(where: resolved.contains) {
            return .warn(
                "resolves to \(resolved) via \(fragment.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
                    + " — Claude Code may not have it on PATH when it runs the hook"
            )
        }
        return .pass("resolves to \(resolved)")
    }

    func fix() -> FixResult {
        .notFixable("Install '\(binary)' and make sure it is on PATH for GUI applications")
    }
}

/// Verifies that pack-contributed settings keys are still present in the settings file.
struct SettingsKeysCheck: DoctorCheck {
    let keys: [String]
    let settingsPath: URL
    let packName: String

    var name: String {
        "Settings keys (\(packName))"
    }

    var section: String {
        "Settings"
    }

    func check() -> CheckResult {
        let data: Data
        do {
            data = try Data(contentsOf: settingsPath)
        } catch {
            return .fail("settings file not found or unreadable")
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .fail("settings file is not a JSON object")
            }
            json = parsed
        } catch {
            return .fail("settings file contains invalid JSON: \(error.localizedDescription)")
        }
        let missing = keys.filter { SettingsHasher.extractValue($0, from: json) == nil }
        if missing.isEmpty {
            return .pass("all settings keys present")
        }
        return .fail("missing settings keys: \(missing.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore settings keys")
    }
}

/// Verifies that pack-contributed settings values haven't drifted from the last sync.
/// Skips if the settings file is missing or invalid (defers to `SettingsKeysCheck`).
/// Reports `.warn` on drift — advisory, since the user may have intentionally changed values.
struct SettingsDriftCheck: DoctorCheck {
    let keys: [String]
    let expectedHash: String
    let settingsPath: URL
    let packName: String

    var name: String {
        "Settings values (\(packName))"
    }

    var section: String {
        "Settings"
    }

    func check() -> CheckResult {
        let data: Data
        do {
            data = try Data(contentsOf: settingsPath)
        } catch {
            return .skip("settings file not found (checked separately)")
        }
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .skip("settings file is not a JSON object (checked separately)")
            }
            json = parsed
        } catch {
            return .skip("settings file invalid: \(error.localizedDescription) (checked separately)")
        }
        guard let currentHash = SettingsHasher.hash(keyPaths: keys, in: json) else {
            return .skip("no settings keys to verify")
        }
        if currentHash == expectedHash {
            return .pass("values unchanged")
        }
        return .warn("settings values modified since last sync")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore settings")
    }
}

/// Verifies that pack-contributed gitignore entries are still present in the global gitignore.
struct PackGitignoreCheck: DoctorCheck {
    let entries: [String]
    let packName: String
    var environment: Environment = .init()

    var name: String {
        "Gitignore entries (\(packName))"
    }

    var section: String {
        "Gitignore"
    }

    func check() -> CheckResult {
        let gitignoreManager = GitignoreManager(shell: ShellRunner(environment: environment))
        let lines: Set<String>
        do {
            guard let result = try gitignoreManager.readLines() else {
                return .fail("global gitignore not found")
            }
            lines = result
        } catch {
            return .fail("global gitignore unreadable: \(error.localizedDescription)")
        }
        let missing = entries.filter { !lines.contains($0) }
        if missing.isEmpty {
            return .pass("all entries present")
        }
        return .fail("missing entries: \(missing.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to restore gitignore entries")
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
