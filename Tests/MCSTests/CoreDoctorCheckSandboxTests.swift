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

    @Test("warn via global fallback when project settings.local.json is invalid")
    func warnWhenProjectSettingsInvalidFallsBackToGlobal() throws {
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
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json is unreadable"))
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

    @Test("pass via global when plugin explicitly false in project settings")
    func passWhenPluginExplicitlyFalseInProject() throws {
        let home = try makeGlobalTmpDir(label: "plugin-false-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        let projectSettings = """
        { "enabledPlugins": { "my-plugin": false } }
        """
        try projectSettings.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        let globalSettings = """
        { "enabledPlugins": { "my-plugin": true } }
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

    @Test("fail with corrupt message when project settings invalid and no global settings")
    func failWhenProjectCorruptAndNoGlobal() throws {
        let home = try makeGlobalTmpDir(label: "plugin-corrupt-no-global")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        try "not valid json".write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json is corrupt"))
        #expect(msg.contains("settings.json not found"))
    }

    @Test("fail with corrupt message when project settings invalid and plugin not in global")
    func failWhenProjectCorruptAndPluginNotInGlobal() throws {
        let home = try makeGlobalTmpDir(label: "plugin-corrupt-not-global")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        let claudeDir = projectRoot.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        try "not valid json".write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            atomically: true, encoding: .utf8
        )

        let globalSettings = """
        { "enabledPlugins": { "other-plugin": true } }
        """
        try globalSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        let check = PluginCheck(pluginRef: PluginRef("my-plugin"), projectRoot: projectRoot, environment: env)
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg == "not enabled (settings.local.json is corrupt)")
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

// MARK: - Scoped Settings Resolution Helpers

/// Creates `<home>/my-project/.claude/` and writes `settings.local.json` into it.
private func makeProjectSettings(in home: URL, contents: String) throws -> URL {
    let projectRoot = home.appendingPathComponent("my-project")
    let claudeDir = projectRoot.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try contents.write(
        to: claudeDir.appendingPathComponent("settings.local.json"),
        atomically: true, encoding: .utf8
    )
    return projectRoot
}

private func hookSettings(event: String) -> String {
    """
    {
      "hooks": {
        "\(event)": [
          { "hooks": [{ "type": "command", "command": "bash .claude/hooks/run.sh" }] }
        ]
      }
    }
    """
}

// MARK: - ExternalHookEventExistsCheck Project Scope (issue #354)

extension ExternalHookEventExistsCheckSandboxTests {
    @Test("pass from project settings.local.json when global settings.json lacks the event")
    func passFromProjectSettings() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: hookSettings(event: "PostToolUse"))
        try hookSettings(event: "PreToolUse").write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "registered in settings.local.json")
    }

    @Test("pass via global fallback when project settings.local.json lacks the event")
    func passViaGlobalFallback() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: hookSettings(event: "PreToolUse"))
        try hookSettings(event: "PostToolUse").write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "registered in settings.json")
    }

    @Test("pass from project settings when no global settings.json exists")
    func passFromProjectWithoutGlobalFile() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-noglobal")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: hookSettings(event: "SessionStart"))

        var check = ExternalHookEventExistsCheck(
            name: "SessionStart hook", section: "Hooks",
            event: "SessionStart", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg == "registered in settings.local.json")
    }

    @Test("fail when event is absent from both scopes")
    func failWhenAbsentFromBothScopes() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-neither")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: hookSettings(event: "PreToolUse"))
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json"))
        #expect(msg.contains("settings.json"))
    }

    @Test("ignores project settings when no projectRoot is given")
    func ignoresProjectSettingsWithoutProjectRoot() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-noroot")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        _ = try makeProjectSettings(in: home, contents: hookSettings(event: "PostToolUse"))
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        // A globally-configured pack has no project root — the project file must not be consulted.
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

    @Test("warn naming the unreadable project file when the event is found globally")
    func warnWhenProjectSettingsCorruptButFoundGlobally() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-corrupt-fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: "{ not json")
        try hookSettings(event: "PostToolUse").write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("registered in settings.json"))
        #expect(msg.contains("settings.local.json is unreadable"))
    }

    @Test("fail surfaces the corrupt project file when the event is absent everywhere")
    func failSurfacesCorruptProjectSettings() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-corrupt-fail")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: "{ not json")
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json is unreadable"))
    }

    @Test("skip when an optional event is absent from both scopes")
    func skipWhenOptionalAbsentFromBothScopes() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-optional-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: "{}")
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "SessionStart hook", section: "Hooks",
            event: "SessionStart", isOptional: true, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case .skip = result else {
            Issue.record("Expected .skip, got \(result)")
            return
        }
    }

    @Test("fail names both candidates when neither settings file exists")
    func failWhenNoSettingsFileAnywhere() throws {
        let home = try makeGlobalTmpDir(label: "hook-event-nofiles")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = home.appendingPathComponent("my-project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        var check = ExternalHookEventExistsCheck(
            name: "PostToolUse hook", section: "Hooks",
            event: "PostToolUse", isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .fail(msg) = result else {
            Issue.record("Expected .fail, got \(result)")
            return
        }
        #expect(msg.contains("no settings file found"))
        #expect(msg.contains("settings.local.json, settings.json"))
    }
}

