import Foundation
@testable import mcs
import Testing

struct ConfigurationDiscoveryTests {
    @Test("discovers MCP servers when project root is a subdirectory of git root")
    func discoversMCPServersViaWalkUp() throws {
        let home = try makeGlobalTmpDir(label: "discovery-walkup")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let gitRoot = home.appendingPathComponent("my-repo")
        let subProject = gitRoot.appendingPathComponent("packages/lib")
        try FileManager.default.createDirectory(
            at: gitRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: subProject.appendingPathComponent(Constants.FileNames.claudeDirectory),
            withIntermediateDirectories: true
        )

        let claudeJSON: [String: Any] = [
            "projects": [
                gitRoot.path: [
                    "mcpServers": [
                        "docs-server": [
                            "command": "npx",
                            "args": ["-y", "docs-server"],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput())
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(subProject))

        #expect(config.mcpServers.count == 1)
        #expect(config.mcpServers.first?.name == "docs-server")
        #expect(config.mcpServers.first?.scope == "local")
    }

    @Test("recovers a multi-token hook interpreter from the registered command")
    func recoversHookInterpreter() throws {
        let home = try makeGlobalTmpDir(label: "discovery-interpreter")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeDir.appendingPathComponent("hooks"),
            withIntermediateDirectories: true
        )

        try """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "node --experimental-strip-types .claude/hooks/gate.ts" }] }
            ],
            "SessionStart": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/start.sh" }] }
            ]
          }
        }
        """.write(
            to: claudeDir.appendingPathComponent(Constants.FileNames.settingsLocal),
            atomically: true,
            encoding: .utf8
        )
        let hooksDir = claudeDir.appendingPathComponent("hooks")
        try "console.log('gate')".write(
            to: hooksDir.appendingPathComponent("gate.ts"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/bash\necho start".write(
            to: hooksDir.appendingPathComponent("start.sh"),
            atomically: true,
            encoding: .utf8
        )

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput(colorsEnabled: false))
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(projectRoot))

        let gate = config.hookFiles.first { $0.filename == "gate.ts" }
        #expect(gate?.hookRegistration?.event == .preToolUse)
        #expect(gate?.hookRegistration?.interpreter == "node --experimental-strip-types")

        // A bash hook records no interpreter — that is the default, not a value to carry.
        let start = config.hookFiles.first { $0.filename == "start.sh" }
        #expect(start?.hookRegistration?.event == .sessionStart)
        #expect(start?.hookRegistration?.interpreter == nil)
    }

    @Test("discovers hooks inside the pack-id subdirectories sync installs into")
    func discoversNamespacedHooks() throws {
        let home = try makeGlobalTmpDir(label: "discovery-namespaced")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        // Exactly how sync lays hooks out: .claude/hooks/<pack-id>/<file>.
        let packHooks = claudeDir.appendingPathComponent("hooks/ts-pack")
        try FileManager.default.createDirectory(at: packHooks, withIntermediateDirectories: true)
        try "console.log('gate')".write(
            to: packHooks.appendingPathComponent("gate.ts"),
            atomically: true,
            encoding: .utf8
        )

        try """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "node --experimental-strip-types .claude/hooks/ts-pack/gate.ts" }] }
            ]
          }
        }
        """.write(
            to: claudeDir.appendingPathComponent(Constants.FileNames.settingsLocal),
            atomically: true,
            encoding: .utf8
        )

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput(colorsEnabled: false))
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(projectRoot))

        // A flat listing found nothing here, so the interpreter round-trip never reached a real
        // synced hook — only hand-written ones at the top level.
        let gate = try #require(config.hookFiles.first { $0.filename == "gate.ts" })
        #expect(gate.hookRegistration?.event == .preToolUse)
        #expect(gate.hookRegistration?.interpreter == "node --experimental-strip-types")
    }

    @Test("a hook does not inherit the registration of one whose name it is a suffix of")
    func doesNotCorrelateBySubstring() throws {
        let home = try makeGlobalTmpDir(label: "discovery-substring")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let packHooks = claudeDir.appendingPathComponent("hooks/p")
        try FileManager.default.createDirectory(at: packHooks, withIntermediateDirectories: true)
        // "gate.ts" is a substring of "pre-gate.ts".
        try "1".write(to: packHooks.appendingPathComponent("gate.ts"), atomically: true, encoding: .utf8)
        try "2".write(to: packHooks.appendingPathComponent("pre-gate.ts"), atomically: true, encoding: .utf8)

        // Only `pre-gate.ts` is registered, and under a distinctive interpreter.
        try """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "bun .claude/hooks/p/pre-gate.ts" }] }
            ]
          }
        }
        """.write(
            to: claudeDir.appendingPathComponent(Constants.FileNames.settingsLocal),
            atomically: true,
            encoding: .utf8
        )

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput(colorsEnabled: false))
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(projectRoot))

        let pre = try #require(config.hookFiles.first { $0.filename == "pre-gate.ts" })
        #expect(pre.hookRegistration?.interpreter == "bun")
        // The unregistered hook must stay unregistered rather than borrowing the other's event.
        let gate = try #require(config.hookFiles.first { $0.filename == "gate.ts" })
        #expect(gate.hookRegistration == nil)
    }

    @Test("discovers MCP servers when project root equals git root")
    func discoversMCPServersExactMatch() throws {
        let home = try makeGlobalTmpDir(label: "discovery-exact")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory),
            withIntermediateDirectories: true
        )

        let claudeJSON: [String: Any] = [
            "projects": [
                projectRoot.path: [
                    "mcpServers": [
                        "docs-server": [
                            "command": "npx",
                            "args": ["-y", "docs-server"],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput())
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(projectRoot))

        #expect(config.mcpServers.count == 1)
        #expect(config.mcpServers.first?.name == "docs-server")
    }

    @Test("returns empty when no MCP servers match subdirectory project")
    func noMCPServersWhenBoundaryBlocks() throws {
        let home = try makeGlobalTmpDir(label: "discovery-boundary")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let outerRepo = home.appendingPathComponent("outer")
        let innerRepo = outerRepo.appendingPathComponent("inner")
        try FileManager.default.createDirectory(
            at: outerRepo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: innerRepo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: innerRepo.appendingPathComponent(Constants.FileNames.claudeDirectory),
            withIntermediateDirectories: true
        )

        // Server is keyed at outer repo, but inner repo has its own .git boundary
        let claudeJSON: [String: Any] = [
            "projects": [
                outerRepo.path: [
                    "mcpServers": [
                        "docs-server": [
                            "command": "npx",
                            "args": ["-y", "docs-server"],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let discovery = ConfigurationDiscovery(environment: env, output: CLIOutput())
        let config = discovery.discover(scope: ConfigurationDiscovery.Scope.project(innerRepo))

        #expect(config.mcpServers.isEmpty)
    }
}
