import Foundation
@testable import mcs
import Testing

struct ClaudeIntegrationTests {
    private let project = URL(fileURLWithPath: "/tmp/mcs-project")

    @Test("mcpRemove runs in the given working directory")
    func mcpRemoveForwardsWorkingDirectory() {
        let shell = MockShellRunner()
        ClaudeIntegration(shell: shell).mcpRemove(name: "srv", scope: "local", workingDirectory: project)

        #expect(shell.runCalls.map(\.arguments) == [["claude", "mcp", "remove", "-s", "local", "srv"]])
        #expect(shell.runCalls.map(\.workingDirectory) == [project.path])
    }

    @Test("mcpAdd runs its pre-remove and its add in the given working directory")
    func mcpAddForwardsWorkingDirectoryToBothCalls() {
        let shell = MockShellRunner()
        ClaudeIntegration(shell: shell).mcpAdd(
            name: "srv", scope: "local", arguments: ["--", "npx"], workingDirectory: project
        )

        #expect(shell.runCalls.map { $0.arguments.prefix(3) } == [
            ["claude", "mcp", "remove"], ["claude", "mcp", "add"],
        ])
        #expect(shell.runCalls.map(\.workingDirectory) == [project.path, project.path])
    }
}
