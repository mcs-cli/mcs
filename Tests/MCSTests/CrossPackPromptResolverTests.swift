import Foundation
@testable import mcs
import Testing

@Suite("CrossPackPromptResolver")
struct CrossPackPromptResolverTests {
    // MARK: - Helpers

    private func makeContext() -> ProjectConfigContext {
        ProjectConfigContext(
            projectPath: FileManager.default.temporaryDirectory,
            repoName: "test-repo",
            output: CLIOutput(colorsEnabled: false),
            resolvedValues: [:],
            isGlobalScope: false
        )
    }

    private func makeMockPack(
        name: String,
        prompts: [ExternalPromptDefinition]
    ) -> PromptMockPack {
        PromptMockPack(
            identifier: name,
            displayName: name,
            prompts: prompts
        )
    }

    // MARK: - Grouping

    @Test("Groups input prompts with the same key across packs")
    func groupsInputPrompts() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH_PREFIX", type: .input,
                label: "Branch prefix from A", defaultValue: "feature",
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH_PREFIX", type: .input,
                label: "Branch prefix from B", defaultValue: "feat",
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.count == 1)
        #expect(shared["BRANCH_PREFIX"]?.count == 2)
        #expect(shared["BRANCH_PREFIX"]?[0].packName == "pack-a")
        #expect(shared["BRANCH_PREFIX"]?[1].packName == "pack-b")
    }

    @Test("Groups select prompts with the same key across packs")
    func groupsSelectPrompts() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "PLATFORM", type: .select,
                label: "Target platform", defaultValue: nil,
                options: [ExternalPromptOption(value: "ios", label: "iOS")],
                detectPatterns: nil, scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "PLATFORM", type: .select,
                label: "Platform for B", defaultValue: nil,
                options: [ExternalPromptOption(value: "macos", label: "macOS")],
                detectPatterns: nil, scriptCommand: nil
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.count == 1)
        #expect(shared["PLATFORM"]?.count == 2)
    }

    @Test("Single-pack prompts are not grouped as shared")
    func singlePackNotShared() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "UNIQUE_KEY", type: .input,
                label: "Only in A", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "OTHER_KEY", type: .input,
                label: "Only in B", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.isEmpty)
    }

    @Test("script prompts are excluded from deduplication")
    func scriptExcluded() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH", type: .script,
                label: nil, defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: "git branch"
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH", type: .script,
                label: nil, defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: "echo main"
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.isEmpty)
    }

    @Test("fileDetect prompts are excluded from deduplication")
    func fileDetectExcluded() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "PROJECT", type: .fileDetect,
                label: "Xcode project", defaultValue: nil,
                options: nil, detectPatterns: ["*.xcodeproj"], scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "PROJECT", type: .fileDetect,
                label: "Project file", defaultValue: nil,
                options: nil, detectPatterns: ["*.xcworkspace"], scriptCommand: nil
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.isEmpty)
    }

    @Test("Three packs sharing a key produces a group of 3")
    func threePacksShared() {
        let packs = (1 ... 3).map { i in
            makeMockPack(name: "pack-\(i)", prompts: [
                ExternalPromptDefinition(
                    key: "SHARED", type: .input,
                    label: "Pack \(i) label", defaultValue: nil,
                    options: nil, detectPatterns: nil, scriptCommand: nil
                ),
            ])
        }

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: packs, context: context)

        #expect(shared["SHARED"]?.count == 3)
    }

    @Test("Mixed types across packs: only deduplicable types are grouped")
    func mixedTypes() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "VAL", type: .input,
                label: "Input A", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
            ExternalPromptDefinition(
                key: "DETECT", type: .fileDetect,
                label: "Detect A", defaultValue: nil,
                options: nil, detectPatterns: ["*.txt"], scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "VAL", type: .input,
                label: "Input B", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
            ExternalPromptDefinition(
                key: "DETECT", type: .fileDetect,
                label: "Detect B", defaultValue: nil,
                options: nil, detectPatterns: ["*.md"], scriptCommand: nil
            ),
        ])

        let context = makeContext()
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        #expect(shared.count == 1)
        #expect(shared["VAL"] != nil)
        #expect(shared["DETECT"] == nil)
    }

    @Test("Skips keys that are already in context.resolvedValues")
    func skipsAlreadyResolvedKeys() {
        let packA = makeMockPack(name: "pack-a", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH_PREFIX", type: .input,
                label: "Prefix from A", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])
        let packB = makeMockPack(name: "pack-b", prompts: [
            ExternalPromptDefinition(
                key: "BRANCH_PREFIX", type: .input,
                label: "Prefix from B", defaultValue: nil,
                options: nil, detectPatterns: nil, scriptCommand: nil
            ),
        ])

        let context = ProjectConfigContext(
            projectPath: FileManager.default.temporaryDirectory,
            repoName: "test-repo",
            output: CLIOutput(colorsEnabled: false),
            resolvedValues: ["BRANCH_PREFIX": "feature"],
            isGlobalScope: false
        )
        let shared = CrossPackPromptResolver.groupSharedPrompts(packs: [packA, packB], context: context)

        // BRANCH_PREFIX is already resolved — should NOT appear in shared prompts
        #expect(shared.isEmpty)
    }

    @Test("Global scope filters out fileDetect from declaredPrompts")
    func globalScopeFiltersFileDetect() {
        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test",
            description: "Test",
            author: nil,
            minMCSVersion: nil,
            components: [],
            templates: nil,
            prompts: [
                ExternalPromptDefinition(
                    key: "PROJECT", type: .fileDetect,
                    label: "Xcode project", defaultValue: nil,
                    options: nil, detectPatterns: ["*.xcodeproj"], scriptCommand: nil
                ),
                ExternalPromptDefinition(
                    key: "PREFIX", type: .input,
                    label: "Branch prefix", defaultValue: "feature",
                    options: nil, detectPatterns: nil, scriptCommand: nil
                ),
            ],
            configureProject: nil,
            supplementaryDoctorChecks: nil
        )
        let adapter = ExternalPackAdapter(
            manifest: manifest,
            packPath: FileManager.default.temporaryDirectory
        )

        let globalContext = ProjectConfigContext(
            projectPath: FileManager.default.temporaryDirectory,
            repoName: "test",
            output: CLIOutput(colorsEnabled: false),
            resolvedValues: [:],
            isGlobalScope: true
        )

        let prompts = adapter.declaredPrompts(context: globalContext)
        #expect(prompts.count == 1)
        #expect(prompts[0].key == "PREFIX")
    }
}