// MARK: - ExternalSettingsKeyEqualsCheck Project Scope (issue #354)

extension ExternalSettingsKeyEqualsCheckSandboxTests {
    @Test("project value takes precedence over a differing global value")
    func projectValueOverridesGlobal() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-override")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(
            in: home, contents: #"{ "permissions": { "defaultMode": "deny" } }"#
        )
        try #"{ "permissions": { "defaultMode": "allowEdits" } }"#
            .write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits",
            projectRoot: projectRoot
        )
        check.environment = env
        // Claude Code applies the project value, so the check must report on that one.
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("'deny' in settings.local.json"))
    }

    @Test("pass from project settings.local.json")
    func passFromProjectSettings() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-project")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(
            in: home, contents: #"{ "permissions": { "defaultMode": "allowEdits" } }"#
        )

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits",
            projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json"))
    }

    @Test("pass via global fallback when the key is absent from project settings")
    func passViaGlobalFallback() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: #"{ "env": { "FOO": "bar" } }"#)
        try #"{ "permissions": { "defaultMode": "allowEdits" } }"#
            .write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits",
            projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .pass(msg) = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
        #expect(msg.contains("(settings.json)"))
    }

    @Test("warn surfaces a corrupt project settings file instead of discarding it")
    func warnSurfacesCorruptProjectSettings() throws {
        let home = try makeGlobalTmpDir(label: "settings-key-corrupt")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectRoot = try makeProjectSettings(in: home, contents: "{ not json")
        try "{}".write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalSettingsKeyEqualsCheck(
            name: "Default mode", section: "Settings",
            keyPath: "permissions.defaultMode", expectedValue: "allowEdits",
            projectRoot: projectRoot
        )
        check.environment = env
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json is unreadable"))
    }
}

// MARK: - ExternalHookEventExistsCheck Matcher / Command Assertions (issue #355)

extension ExternalHookEventExistsCheckSandboxTests {
    /// Two groups under PreToolUse: one matching `Agent|Task` running the gate, one matching
    /// `Bash` running something else. Enough shape to tell "same group" from "any group".
    private static let twoGroupSettings = """
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Agent|Task",
            "hooks": [{ "type": "command", "command": "bash .claude/hooks/kb-gate.sh" }]
          },
          {
            "matcher": "Bash",
            "hooks": [{ "type": "command", "command": "bash .claude/hooks/audit.sh" }]
          }
        ]
      }
    }
    """

