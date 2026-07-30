import Foundation

// MARK: - Misconfigured Check

/// A diagnostic check returned when a doctor check definition has missing required fields.
/// Always reports a warning so the user knows the pack manifest is misconfigured.
struct MisconfiguredDoctorCheck: DoctorCheck {
    let name: String
    let section: String
    let reason: String

    func check() -> CheckResult {
        .warn("misconfigured: \(reason)")
    }

    func fix() -> FixResult {
        .notFixable("Fix the pack's techpack.yaml: \(reason)")
    }
}

// MARK: - Command Exists Check

/// Checks that a command is available. Bare command names are resolved via `/usr/bin/which`.
/// - **No args**: only checks PATH presence (does not run the command — avoids hangs from
///   interactive CLIs like `ollama`).
/// - **With args**: executes the resolved command with the given arguments and checks the exit code.
struct ExternalCommandExistsCheck: DoctorCheck {
    let name: String
    let section: String
    let command: String
    let args: [String]
    let fixCommand: String?
    let scriptRunner: ScriptRunner
    let environment: Environment

    init(
        name: String, section: String, command: String, args: [String],
        fixCommand: String?, scriptRunner: ScriptRunner, environment: Environment = Environment()
    ) {
        self.name = name
        self.section = section
        self.command = command
        self.args = args
        self.fixCommand = fixCommand
        self.scriptRunner = scriptRunner
        self.environment = environment
    }

    var fixCommandPreview: String? {
        fixCommand
    }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: environment)

        // Resolve bare command names to absolute paths. Process.executableURL
        // does not search PATH, so "ollama" must become "/opt/homebrew/bin/ollama".
        let resolved: String
        if command.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                return .fail("not found")
            }
            resolved = command
        } else {
            let which = shell.run(Constants.CLI.which, arguments: [command])
            guard which.succeeded, !which.stdout.isEmpty else {
                // Command not on PATH at all.
                return .fail("not found")
            }
            resolved = which.stdout
        }

        // No args: the intent is just "is this binary available?" — finding it
        // on PATH is sufficient. Running it could hang (e.g. ollama starts a server).
        if args.isEmpty { return .pass("installed") }

        let result = shell.run(resolved, arguments: args)
        if result.succeeded { return .pass("available") }
        return .fail("not found")
    }

    func fix() -> FixResult {
        guard let fixCommand else {
            return .notFixable("Run 'mcs sync' to install dependencies")
        }
        let result = scriptRunner.runCommand(fixCommand)
        if result.succeeded {
            return .fixed("fix command succeeded")
        }
        return .failed(result.stderr)
    }
}

// MARK: - File Exists Check

/// Checks that a file exists at the given path.
struct ExternalFileExistsCheck: ScopedPathCheck {
    let name: String
    let section: String
    let path: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        let resolved: String
        switch resolvePath() {
        case .noProjectRoot:
            return .skip("no project root for project-scoped check")
        case .pathTraversal:
            return .fail("path '\(path)' escapes project root — possible path traversal")
        case let .resolved(path):
            resolved = path
        }
        if FileManager.default.fileExists(atPath: resolved) {
            return .pass("present")
        }
        return .fail("missing")
    }
}

// MARK: - Directory Exists Check

/// Checks that a directory exists at the given path.
struct ExternalDirectoryExistsCheck: ScopedPathCheck {
    let name: String
    let section: String
    let path: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        let resolved: String
        switch resolvePath() {
        case .noProjectRoot:
            return .skip("no project root for project-scoped check")
        case .pathTraversal:
            return .fail("path '\(path)' escapes project root — possible path traversal")
        case let .resolved(path):
            resolved = path
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
            return .pass("present")
        }
        return .fail("missing")
    }
}

// MARK: - File Contains Check

/// Checks that a file contains a given substring.
struct ExternalFileContainsCheck: ScopedPathCheck {
    let name: String
    let section: String
    let path: String
    let pattern: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        let resolved: String
        switch resolvePath() {
        case .noProjectRoot:
            return .skip("no project root for project-scoped check")
        case .pathTraversal:
            return .fail("path '\(path)' escapes project root — possible path traversal")
        case let .resolved(path):
            resolved = path
        }
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return .fail("file not found or unreadable")
        }
        if content.contains(pattern) {
            return .pass("pattern found")
        }
        return .fail("pattern not found")
    }
}

