import Foundation
@testable import mcs

/// Mock `ClaudeCLI` that records calls without executing real shell commands.
final class MockClaudeCLI: ClaudeCLI, @unchecked Sendable {
    struct MCPAddCall: Equatable {
        let name: String
        let scope: String
        let arguments: [String]
        var workingDirectory: URL?
    }

    struct MCPRemoveCall: Equatable {
        let name: String
        let scope: String
        var workingDirectory: URL?
    }

    var isAvailable: Bool {
        true
    }

    var mcpAddCalls: [MCPAddCall] = []
    var mcpRemoveCalls: [MCPRemoveCall] = []

    /// Result to return from all operations. Defaults to success.
    var result = ShellResult(exitCode: 0, stdout: "", stderr: "")

    @discardableResult
    func mcpAdd(name: String, scope: String, arguments: [String], workingDirectory: URL?) -> ShellResult {
        mcpAddCalls.append(MCPAddCall(
            name: name, scope: scope, arguments: arguments, workingDirectory: workingDirectory
        ))
        return result
    }

    @discardableResult
    func mcpRemove(name: String, scope: String, workingDirectory: URL?) -> ShellResult {
        mcpRemoveCalls.append(MCPRemoveCall(name: name, scope: scope, workingDirectory: workingDirectory))
        return result
    }

    struct PluginCall: Equatable {
        let id: String
        let scope: String
        var workingDirectory: URL?
    }

    var marketplaceAddCalls: [String] = []
    var pluginInstallCalls: [PluginCall] = []
    var pluginRemoveCalls: [PluginCall] = []

    /// What `plugin marketplace list` reports. Defaults to the official marketplace.
    var marketplaces = [PluginMarketplace(
        name: Constants.Plugins.officialMarketplace, repo: Constants.Plugins.officialMarketplaceRepo
    )]

    /// What `plugin list` reports. A successful install adds to it and a removal drops from it,
    /// so a sync → doctor → remove sequence sees what the real CLI would.
    var installedPlugins: [InstalledPlugin] = []

    @discardableResult
    func pluginMarketplaceAdd(repo: String) -> ShellResult {
        marketplaceAddCalls.append(repo)
        return result
    }

    func pluginMarketplaceList() -> ShellResult {
        jsonResult(marketplaces)
    }

    func pluginList(workingDirectory: URL?) -> ShellResult {
        jsonResult(installedPlugins.map { plugin in
            // Mirrors the CLI: a local install is enabled only when listed from its own project.
            guard plugin.scope == Constants.PluginScope.local else { return plugin }
            let here = plugin.isInstall(atScope: plugin.scope, projectDirectory: workingDirectory)
            return InstalledPlugin(
                id: plugin.id, scope: plugin.scope, enabled: plugin.enabled && here, projectPath: plugin.projectPath
            )
        })
    }

    @discardableResult
    func pluginInstall(id: String, scope: String, workingDirectory: URL?) -> ShellResult {
        pluginInstallCalls.append(PluginCall(id: id, scope: scope, workingDirectory: workingDirectory))
        if result.succeeded {
            installedPlugins.append(InstalledPlugin(
                id: id, scope: scope, enabled: true,
                projectPath: scope == Constants.PluginScope.local ? workingDirectory?.path : nil
            ))
        }
        return result
    }

    @discardableResult
    func pluginRemove(id: String, scope: String, workingDirectory: URL?) -> ShellResult {
        pluginRemoveCalls.append(PluginCall(id: id, scope: scope, workingDirectory: workingDirectory))
        if result.succeeded {
            installedPlugins.removeAll { $0.id == id && $0.isInstall(atScope: scope, projectDirectory: workingDirectory) }
        }
        return result
    }

    private func jsonResult(_ value: some Encodable) -> ShellResult {
        do {
            let data = try JSONEncoder().encode(value)
            return ShellResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        } catch {
            return ShellResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }
}

/// Mock `ShellRunning` that records calls without executing real processes.
final class MockShellRunner: ShellRunning, @unchecked Sendable {
    struct RunCall: Equatable {
        let executable: String
        let arguments: [String]
        let workingDirectory: String?
        let additionalEnvironment: [String: String]
        let interactive: Bool
    }

    let environment: Environment

    /// Mock is `@unchecked Sendable` and may be called concurrently from
    /// `DispatchQueue.concurrentPerform`; the lock makes the queue and call arrays consistent.
    private let lock = NSLock()

    var runCalls: [RunCall] = []
    var commandExistsCalls: [String] = []

    /// Default result when neither queue below produces a value.
    /// Dispatch precedence in `run()`: `runResultsByFirstArg[arguments.first]` →
    /// `runResults.removeFirst()` → `result`.
    var result = ShellResult(exitCode: 0, stdout: "", stderr: "")