// MARK: - MCPServerConfig substitution

@Suite("MCPServerConfig — substituting")
struct MCPServerConfigSubstitutionTests {
    @Test("Substitutes env values")
    func substitutesEnv() {
        let config = MCPServerConfig(
            name: "test-server",
            command: "npx",
            args: ["-y", "server@latest"],
            env: ["API_KEY": "__USER_API_KEY__", "TOKEN": "__SERVICE_TOKEN__"]
        )
        let result = config.substituting(["USER_API_KEY": "abc123", "SERVICE_TOKEN": "tok456"])

        #expect(result.env["API_KEY"] == "abc123")
        #expect(result.env["TOKEN"] == "tok456")
    }

    @Test("Substitutes command and args")
    func substitutesCommandArgs() {
        let config = MCPServerConfig(
            name: "test-server",
            command: "__CMD__",
            args: ["--url", "__SERVER_URL__"],
            env: [:]
        )
        let result = config.substituting(["CMD": "uvx", "SERVER_URL": "https://example.com"])

        #expect(result.command == "uvx")
        #expect(result.args == ["--url", "https://example.com"])
    }

    @Test("Preserves name during substitution")
    func preservesName() {
        let config = MCPServerConfig(
            name: "__NAME__",
            command: "cmd",
            args: [],
            env: [:]
        )
        let result = config.substituting(["NAME": "should-not-change"])

        // Name contains __NAME__ literally because substituting() preserves name
        #expect(result.name == "__NAME__")
    }

    @Test("Empty values returns same config")
    func emptyValuesNoOp() {
        let config = MCPServerConfig(
            name: "server",
            command: "cmd",
            args: ["--flag"],
            env: ["KEY": "__PLACEHOLDER__"]
        )
        let result = config.substituting([:])

        #expect(result.env["KEY"] == "__PLACEHOLDER__")
        #expect(result.command == "cmd")
    }

    @Test("Preserves scope during substitution")
    func preservesScope() {
        let config = MCPServerConfig(
            name: "server",
            command: "cmd",
            args: [],
            env: [:],
            scope: "project"
        )
        let result = config.substituting(["FOO": "bar"])

        #expect(result.scope == "project")
    }
}

// MARK: - Settings load with substitution