    private func makeCheck(
        in home: URL,
        settings: String,
        matcher: String? = nil,
        command: String? = nil,
        isOptional: Bool = false
    ) throws -> ExternalHookEventExistsCheck {
        let env = Environment(home: home)
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)
        var check = ExternalHookEventExistsCheck(
            name: "PreToolUse hook", section: "Hooks",
            event: "PreToolUse", matcher: matcher, commandSubstring: command,
            isOptional: isOptional
        )
        check.environment = env
        return check
    }

    @Test("pass when the declared matcher is registered")
    func passWhenMatcherMatches() throws {
        let home = try makeGlobalTmpDir(label: "hook-matcher-pass")
        defer { try? FileManager.default.removeItem(at: home) }

        let check = try makeCheck(in: home, settings: Self.twoGroupSettings, matcher: "Agent|Task")
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("warn when the event is registered but the matcher differs")
    func warnWhenMatcherDiffers() throws {
        let home = try makeGlobalTmpDir(label: "hook-matcher-differs")
        defer { try? FileManager.default.removeItem(at: home) }

        // The motivating shape: settings carry `Agent|Task`, the check declares only `Task`.
        let check = try makeCheck(in: home, settings: Self.twoGroupSettings, matcher: "Task")
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        // Both the expected and the actual matchers must be named, or the reader cannot tell a
        // mismatch from an absent registration.
        #expect(msg.contains("'Task'"))
        #expect(msg.contains("'Agent|Task'"))
        #expect(msg.contains("'Bash'"))
    }

    @Test("warn when the matcher matches but the command substring is absent")
    func warnWhenCommandAbsent() throws {
        let home = try makeGlobalTmpDir(label: "hook-command-absent")
        defer { try? FileManager.default.removeItem(at: home) }

        let check = try makeCheck(
            in: home, settings: Self.twoGroupSettings,
            matcher: "Agent|Task", command: "missing.sh"
        )
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("missing.sh"))
    }

    @Test("warn when matcher and command are satisfied by different groups")
    func warnWhenSatisfiedByDifferentGroups() throws {
        let home = try makeGlobalTmpDir(label: "hook-different-groups")
        defer { try? FileManager.default.removeItem(at: home) }

        // `Agent|Task` exists and `audit.sh` exists, but not together — the pair must be proven by
        // one group or it proves nothing about which registration belongs to the pack.
        let check = try makeCheck(
            in: home, settings: Self.twoGroupSettings,
            matcher: "Agent|Task", command: "audit.sh"
        )
        let result = check.check()
        guard case .warn = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
    }

    @Test("pass on command substring alone, matched in any group")
    func passWhenCommandOnlyMatches() throws {
        let home = try makeGlobalTmpDir(label: "hook-command-only")
        defer { try? FileManager.default.removeItem(at: home) }

        let check = try makeCheck(in: home, settings: Self.twoGroupSettings, command: "audit.sh")
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("pass on event presence alone when neither field is declared")
    func passWhenNoAssertionsDeclared() throws {
        let home = try makeGlobalTmpDir(label: "hook-no-assertions")
        defer { try? FileManager.default.removeItem(at: home) }

        let check = try makeCheck(in: home, settings: Self.twoGroupSettings)
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("empty matcher in settings satisfies an undeclared matcher")
    func emptyMatcherNormalizesToAbsent() throws {
        let home = try makeGlobalTmpDir(label: "hook-empty-matcher")
        defer { try? FileManager.default.removeItem(at: home) }

        let settings = """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "", "hooks": [{ "type": "command", "command": "bash run.sh" }] }
            ]
          }
        }
        """
        // A written "" and an absent key select the same tools, so this must not read as drift.
        let check = try makeCheck(in: home, settings: settings, command: "run.sh")
        let result = check.check()
        guard case .pass = result else {
            Issue.record("Expected .pass, got \(result)")
            return
        }
    }

    @Test("skip when optional and the matcher differs")
    func skipWhenOptionalMismatch() throws {
        let home = try makeGlobalTmpDir(label: "hook-optional-mismatch")
        defer { try? FileManager.default.removeItem(at: home) }

        let check = try makeCheck(
            in: home, settings: Self.twoGroupSettings,
            matcher: "Task", isOptional: true
        )
        let result = check.check()
        guard case .skip = result else {
            Issue.record("Expected .skip, got \(result)")
            return
        }
    }

    @Test("a mismatched project registration is not rescued by a correct global one")
    func projectMismatchWinsOverGlobal() throws {
        let home = try makeGlobalTmpDir(label: "hook-project-mismatch")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let projectSettings = """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Task", "hooks": [{ "type": "command", "command": "bash gate.sh" }] }
            ]
          }
        }
        """
        let projectRoot = try makeProjectSettings(in: home, contents: projectSettings)
        try Self.twoGroupSettings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)

        var check = ExternalHookEventExistsCheck(
            name: "PreToolUse hook", section: "Hooks",
            event: "PreToolUse", matcher: "Agent|Task",
            isOptional: false, projectRoot: projectRoot
        )
        check.environment = env
        // settings.local.json takes precedence and is what Claude Code will actually run, so its
        // wrong matcher must be reported rather than masked by the correct global file.
        let result = check.check()
        guard case let .warn(msg) = result else {
            Issue.record("Expected .warn, got \(result)")
            return
        }
        #expect(msg.contains("settings.local.json"))
    }
}