// MARK: - File Not Contains Check

/// Checks that a file does NOT contain a given substring.
struct ExternalFileNotContainsCheck: ScopedPathCheck {
    let name: String
    let section: String
    let path: String
    let pattern: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        let resolved: String
        switch resolvePath() {
        case .noProjectRoot:
            return .skip("no project root for project-scoped check")
        case .pathTraversal:
            return .fail("path '\(path)' escapes project root — possible path traversal")
        case let .resolved(path):
            resolved = path
        }
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            // File not found — pattern is not present, so this passes
            return .pass("file not present (pattern absent)")
        }
        if content.contains(pattern) {
            return .fail("unwanted pattern found")
        }
        return .pass("pattern absent")
    }
}

// MARK: - Shell Script Check

/// Runs a custom shell script with exit code conventions:
/// - 0 = pass
/// - 1 = fail
/// - 2 = warn
/// - 3 = skip
/// stdout is used as the message.
struct ExternalShellScriptCheck: DoctorCheck {
    let name: String
    let section: String
    let scriptPath: URL
    let packPath: URL
    let fixScriptPath: URL?
    let fixCommand: String?
    let scriptRunner: ScriptRunner

    var fixCommandPreview: String? {
        if let fixCommand { return fixCommand }
        guard let fixScriptPath else { return nil }
        return fixScriptPath.path.replacingOccurrences(of: packPath.path + "/", with: "")
    }

    func check() -> CheckResult {
        let result: ScriptRunner.ScriptResult
        do {
            result = try scriptRunner.run(script: scriptPath, packPath: packPath)
        } catch {
            return .fail(error.localizedDescription)
        }

        let message = result.stdout.isEmpty ? name : result.stdout

        switch result.exitCode {
        case 0:
            return .pass(message)
        case 1:
            return .fail(message)
        case 2:
            return .warn(message)
        case 3:
            return .skip(message)
        default:
            return .fail("unexpected exit code \(result.exitCode): \(message)")
        }
    }

