import Foundation
@testable import mcs
import Testing

// MARK: - MCPServerCheck Sandbox Tests

struct MCPServerCheckSandboxTests {
    @Test("pass when server exists in global mcpServers")
    func passGlobalServer() throws {
        let home = try makeGlobalTmpDir(label: "mcp-global")
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
        let home = try makeGlobalTmpDir(label: "mcp-project")
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
        let home = try makeGlobalTmpDir(label: "mcp-missing")
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
        let home = try makeGlobalTmpDir(label: "mcp-nofile")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let check = MCPServerCheck(name: "Test", serverName: "test-server", environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fail when claude.json contains invalid JSON")
    func failInvalidJSON() throws {
        let home = try makeGlobalTmpDir(label: "mcp-invalid")
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

    @Test("pass when subdirectory project root walks up to find server at git root")
    func passWalkUpToGitRoot() throws {
        let home = try makeGlobalTmpDir(label: "mcp-walkup")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let gitRoot = home.appendingPathComponent("my-project")
        let subProject = gitRoot.appendingPathComponent("packages/lib")
        try FileManager.default.createDirectory(
            at: gitRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: subProject, withIntermediateDirectories: true)

        let claudeJSON: [String: Any] = [
            "projects": [
                gitRoot.path: [
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
            projectRoot: subProject, environment: env
        )
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass (walk-up), got \(result)")
            return
        }
    }

    @Test("walk-up stops at .git boundary and does not escape repo")
    func walkUpStopsAtGitBoundary() throws {
        let home = try makeGlobalTmpDir(label: "mcp-boundary")
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

        let claudeJSON: [String: Any] = [
            "projects": [
                outerRepo.path: [
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
            projectRoot: innerRepo, environment: env
        )
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail (should not escape git boundary), got \(result)")
            return
        }
    }

    @Test("pass when projectRoot equals gitRoot (regression)")
    func passExactMatchRegression() throws {
        let home = try makeGlobalTmpDir(label: "mcp-exact")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

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
            Issue.record("Expected .pass (exact match regression), got \(result)")
            return
        }
    }
}

// MARK: - PluginCheck Sandbox Tests

struct PluginCheckSandboxTests {
    @Test("pass when plugin is enabled in settings.json")
    func passWhenEnabled() throws {
        let home = try makeGlobalTmpDir(label: "plugin-pass")
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

        let check = PluginCheck(pluginRef: PluginRef("pr-review-toolkit"), environment: env)
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when plugin is not in enabledPlugins")
    func failWhenNotEnabled() throws {
        let home = try makeGlobalTmpDir(label: "plugin-fail")
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

        let check = PluginCheck(pluginRef: PluginRef("missing-plugin"), environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("fail when settings.json does not exist")
    func failWhenNoSettings() throws {
        let home = try makeGlobalTmpDir(label: "plugin-nosettings")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)
        // Don't create settings.json

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    // MARK: - Project-scoped tests

    @Test("pass when plugin is enabled in project settings.local.json")
    func passWhenEnabledInProjectSettings() throws {
        let home = try makeGlobalTmpDir(label: "plugin-project-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let projectSettings = """
        {
          "enabledPlugins": {
            "my-plugin": true
          }
        }
        """
        try projectSettings.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )
        // No global settings.json

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "enabled (project)")
    }

    @Test("pass via global fallback when plugin not in project settings")
    func passWhenEnabledGloballyButNotInProject() throws {
        let home = try makeGlobalTmpDir(label: "plugin-global-fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Project settings without the target plugin
        let projectSettings = """
        {
          "enabledPlugins": {
            "other-plugin": true
          }
        }
        """
        try projectSettings.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        // Global settings with the target plugin
        let globalSettings = """
        {
          "enabledPlugins": {
            "my-plugin": true
          }
        }
        """
        try globalSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "enabled")
    }

    @Test("fail when plugin not enabled in either scope")
    func failWhenNotEnabledInEitherScope() throws {
        let home = try makeGlobalTmpDir(label: "plugin-both-fail")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let projectSettings = """
        { "enabledPlugins": { "other-plugin": true } }
        """
        try projectSettings.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        let globalSettings = """
        { "enabledPlugins": { "another-plugin": true } }
        """
        try globalSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("pass via global fallback when project settings.local.json is invalid")
    func passWhenProjectSettingsInvalidFallsBackToGlobal() throws {
        let home = try makeGlobalTmpDir(label: "plugin-invalid-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Invalid project settings
        try "not valid json".write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        // Valid global settings
        let globalSettings = """
        {
          "enabledPlugins": {
            "my-plugin": true
          }
        }
        """
        try globalSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "enabled")
    }

    @Test("pass via global when projectRoot set but no settings.local.json exists")
    func passWhenProjectSettingsAbsentFallsBackToGlobal() throws {
        let home = try makeGlobalTmpDir(label: "plugin-no-project-settings")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let globalSettings = """
        {
          "enabledPlugins": {
            "my-plugin": true
          }
        }
        """
        try globalSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "enabled")
    }
}

// MARK: - HookCheck Sandbox Tests

struct HookCheckSandboxTests {
    @Test("pass when hook file exists and is executable")
    func passWhenExecutable() throws {
        let home = try makeGlobalTmpDir(label: "hook-pass")
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
        let home = try makeGlobalTmpDir(label: "hook-missing")
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
        let home = try makeGlobalTmpDir(label: "hook-optional")
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
        let home = try makeGlobalTmpDir(label: "hook-noexec")
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
        let home = try makeGlobalTmpDir(label: "hook-fix")
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
        let home = try makeGlobalTmpDir(label: "hook-fix-missing")
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
        let home = try makeGlobalTmpDir(label: "index-pass")
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
        let home = try makeGlobalTmpDir(label: "index-stale")
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
        let home = try makeGlobalTmpDir(label: "index-empty")
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
        let home = try makeGlobalTmpDir(label: "index-fix")
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
        let home = try makeGlobalTmpDir(label: "index-global")
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
        let home = try makeGlobalTmpDir(label: "derived-env")
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
        let home = try makeGlobalTmpDir(label: "derived-project")
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
            let fallback = try #require(fileCheck.fallbackPath)
            #expect(fallback.path.hasPrefix(home.path))
        } else {
            Issue.record("Expected FileExistsCheck, got \(type(of: check!))")
        }
    }

    @Test("mcpServer check uses injected environment")
    func mcpServerUsesInjectedEnv() throws {
        let home = try makeGlobalTmpDir(label: "derived-mcp")
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
        let home = try makeGlobalTmpDir(label: "derived-all")
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

// MARK: - PluginCheck Invalid JSON

extension PluginCheckSandboxTests {
    @Test("fail when settings.json contains invalid JSON")
    func failWhenInvalidSettings() throws {
        let home = try makeGlobalTmpDir(label: "plugin-invalid")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        try "not valid json".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), environment: env)
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("invalid"))
    }
}

// MARK: - ExternalHookEventExistsCheck Sandbox Tests

struct ExternalHookEventExistsCheckSandboxTests {
    @Test("pass when hook event is registered in settings")
    func passWhenRegistered() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        {
          "hooks": {
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/lint.sh" }] }
            ]
          }
        }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false
        )
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("fail when hook event is not registered")
    func failWhenNotRegistered() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-fail")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/guard.sh" }] }
            ]
          }
        }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false
        )
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }

    @Test("skip when optional hook event is not registered")
    func skipWhenOptionalNotRegistered() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-skip")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "SessionStart hook", section: "Hooks",
            event: "SessionStart", isOptional: true
        )
        check.environment = env
        let result = check.check()
        guard case .skip = result else {
            Issue.record("Expected .skip, got \(result)")
            return
        }
    }

    @Test("fail when settings.json does not exist")
    func failWhenNoSettings() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-nosettings")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false
        )
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }
}

// MARK: - ExternalSettingsKeyEqualsCheck Sandbox Tests

struct ExternalSettingsKeyEqualsCheckSandboxTests {
    @Test("pass when key matches expected value")
    func passWhenMatches() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-pass")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        { "permissions": { "defaultMode": "allowEdits" } }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits"
        )
        check.environment = env
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("warn when key value differs from expected")
    func warnWhenDiffers() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-warn")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let settings = """
        { "permissions": { "defaultMode": "deny" } }
        """
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits"
        )
        check.environment = env
        let result = check.check()
        guard case .warn = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
    }

    @Test("warn when key is absent")
    func warnWhenAbsent() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-absent")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits"
        )
        check.environment = env
        let result = check.check()
        guard case .warn = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
    }

    @Test("fail when settings.json does not exist")
    func failWhenNoSettings() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-nosettings")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits"
        )
        check.environment = env
        let result = check.check()
        guard case .fail = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
    }
}