@Suite("Settings — load with substitution")
struct SettingsLoadSubstitutionTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-settings-sub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Substitutes placeholders in settings JSON before parsing")
    func substitutesBeforeParsing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsJSON = """
        {
            "env": {
                "API_KEY": "__USER_API_KEY__",
                "STATIC": "unchanged"
            }
        }
        """
        let url = tmpDir.appendingPathComponent("settings.json")
        try settingsJSON.write(to: url, atomically: true, encoding: .utf8)

        let settings = try Settings.load(from: url, substituting: ["USER_API_KEY": "secret123"])

        let envData = try #require(settings.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["API_KEY"] == "secret123")
        #expect(env["STATIC"] == "unchanged")
    }

    @Test("Empty values falls back to normal load")
    func emptyValuesFallsBack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsJSON = """
        {
            "env": {
                "KEY": "__PLACEHOLDER__"
            }
        }
        """
        let url = tmpDir.appendingPathComponent("settings.json")
        try settingsJSON.write(to: url, atomically: true, encoding: .utf8)

        let settings = try Settings.load(from: url, substituting: [:])

        let envData = try #require(settings.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["KEY"] == "__PLACEHOLDER__")
    }

    @Test("JSON-escapes values containing quotes and backslashes")
    func jsonEscapesSpecialCharacters() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsJSON = """
        {
            "env": {
                "PATH_VAR": "__SOME_PATH__"
            }
        }
        """
        let url = tmpDir.appendingPathComponent("settings.json")
        try settingsJSON.write(to: url, atomically: true, encoding: .utf8)

        // Value with quotes and backslashes that would break JSON if not escaped
        let settings = try Settings.load(
            from: url,
            substituting: ["SOME_PATH": #"C:\Users\me "quoted""#]
        )

        let envData = try #require(settings.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["PATH_VAR"] == #"C:\Users\me "quoted""#)
    }

    @Test("Missing file returns empty settings")
    func missingFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")

        let settings = try Settings.load(from: url, substituting: ["FOO": "bar"])

        #expect(settings.hooks == nil)
        #expect(settings.enabledPlugins == nil)
        #expect(settings.extraJSON.isEmpty)
    }
}

// MARK: - Undeclared placeholder scanner extension

@Suite("ConfiguratorSupport — scanForUndeclaredPlaceholders")
struct ScannerExtensionTests {
    @Test("Finds placeholders in settings file sources")
    func findsSettingsPlaceholders() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-scan-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settingsJSON = """
        {
            "env": {
                "API_KEY": "__MY_API_KEY__"
            }
        }
        """
        let url = tmpDir.appendingPathComponent("settings.json")
        try settingsJSON.write(to: url, atomically: true, encoding: .utf8)

        let pack = PromptMockPack(
            identifier: "test-pack",
            displayName: "Test",
            components: [ComponentDefinition(
                id: "test-pack.settings",
                displayName: "Settings",
                description: "Test",
                type: .configuration,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .settingsMerge(source: url)
            )]
        )

        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: [pack], resolvedValues: [:]
        )

        #expect(undeclared.contains("MY_API_KEY"))
    }

    @Test("Finds placeholders in MCP server env values")
    func findsMCPEnvPlaceholders() {
        let pack = PromptMockPack(
            identifier: "test-pack",
            displayName: "Test",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test",
                    command: "npx",
                    args: ["-y", "server"],
                    env: ["TOKEN": "__SERVICE_TOKEN__"]
                ))
            )]
        )

        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: [pack], resolvedValues: [:]
        )

        #expect(undeclared.contains("SERVICE_TOKEN"))
    }

    @Test("Finds placeholders in MCP server command")
    func findsMCPCommandPlaceholders() {
        let pack = PromptMockPack(
            identifier: "test-pack",
            displayName: "Test",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test",
                    command: "__MY_CMD__",
                    args: [],
                    env: [:]
                ))
            )]
        )

        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: [pack], resolvedValues: [:]
        )

        #expect(undeclared.contains("MY_CMD"))
    }

    @Test("Finds placeholders in MCP server args")
    func findsMCPArgPlaceholders() {
        let pack = PromptMockPack(
            identifier: "test-pack",
            displayName: "Test",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test",
                    command: "npx",
                    args: ["--endpoint", "__API_ENDPOINT__"],
                    env: [:]
                ))
            )]
        )

        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: [pack], resolvedValues: [:]
        )

        #expect(undeclared.contains("API_ENDPOINT"))
    }

    @Test("Already-resolved keys are not reported as undeclared")
    func resolvedKeysExcluded() {
        let pack = PromptMockPack(
            identifier: "test-pack",
            displayName: "Test",
            components: [ComponentDefinition(
                id: "test-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "test-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test",
                    command: "npx",
                    args: [],
                    env: ["TOKEN": "__SERVICE_TOKEN__"]
                ))
            )]
        )

        let undeclared = ConfiguratorSupport.scanForUndeclaredPlaceholders(
            packs: [pack], resolvedValues: ["SERVICE_TOKEN": "already-resolved"]
        )

        #expect(!undeclared.contains("SERVICE_TOKEN"))
    }
}

// MARK: - PromptMockPack

/// A mock TechPack that supports declaredPrompts for testing cross-pack dedup.
private struct PromptMockPack: TechPack {
    let identifier: String
    let displayName: String
    let description: String = "Mock pack for prompt tests"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution] = []
    let supplementaryDoctorChecks: [any DoctorCheck] = []
    private let prompts: [ExternalPromptDefinition]

    init(
        identifier: String,
        displayName: String,
        prompts: [ExternalPromptDefinition] = [],
        components: [ComponentDefinition] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.prompts = prompts
        self.components = components
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}

    func declaredPrompts(context: ProjectConfigContext) -> [ExternalPromptDefinition] {
        context.isGlobalScope
            ? prompts.filter { $0.type != .fileDetect }
            : prompts
    }
}