    func fix() -> FixResult {
        if let fixScriptPath {
            do {
                let result = try scriptRunner.run(script: fixScriptPath, packPath: packPath)
                if result.succeeded {
                    let message = result.stdout.isEmpty ? "fix applied" : result.stdout
                    return .fixed(message)
                }
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                return .failed(message.isEmpty ? "fix script failed" : message)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        if let fixCommand {
            let result = scriptRunner.runCommand(fixCommand)
            if result.succeeded {
                let message = result.stdout.isEmpty ? "fix applied" : result.stdout
                return .fixed(message)
            }
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            return .failed(message.isEmpty ? "fix command failed" : message)
        }

        return .notFixable("No fix available for this check")
    }
}

// MARK: - Hook Event Exists Check

/// Checks that a hook event is registered in the Claude settings, optionally asserting the
/// matcher and command of the group that registers it.
/// Pack-contributed replacement for the engine-level HookEventCheck.
///
/// Resolves project `settings.local.json` before global `settings.json` — see
/// `SettingsReadingCheck`.
///
/// `matcher` and `command` exist for hooks a pack ships through a settings file. Those never
/// reach `PackArtifactRecord.hookCommands` — only `hook:` components do — so `HookSettingsCheck`,
/// which derives its expectations from `ComponentDefinition.hookRegistration`, cannot see them.
/// For a `hook:` component, prefer the derived check and leave these fields off: restating the
/// matcher gives a second copy that can drift from the component's.
///
/// This proves the declared matcher reached settings, not that it matches a tool Claude Code
/// actually emits. Only a real session transcript proves that.
struct ExternalHookEventExistsCheck: SettingsReadingCheck {
    /// Whether the registration found under `event` satisfied the declared assertions.
    private enum Registration {
        case satisfied
        /// The event is registered, but not the way the check declared. Carries the detail.
        case mismatch(String)
    }

    let name: String
    let section: String
    let event: String
    /// Exact matcher a `HookGroup` under `event` must carry. Compared as a raw string — the regex
    /// is deliberately not interpreted, since Claude Code is what evaluates it at runtime.
    var matcher: String?
    /// Substring a hook command must contain. When `matcher` is also given, both must be satisfied
    /// by the *same* group — that is what proves the registration belongs to this pack.
    var commandSubstring: String?
    let isOptional: Bool
    var projectRoot: URL?
    var environment: Environment = .init()

    func check() -> CheckResult {
        // Any file that registers the event answers the probe, mismatch or not; otherwise a
        // wrongly-registered project hook would fall through to a correct global one and pass.
        let probe: SettingsProbe<Registration> = probeSettings { url in
            guard let groups = try Settings.load(from: url).hooks?[event] else { return nil }
            return evaluate(groups)
        }

        if let match = probe.match {
            switch match.value {
            case .satisfied:
                return probe.readErrors.isEmpty
                    ? .pass("registered in \(match.fileName)")
                    : .warn("registered in \(match.fileName)\(probe.errorSuffix)")
            case let .mismatch(detail):
                // Advisory, not fatal: the registration is present, and a user who narrowed a
                // matcher on purpose should not be blocked by a red doctor.
                return isOptional
                    ? .skip("\(detail) in \(match.fileName) (optional)")
                    : .warn("\(detail) in \(match.fileName)\(probe.errorSuffix)")
            }
        }
        guard probe.anyFileExisted else {
            return .fail("no settings file found (searched \(searchedFileNames))")
        }
        if !probe.readErrors.isEmpty {
            return .fail("\(event) not registered\(probe.errorSuffix)")
        }
        return isOptional
            ? .skip("\(event) not registered (optional)")
            : .fail("\(event) not registered in \(searchedFileNames)")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to merge settings")
    }

    // MARK: - Helpers

    /// Judge the groups registered under `event` against the declared matcher and command.
    private func evaluate(_ groups: [Settings.HookGroup]) -> Registration {
        guard matcher != nil || commandSubstring != nil else { return .satisfied }

        // Narrow to the groups the matcher admits, then require the command inside one of those —
        // checking them independently would let two unrelated groups satisfy the pair between them.
        let candidates: [Settings.HookGroup]
        if let matcher {
            let expected = normalizedMatcher(matcher)
            candidates = groups.filter { normalizedMatcher($0.matcher) == expected }
            guard !candidates.isEmpty else {
                let actual = groups.isEmpty
                    ? "none"
                    : groups.map { describeMatcher($0.matcher) }.joined(separator: ", ")
                return .mismatch(
                    "\(event) has no hook group with matcher \(describeMatcher(matcher)) — found \(actual)"
                )
            }
        } else {
            candidates = groups
        }

        if let commandSubstring {
            let found = candidates.contains { group in
                (group.hooks ?? []).contains { $0.command?.contains(commandSubstring) == true }
            }
            guard found else {
                let scope = matcher.map { " with matcher \(describeMatcher($0))" } ?? ""
                return .mismatch(
                    "\(event) group\(scope) has no hook command containing '\(commandSubstring)'"
                )
            }
        }

        return .satisfied
    }
}

// MARK: - Settings Key Equals Check

/// Checks that a specific settings key has an expected value.
/// Uses dot-notation keyPath to navigate the raw JSON, ensuring forward compatibility
/// with any key — not just those modeled by the Settings struct.
///
/// Resolves project `settings.local.json` before global `settings.json` — see
/// `SettingsReadingCheck`. This matches Claude Code's own precedence, so the check reports
/// the value actually in effect.
struct ExternalSettingsKeyEqualsCheck: SettingsReadingCheck {
    let name: String
    let section: String
    let keyPath: String
    let expectedValue: String
    var projectRoot: URL?
    var environment: Environment = .init()

    func check() -> CheckResult {
        let probe: SettingsProbe<String> = probeSettings { url in
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCSError.invalidConfiguration("not a JSON object")
            }
            return resolveKeyPath(keyPath, in: json)
        }

        guard probe.anyFileExisted else {
            return .fail("no settings file found (searched \(searchedFileNames))")
        }
        guard let match = probe.match else {
            return .warn("\(keyPath) not set\(probe.errorSuffix)")
        }
        if match.value == expectedValue {
            return .pass("\(keyPath) = \(expectedValue) (\(match.fileName))\(probe.errorSuffix)")
        }
        return .warn(
            "\(keyPath) is '\(match.value)' in \(match.fileName), expected '\(expectedValue)'\(probe.errorSuffix)"
        )
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to merge settings")
    }

    private func resolveKeyPath(_ keyPath: String, in json: [String: Any]) -> String? {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any = json
        for part in parts {
            guard let dict = current as? [String: Any],
                  let next = dict[part]
            else { return nil }
            current = next
        }
        if let str = current as? String { return str }
        if let bool = current as? Bool { return String(bool) }
        if let num = current as? NSNumber { return num.stringValue }
        return nil
    }
}

// MARK: - Factory

/// Creates concrete `DoctorCheck` instances from declarative `ExternalDoctorCheckDefinition`.
/// Definitions are expected to be pre-validated by `ExternalPackManifest.validate()`.
enum ExternalDoctorCheckFactory {
    /// Build a `DoctorCheck` from a declarative definition.
    ///
    /// - Parameters:
    ///   - definition: The declarative check from the manifest (must be pre-validated)
    ///   - packPath: Root directory of the external pack
    ///   - projectRoot: Project root for project-scoped checks (nil if not in a project)
    ///   - scriptRunner: Runner for shell script checks
    static func makeCheck(
        from definition: ExternalDoctorCheckDefinition,
        packPath: URL,
        projectRoot: URL?,
        scriptRunner: ScriptRunner,
        environment: Environment = Environment()
    ) -> any DoctorCheck {
        let section = definition.section ?? "External Pack"
        let scope = definition.scope ?? .global

        switch definition.type {
        case .commandExists:
            guard let command = definition.command, !command.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "commandExists requires non-empty 'command'"
                )
            }
            return ExternalCommandExistsCheck(
                name: definition.name,
                section: section,
                command: command,
                args: definition.args ?? [],
                fixCommand: definition.fixCommand,
                scriptRunner: scriptRunner,
                environment: environment
            )

