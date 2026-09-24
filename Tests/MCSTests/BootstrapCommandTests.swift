import Foundation
@testable import mcs
import Testing

struct BootstrapUnmatchedSeedKeysTests {
    @Test("Only keys matching neither a prompt nor a placeholder are unmatched")
    func reportsOnlyTypoKeys() {
        let pack = MockPromptTechPack(
            identifier: "seed-pack",
            displayName: "Seed Pack",
            prompts: [PromptDefinition(
                key: "LABEL_PREFIX", type: .input,
                label: nil, defaultValue: nil, options: nil,
                detectPatterns: nil, scriptCommand: nil
            )],
            components: [ComponentDefinition(
                id: "seed-pack.mcp",
                displayName: "MCP Server",
                description: "Test",
                type: .mcpServer,
                packIdentifier: "seed-pack",
                dependencies: [],
                isRequired: true,
                installAction: .mcpServer(MCPServerConfig(
                    name: "test", command: "npx", args: [], env: ["TOKEN": "__API_TOKEN__"]
                ))
            )]
        )
        let file = BootstrapFile(schemaVersion: 1, packs: [
            .init(source: "org/seed-pack", values: [
                "LABEL_PREFIX": "scope:",
                "API_TOKEN": "secret",
                "API_TOKNE": "secret",
            ]),
        ])
        let context = ProjectConfigContext(
            projectPath: FileManager.default.temporaryDirectory,
            repoName: "",
            output: CLIOutput(colorsEnabled: false)
        )

        let unmatched = BootstrapCommand.unmatchedSeedKeys(
            file: file, packs: [pack], context: context, includeTemplates: true
        )

        #expect(unmatched == ["API_TOKNE"])
    }
}