    /// Positional queue for `run()`. Only safe for sequential call orders.
    var runResults: [ShellResult] = []

    /// Argument-keyed dispatch for `run()`, keyed on `arguments.first`. Use this for tests
    /// where `concurrentPerform` interleaves calls — every matching call returns the same
    /// canned response regardless of order.
    var runResultsByFirstArg: [String: ShellResult] = [:]

    /// Controls what `commandExists()` returns. Defaults to `true`.
    var commandExistsResult = true

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    func commandExists(_ command: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        commandExistsCalls.append(command)
        return commandExistsResult
    }

    @discardableResult
    func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: String?,
        additionalEnvironment: [String: String],
        interactive: Bool
    ) -> ShellResult {
        lock.lock()
        defer { lock.unlock() }
        runCalls.append(RunCall(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment,
            interactive: interactive
        ))
        if let firstArg = arguments.first, let scripted = runResultsByFirstArg[firstArg] {
            return scripted
        }
        if !runResults.isEmpty {
            return runResults.removeFirst()
        }
        return result
    }

    @discardableResult
    func shell(
        _: String,
        workingDirectory _: String?,
        additionalEnvironment _: [String: String],
        interactive _: Bool
    ) -> ShellResult {
        result
    }
}

/// Minimal TechPack implementation for tests.
struct MockTechPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String = "Mock pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    private let storedChecks: [any DoctorCheck]

    init(
        identifier: String,
        displayName: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        supplementaryDoctorChecks: [any DoctorCheck] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.components = components
        self.templates = templates
        storedChecks = supplementaryDoctorChecks
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        storedChecks
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}