        case .fileExists:
            guard let path = definition.path, !path.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileExists requires non-empty 'path'"
                )
            }
            return ExternalFileExistsCheck(
                name: definition.name,
                section: section,
                path: path,
                scope: scope,
                projectRoot: projectRoot
            )

        case .directoryExists:
            guard let path = definition.path, !path.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "directoryExists requires non-empty 'path'"
                )
            }
            return ExternalDirectoryExistsCheck(
                name: definition.name,
                section: section,
                path: path,
                scope: scope,
                projectRoot: projectRoot
            )

        case .fileContains:
            guard let path = definition.path, !path.isEmpty,
                  let pattern = definition.pattern, !pattern.isEmpty
            else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileContains requires non-empty 'path' and 'pattern'"
                )
            }
            return ExternalFileContainsCheck(
                name: definition.name,
                section: section,
                path: path,
                pattern: pattern,
                scope: scope,
                projectRoot: projectRoot
            )

        case .fileNotContains:
            guard let path = definition.path, !path.isEmpty,
                  let pattern = definition.pattern, !pattern.isEmpty
            else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileNotContains requires non-empty 'path' and 'pattern'"
                )
            }
            return ExternalFileNotContainsCheck(
                name: definition.name,
                section: section,
                path: path,
                pattern: pattern,
                scope: scope,
                projectRoot: projectRoot
            )

        case .shellScript:
            // command is guaranteed non-empty by manifest validation
            let scriptURL = packPath.appendingPathComponent(definition.command ?? "")
            let fixURL: URL? = definition.fixScript.map {
                packPath.appendingPathComponent($0)
            }
            return ExternalShellScriptCheck(
                name: definition.name,
                section: section,
                scriptPath: scriptURL,
                packPath: packPath,
                fixScriptPath: fixURL,
                fixCommand: definition.fixCommand,
                scriptRunner: scriptRunner
            )

        case .hookEventExists:
            guard let event = definition.event, !event.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "hookEventExists requires non-empty 'event'"
                )
            }
            // `scope` is deliberately not forwarded: it selects a base directory for an
            // author-supplied `path`, and this check has none. The settings file is implied by
            // the check type, so `projectRoot` alone drives resolution.
            return ExternalHookEventExistsCheck(
                name: definition.name,
                section: section,
                event: event,
                matcher: definition.matcher,
                // `command` carries a per-type meaning: a script path for `shellScript`, a binary
                // for `commandExists`, a hook-command substring here.
                commandSubstring: definition.command,
                isOptional: definition.isOptional ?? false,
                projectRoot: projectRoot,
                environment: environment
            )

        case .settingsKeyEquals:
            guard let keyPath = definition.keyPath, !keyPath.isEmpty,
                  let expectedValue = definition.expectedValue, !expectedValue.isEmpty
            else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "settingsKeyEquals requires non-empty 'keyPath' and 'expectedValue'"
                )
            }
            // See the note on `.hookEventExists` above — `scope` does not apply here either.
            return ExternalSettingsKeyEqualsCheck(
                name: definition.name,
                section: section,
                keyPath: keyPath,
                expectedValue: expectedValue,
                projectRoot: projectRoot,
                environment: environment
            )
        }
    }
}

