import Foundation
@testable import mcs
import Testing

// MARK: - Sandbox Helpers

private func makeSandboxHome(label: String = "sandbox") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcs-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Create ~/.claude/ and ~/.mcs/ subdirectories
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(".claude"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(".mcs"),
        withIntermediateDirectories: true
    )
    return dir
}

// MARK: - MCPServerCheck Sandbox Tests

struct MCPServerCheckSandboxTests {
    @Test("pass when server exists in global mcpServers")
    func passGlobalServer() throws {
        let home = try makeSandboxHome(label: "mcp-global")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let claudeJSON: [String: Any] = [
            "mcpServers": [
                "test-server": ["command": "npx", "args": ["-y", "test-server"]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let check = MCPServerCheck(name: "Test Server", serverName: "test-server", environment: env)
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("pass when server exists in project-scoped mcpServers")
    func passProjectServer() throws {
        let home = try makeSandboxHome(label: "mcp-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeJSON: [String: Any] = [
            "projects": [
                projectRoot.path: [
                    "mcpServers": [
                        "serena": ["command": "npx", "args": ["-y", "serena"]],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let check = MCPServerCheck(
            name: "Serena", serverName: "serena",
            projectRoot: projectRoot, environment: env
        )
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when server is missing from claude.json")
    func failMissingServer() throws {
        let home = try makeSandboxHome(label: "mcp-missing")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let claudeJSON: [String: Any] = [
            "mcpServers": [
                "other-server": ["command": "npx"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: env.claudeJSON)

        let check = MCPServerCheck(name: "Missing", serverName: "missing-server", environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fail when claude.json does not exist")
    func failNoClaudeJSON() throws {
        let home = try makeSandboxHome(label: "mcp-nofile")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)
        // Don't create .claude.json

        let check = MCPServerCheck(name: "Test", serverName: "test-server", environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fail when claude.json contains invalid JSON")
    func failInvalidJSON() throws {
        let home = try makeSandboxHome(label: "mcp-invalid")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        try "not valid json".write(to: env.claudeJSON, atomically: true, encoding: .utf8)

        let check = MCPServerCheck(name: "Test", serverName: "test-server", environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }
}

// MARK: - PluginCheck Sandbox Tests

struct PluginCheckSandboxTests {
    @Test("pass when plugin is enabled in settings.json")
    func passWhenEnabled() throws {
        let home = try makeSandboxHome(label: "plugin-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        {
          "enabledPlugins": {
            "pr-review-toolkit": true
          }
        }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = PluginCheck(pluginRef: PluginRef("pr-review-toolkit"))
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when plugin is not in enabledPlugins")
    func failWhenNotEnabled() throws {
        let home = try makeSandboxHome(label: "plugin-fail")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        {
          "enabledPlugins": {
            "other-plugin": true
          }
        }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = PluginCheck(pluginRef: PluginRef("missing-plugin"))
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fail when settings.json does not exist")
    func failWhenNoSettings() throws {
        let home = try makeSandboxHome(label: "plugin-nosettings")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)
        // Don't create settings.json

        var check = PluginCheck(pluginRef: PluginRef("my-plugin"))
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }
}

// MARK: - HookCheck Sandbox Tests

struct HookCheckSandboxTests {
    @Test("pass when hook file exists and is executable")
    func passWhenExecutable() throws {
        let home = try makeSandboxHome(label: "hook-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let hooksDir = env.hooksDirectory
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hookFile = hooksDir.appendingPathComponent("lint.sh")
        try "#!/bin/bash\necho lint".write(to: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)

        var check = HookCheck(hookName: "lint.sh")
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when hook file is missing")
    func failWhenMissing() throws {
        let home = try makeSandboxHome(label: "hook-missing")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        var check = HookCheck(hookName: "nonexistent.sh")
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("skip when optional hook is missing")
    func skipWhenOptionalMissing() throws {
        let home = try makeSandboxHome(label: "hook-optional")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        var check = HookCheck(hookName: "optional.sh", isOptional: true)
        check.environment = env
        let result = check.check()
        guard case .skip = result else {
            Issue.record("Expected .skip, got \(result)")
            return
        }
    }

    @Test("fail when hook file is not executable")
    func failWhenNotExecutable() throws {
        let home = try makeSandboxHome(label: "hook-noexec")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let hooksDir = env.hooksDirectory
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hookFile = hooksDir.appendingPathComponent("lint.sh")
        try "#!/bin/bash\necho lint".write(to: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hookFile.path)

        var check = HookCheck(hookName: "lint.sh")
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fix makes non-executable hook executable")
    func fixMakesExecutable() throws {
        let home = try makeSandboxHome(label: "hook-fix")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let hooksDir = env.hooksDirectory
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hookFile = hooksDir.appendingPathComponent("lint.sh")
        try "#!/bin/bash\necho lint".write(to: hookFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hookFile.path)

        var check = HookCheck(hookName: "lint.sh")
        check.environment = env

        let fixResult = check.fix()
        guard case .fixed = fixResult else {
            Issue.record("Expected .fixed, got \(fixResult)")
            return
        }

        // Verify the file is now executable
        #expect(FileManager.default.isExecutableFile(atPath: hookFile.path))
    }

    @Test("fix returns notFixable when hook file is missing")
    func fixNotFixableWhenMissing() throws {
        let home = try makeSandboxHome(label: "hook-fix-missing")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        var check = HookCheck(hookName: "nonexistent.sh")
        check.environment = env
        let fixResult = check.fix()
        guard case .notFixable = fixResult else {
            Issue.record("Expected .notFixable, got \(fixResult)")
            return
        }
    }
}

// MARK: - ProjectIndexCheck Sandbox Tests

struct ProjectIndexCheckSandboxTests {
    @Test("pass when all tracked paths exist")
    func passWhenAllPathsExist() throws {
        let home = try makeSandboxHome(label: "index-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        // Create a real directory that the index entry points to
        let projectDir = home.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let index = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: projectDir.path, packIDs: ["ios"], in: &data)
        try index.save(data)

        var check = ProjectIndexCheck()
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when stale paths exist")
    func failWhenStalePaths() throws {
        let home = try makeSandboxHome(label: "index-stale")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let index = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: "/nonexistent/path/\(UUID().uuidString)", packIDs: ["ios"], in: &data)
        try index.save(data)

        var check = ProjectIndexCheck()
        check.environment = env
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("stale"))
    }

    @Test("warn when index is empty")
    func warnWhenEmpty() throws {
        let home = try makeSandboxHome(label: "index-empty")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        // Create empty index file
        let index = ProjectIndex(path: env.projectsIndexFile)
        let data = ProjectIndex.IndexData()
        try index.save(data)

        var check = ProjectIndexCheck()
        check.environment = env
        let result = check.check()
        guard case .warn = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
    }

    @Test("fix prunes stale entries")
    func fixPrunesStaleEntries() throws {
        let home = try makeSandboxHome(label: "index-fix")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        // Create one real directory and one stale path
        let realProject = home.appendingPathComponent("real-project")
        try FileManager.default.createDirectory(at: realProject, withIntermediateDirectories: true)

        let index = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        index.upsert(projectPath: realProject.path, packIDs: ["ios"], in: &data)
        index.upsert(projectPath: "/nonexistent/stale/\(UUID().uuidString)", packIDs: ["web"], in: &data)
        try index.save(data)

        var check = ProjectIndexCheck()
        check.environment = env

        // Verify it fails first
        guard case .fail = check.check() else {
            Issue.record("Expected .fail before fix")
            return
        }

        // Fix should prune the stale entry
        let fixResult = check.fix()
        guard case .fixed = fixResult else {
            Issue.record("Expected .fixed, got \(fixResult)")
            return
        }

        // Verify the index now has only the real project
        let updatedData = try index.load()
        #expect(updatedData.projects.count == 1)
        #expect(updatedData.projects.first?.path == realProject.path)
    }

    @Test("global sentinel paths are never stale")
    func globalSentinelNotStale() throws {
        let home = try makeSandboxHome(label: "index-global")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let index = ProjectIndex(path: env.projectsIndexFile)
        var data = ProjectIndex.IndexData()
        // __global__ sentinel should never be considered stale even though it's not a real path
        index.upsert(projectPath: ProjectIndex.globalSentinel, packIDs: ["core"], in: &data)
        try index.save(data)

        var check = ProjectIndexCheck()
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass (global sentinel should not be stale), got \(result)")
            return
        }
    }
}

// MARK: - DerivedDoctorChecks Sandbox Tests

struct DerivedDoctorCheckSandboxTests {
    private let dummySource = URL(fileURLWithPath: "/tmp/dummy-source")

    @Test("copyPackFile uses injected environment for global URL")
    func copyPackFileUsesInjectedEnv() throws {
        let home = try makeSandboxHome(label: "derived-env")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let component = ComponentDefinition(
            id: "test.skill",
            displayName: "Test Skill",
            description: "A test skill",
            type: .skill,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(source: dummySource, destination: "skill.md", fileType: .skill)
        )

        // Without project root, the derived check should use the environment's skills directory
        let check = component.deriveDoctorCheck(environment: env)
        #expect(check != nil)

        // The check should be a FileExistsCheck with a path inside our sandbox
        if let fileCheck = check as? FileExistsCheck {
            #expect(fileCheck.path.path.hasPrefix(home.path))
        } else {
            Issue.record("Expected FileExistsCheck, got \(type(of: check!))")
        }
    }

    @Test("copyPackFile with project root returns project-scoped path and global fallback")
    func copyPackFileWithProjectRoot() throws {
        let home = try makeSandboxHome(label: "derived-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)
        let projectRoot = home.appendingPathComponent("my-project")

        let component = ComponentDefinition(
            id: "test.hook",
            displayName: "Test Hook",
            description: "A test hook",
            type: .hookFile,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .copyPackFile(source: dummySource, destination: "hook.sh", fileType: .hook)
        )

        let check = component.deriveDoctorCheck(projectRoot: projectRoot, environment: env)
        #expect(check != nil)

        if let fileCheck = check as? FileExistsCheck {
            // Primary path should be under the project root
            #expect(fileCheck.path.path.hasPrefix(projectRoot.path))
            // Fallback path should be under the sandbox home
            #expect(fileCheck.fallbackPath != nil)
            #expect(try #require(fileCheck.fallbackPath?.path.hasPrefix(home.path)))
        } else {
            Issue.record("Expected FileExistsCheck, got \(type(of: check!))")
        }
    }

    @Test("mcpServer check uses injected environment")
    func mcpServerUsesInjectedEnv() throws {
        let home = try makeSandboxHome(label: "derived-mcp")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let component = ComponentDefinition(
            id: "test.mcp",
            displayName: "Test MCP",
            description: "A test MCP server",
            type: .mcpServer,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .mcpServer(MCPServerConfig(name: "test-mcp", command: "npx", args: ["-y", "test"], env: [:]))
        )

        let check = component.deriveDoctorCheck(environment: env)
        #expect(check != nil)

        // The MCPServerCheck should fail because there's no .claude.json in the sandbox
        if let mcpCheck = check as? MCPServerCheck {
            let result = mcpCheck.check()
            guard case .fail = result else {
                Issue.record("Expected .fail (no claude.json in sandbox), got \(result)")
                return
            }
        } else {
            Issue.record("Expected MCPServerCheck, got \(type(of: check!))")
        }
    }

    @Test("allDoctorChecks forwards environment to derived check")
    func allDoctorChecksForwardsEnv() throws {
        let home = try makeSandboxHome(label: "derived-all")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let component = ComponentDefinition(
            id: "test.plugin",
            displayName: "Test Plugin",
            description: "A test plugin",
            type: .plugin,
            packIdentifier: nil,
            dependencies: [],
            isRequired: true,
            installAction: .plugin(name: "my-plugin")
        )

        let checks = component.allDoctorChecks(environment: env)
        #expect(checks.count == 1)

        // The PluginCheck should use our sandbox settings path
        if let pluginCheck = checks.first as? PluginCheck {
            let result = pluginCheck.check()
            // Should fail because settings.json doesn't exist in sandbox
            guard case .fail = result else {
                Issue.record("Expected .fail (no settings in sandbox), got \(result)")
                return
            }
        } else {
            Issue.record("Expected PluginCheck, got \(type(of: checks.first!))")
        }
    }
}
