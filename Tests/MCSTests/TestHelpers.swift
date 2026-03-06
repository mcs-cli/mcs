import Foundation
@testable import mcs

/// Mock `ClaudeCLI` that records calls without executing real shell commands.
final class MockClaudeCLI: ClaudeCLI, @unchecked Sendable {
    struct MCPAddCall: Equatable {
        let name: String
        let scope: String
        let arguments: [String]
    }

    struct MCPRemoveCall: Equatable {
        let name: String
        let scope: String
    }

    struct PluginCall: Equatable {
        let name: String
    }

    var isAvailable: Bool {
        true
    }

    var mcpAddCalls: [MCPAddCall] = []
    var mcpRemoveCalls: [MCPRemoveCall] = []
    var pluginMarketplaceAddCalls: [String] = []
    var pluginInstallCalls: [PluginCall] = []
    var pluginRemoveCalls: [PluginCall] = []

    /// Result to return from all operations. Defaults to success.
    var result = ShellResult(exitCode: 0, stdout: "", stderr: "")

    @discardableResult
    func mcpAdd(name: String, scope: String, arguments: [String]) -> ShellResult {
        mcpAddCalls.append(MCPAddCall(name: name, scope: scope, arguments: arguments))
        return result
    }

    @discardableResult
    func mcpRemove(name: String, scope: String) -> ShellResult {
        mcpRemoveCalls.append(MCPRemoveCall(name: name, scope: scope))
        return result
    }

    @discardableResult
    func pluginMarketplaceAdd(repo: String) -> ShellResult {
        pluginMarketplaceAddCalls.append(repo)
        return result
    }

    @discardableResult
    func pluginInstall(ref: PluginRef) -> ShellResult {
        pluginInstallCalls.append(PluginCall(name: ref.bareName))
        return result
    }

    @discardableResult
    func pluginRemove(ref: PluginRef) -> ShellResult {
        pluginRemoveCalls.append(PluginCall(name: ref.bareName))
        return result
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

// MARK: - Global Test Helpers

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
    return dir
}

/// Create a `Configurator` configured for global-scope sync.
func makeGlobalConfigurator(
    home: URL,
    mockCLI: MockClaudeCLI = MockClaudeCLI()
) -> Configurator {
    let env = Environment(home: home)
    return Configurator(
        environment: env,
        output: CLIOutput(colorsEnabled: false),
        shell: ShellRunner(environment: env),
        strategy: GlobalSyncStrategy(environment: env),
        claudeCLI: mockCLI
    )
}