// MARK: - Scoped Path Protocol

/// Shared path resolution for doctor checks that operate on a file or directory
/// with global or project scope.
protocol ScopedPathCheck: DoctorCheck {
    var path: String { get }
    var scope: ExternalDoctorCheckScope { get }
    var projectRoot: URL? { get }
}

enum PathResolveResult {
    case resolved(String)
    case noProjectRoot
    case pathTraversal
}

extension ScopedPathCheck {
    func resolvePath() -> PathResolveResult {
        switch scope {
        case .global:
            return .resolved(expandTilde(path))
        case .project:
            guard let root = projectRoot else { return .noProjectRoot }
            guard let safe = PathContainment.safePath(relativePath: path, within: root) else {
                return .pathTraversal
            }
            return .resolved(safe.resolvingSymlinksInPath().path)
        }
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs sync' to install")
    }
}

// MARK: - Settings Reading Protocol

/// Shared settings-file resolution for doctor checks that read Claude settings.
///
/// Unlike `ScopedPathCheck`, these checks have no author-supplied path — the file is implied
/// by the check type — so resolution is driven entirely by `projectRoot`, never by the
/// manifest's `scope` field (hence the name: these checks read settings, they are not scoped).
/// Candidates are tried most-specific-first: project `settings.local.json`, then global
/// `settings.json`. That order matches Claude Code's own precedence, so a check reports on the
/// settings actually in effect.
protocol SettingsReadingCheck: DoctorCheck {
    var projectRoot: URL? { get }
    var environment: Environment { get }
}

/// Outcome of walking the candidate settings files.
struct SettingsProbe<Value> {
    /// First candidate that produced a value, with the name of the file that answered.
    let match: (value: Value, fileName: String)?
    /// Files that exist on disk but could not be read or parsed.
    let readErrors: [String]
    /// Whether any candidate file was present on disk.
    let anyFileExisted: Bool

    /// Read failures rendered for appending to a check message, empty when there were none.
    /// Single definition so every result string reports unreadable files the same way.
    var errorSuffix: String {
        readErrors.isEmpty ? "" : " — \(readErrors.joined(separator: "; "))"
    }
}

extension SettingsReadingCheck {
    /// Candidate settings files, most specific first.
    var settingsCandidates: [URL] {
        var urls: [URL] = []
        if let projectRoot {
            urls.append(
                projectRoot
                    .appendingPathComponent(Constants.FileNames.claudeDirectory)
                    .appendingPathComponent(Constants.FileNames.settingsLocal)
            )
        }
        urls.append(environment.claudeSettings)
        return urls
    }

    /// Human-readable list of the files this check consults, for diagnostics.
    var searchedFileNames: String {
        settingsCandidates.map(\.lastPathComponent).joined(separator: ", ")
    }

    /// Walk the candidates in order and return the first non-nil `read` result.
    ///
    /// Absent files are skipped rather than treated as errors — `Settings.load(from:)` returns an
    /// empty `Settings` for a missing file, so existence must be checked here to distinguish
    /// "no such file" from "file present but key absent". Read and parse failures are collected
    /// rather than discarded, so a corrupt file is always surfaced to the user.
    func probeSettings<Value>(_ read: (URL) throws -> Value?) -> SettingsProbe<Value> {
        var readErrors: [String] = []
        var anyFileExisted = false

        for url in settingsCandidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            anyFileExisted = true
            do {
                if let value = try read(url) {
                    return SettingsProbe(
                        match: (value: value, fileName: url.lastPathComponent),
                        readErrors: readErrors,
                        anyFileExisted: true
                    )
                }
            } catch {
                readErrors.append("\(url.lastPathComponent) is unreadable: \(error.localizedDescription)")
            }
        }
        return SettingsProbe(match: nil, readErrors: readErrors, anyFileExisted: anyFileExisted)
    }
}

// MARK: - Helpers

/// Expand `~` at the start of a path to the user's home directory.
func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        return NSString(string: path).expandingTildeInPath
    }
    return path
}