/// Mock TechPack that declares prompts and resolves them using `context.priorValues`
/// (falling back to a `defaultAnswer` closure when no prior exists). Simulates the
/// adapter's "skip keys already in resolvedValues" filter so tests can verify the
/// full reuse pipeline without needing interactive stdin.
///
/// A prompt declared without a default is advertised with `defaultAnswer` as its default,
/// so the non-interactive preflight sees the same answer the mock will give. Tests about
/// unanswerable prompts use a real `ExternalPackAdapter` instead.
struct MockPromptTechPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String = "Mock pack with prompts"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    private let prompts: [PromptDefinition]
    private let defaultAnswer: @Sendable (String) -> String

    init(
        identifier: String,
        displayName: String,
        prompts: [PromptDefinition],
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        defaultAnswer: @escaping @Sendable (String) -> String = { "default-\($0)" }
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.prompts = prompts
        self.components = components
        self.templates = templates
        self.defaultAnswer = defaultAnswer
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func declaredPrompts(context _: ProjectConfigContext) -> [PromptDefinition] {
        prompts.map { prompt in
            PromptDefinition(
                key: prompt.key, type: prompt.type, label: prompt.label,
                defaultValue: prompt.defaultValue ?? defaultAnswer(prompt.key),
                options: prompt.options, detectPatterns: prompt.detectPatterns,
                scriptCommand: prompt.scriptCommand
            )
        }
    }

    func templateValues(context: ProjectConfigContext) -> [String: String] {
        var resolved: [String: String] = [:]
        for prompt in prompts where context.resolvedValues[prompt.key] == nil {
            // Mirror real executor semantics: a select prior is only a valid answer
            // when it still matches one of the current options. Otherwise fall back
            // to the mock's defaultAnswer (simulating the user picking fresh).
            let prior = context.priorValues[prompt.key]
            if prompt.type == .select, let prior, let options = prompt.options,
               !options.contains(where: { $0.value == prior }) {
                resolved[prompt.key] = defaultAnswer(prompt.key)
            } else if prompt.type == .fileDetect {
                // The real executor re-scans and asks when a fileDetect key reaches it,
                // so reaching this branch at all means the prior was not reused.
                resolved[prompt.key] = defaultAnswer(prompt.key)
            } else {
                resolved[prompt.key] = prior ?? defaultAnswer(prompt.key)
            }
        }
        return resolved
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}

/// Mock TechPack that tracks `configureProject` invocations.
final class TrackingMockTechPack: TechPack, @unchecked Sendable {
    let identifier: String
    let displayName: String
    let description: String = "Tracking mock pack"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    var configureProjectCallCount = 0

    init(
        identifier: String,
        displayName: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.components = components
        self.templates = templates
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {
        configureProjectCallCount += 1
    }
}

// MARK: - PackEntry Factories

/// Create a `PackRegistryFile.PackEntry` for tests.
func makeRegistryEntry(
    identifier: String,
    commitSHA: String = "abc123def456",
    sourceURL: String? = nil,
    ref: String? = nil
) -> PackRegistryFile.PackEntry {
    PackRegistryFile.PackEntry(
        identifier: identifier,
        displayName: identifier,
        author: nil,
        sourceURL: sourceURL ?? "https://example.com/\(identifier).git",
        ref: ref,
        commitSHA: commitSHA,
        localPath: identifier,
        addedAt: "2026-01-01T00:00:00Z",
        trustedScriptHashes: [:],
        isLocal: nil
    )
}

/// Create a local `PackRegistryFile.PackEntry` for tests.
func makeLocalRegistryEntry(
    identifier: String,
    localPath: String = "/Users/dev/local-pack"
) -> PackRegistryFile.PackEntry {
    PackRegistryFile.PackEntry(
        identifier: identifier,
        displayName: identifier,
        author: nil,
        sourceURL: localPath,
        ref: nil,
        commitSHA: "local",
        localPath: localPath,
        addedAt: "2026-01-01T00:00:00Z",
        trustedScriptHashes: [:],
        isLocal: true
    )
}

/// Create the on-disk pack clone directory under `Environment(home:).packsDirectory` so
/// `PackEntry.resolvedPath(packsDirectory:)` resolves and `PathContainment.safePath` allows
/// it. The directory is empty — tests that mock the shell don't need a real git checkout,
/// only a valid working directory to pass to git invocations.
func preparePackDir(home: URL, identifier: String) throws {
    let dir = Environment(home: home).packsDirectory.appendingPathComponent(identifier)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

// MARK: - Temp Directory Helpers

/// Create a bare temp directory with a UUID-unique name.
func makeTmpDir(label: String = "test") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcs-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Opt the sandbox out of the (default-on) update-check hook so tests that assert on
/// SessionStart hook shape don't see the mcs update-check entry auto-injected.
func disableUpdateCheck(home: URL) throws {
    let env = Environment(home: home)
    var config = MCSConfig()
    config.updateCheck = false
    try config.save(to: env.mcsConfigFile)
}

/// Create a temp directory pre-configured for global-scope tests (`.claude/` + `.mcs/` subdirectories).
func makeGlobalTmpDir(label: String = "global") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcs-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(Constants.FileNames.claudeDirectory),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(".mcs"),
        withIntermediateDirectories: true
    )
    try seedGlobalGitignore(home: dir)
    return dir
}

/// Write mcs's core entries to the sandbox's global gitignore.
///
/// `GitignoreCheck` resolves this file from the injected `Environment`'s home, so a sandbox
/// without one reports "global gitignore not found" and every doctor run inside it carries an
/// extra issue unrelated to what the test is asserting. Seeding it makes the sandbox look like a
/// machine `mcs sync` has already run on, which is the state these fixtures assume.
func seedGlobalGitignore(home: URL) throws {
    let gitDir = home
        .appendingPathComponent(".config")
        .appendingPathComponent("git")
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try (GitignoreManager.coreEntries.joined(separator: "\n") + "\n").write(
        to: gitDir.appendingPathComponent("ignore"),
        atomically: true, encoding: .utf8
    )
}

/// Create a temp home pre-configured with the Claude Code canonical layout:
/// `.claude/` directory plus (optional) `.claude.json` sibling file.
func makeClaudeHome(label: String = "claude-home", withJSON: Bool = true) throws -> URL {
    let home = try makeGlobalTmpDir(label: label)
    if withJSON {
        try "{}".write(
            to: home.appendingPathComponent(".claude.json"),
            atomically: true, encoding: .utf8
        )
    }
    return home
}

/// Create a temp directory pre-configured as a project sandbox:
/// home with `.claude/` + `.mcs/`, plus a nested project with `.git/` + `.claude/`.
func makeSandboxProject(label: String = "project") throws -> (home: URL, project: URL) {
    let home = try makeGlobalTmpDir(label: label)
    let project = home.appendingPathComponent("test-project")
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent(".git"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent(Constants.FileNames.claudeDirectory),
        withIntermediateDirectories: true
    )
    return (home, project)
}

/// Count non-overlapping occurrences of `needle` within `haystack`.
func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

/// Create a `Configurator` configured for global-scope sync.
func makeGlobalSyncConfigurator(
    home: URL,
    mockCLI: MockClaudeCLI = MockClaudeCLI(),
    shell: (any ShellRunning)? = nil
) -> Configurator {
    let env = Environment(home: home)
    return Configurator(
        environment: env,
        output: CLIOutput(colorsEnabled: false),
        shell: shell ?? ShellRunner(environment: env),
        strategy: GlobalSyncStrategy(environment: env),
        claudeCLI: mockCLI
    )
}
