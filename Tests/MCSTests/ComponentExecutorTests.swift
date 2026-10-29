import Foundation
@testable import mcs
import Testing

struct ComponentExecutorTests {
    private func makeExecutor() -> ComponentExecutor {
        let env = Environment()
        return ComponentExecutor(
            environment: env,
            output: CLIOutput(),
            shell: ShellRunner(environment: env),
            claudeCLI: ClaudeIntegration(shell: ShellRunner(environment: env))
        )
    }

    // MARK: - removePlugin

    private let userCopy = InstalledPlugin(id: "lint@acme", scope: "user", enabled: true, projectPath: nil)

    private func removePlugin(
        returning result: ShellResult,
        scope: String = Constants.PluginScope.user,
        installed: [InstalledPlugin] = []
    ) -> Bool {
        let cli = MockClaudeCLI()
        cli.result = result
        cli.installedPlugins = installed
        return makeExecutor(cli).removePlugin("lint@acme", scope: scope)
    }

    @Test("removePlugin counts a plugin that is already uninstalled as removed")
    func removePluginAlreadyGone() {
        let stderr = "✘ Failed to uninstall plugin \"lint\": Plugin \"lint\" not found in installed plugins"
        #expect(removePlugin(returning: ShellResult(exitCode: 1, stdout: "", stderr: stderr)))
    }

    @Test("removePlugin counts a plugin left only at another scope as removed from this one")
    func removePluginOnlyAtOtherScope() {
        let stderr = "✘ Failed to uninstall plugin \"lint@acme\": Plugin \"lint@acme\" is installed in user scope, not local."
        #expect(removePlugin(
            returning: ShellResult(exitCode: 1, stdout: "", stderr: stderr), scope: Constants.PluginScope.local, installed: [userCopy]
        ))
    }

    @Test("removePlugin reports a failure that leaves the plugin installed at this scope")
    func removePluginRealFailure() {
        #expect(!removePlugin(returning: ShellResult(exitCode: 1, stdout: "", stderr: "network unreachable"), installed: [userCopy]))
    }

    // MARK: - installProjectFile placeholder substitution

    @Test("installProjectFile substitutes PROJECT_DIR_NAME and REPO_NAME placeholders")
    func projectDirNameSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let packDir = tmpDir.appendingPathComponent("pack/my-skill")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try "Dir: __PROJECT_DIR_NAME__, Repo: __REPO_NAME__".write(
            to: packDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: packDir,
            destination: "my-skill",
            fileType: .skill,
            projectPath: projectPath,
            resolvedValues: ["PROJECT_DIR_NAME": "my-folder", "REPO_NAME": "my-app"]
        )

        #expect(!result.paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/skills/my-skill/SKILL.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("Dir: my-folder"))
        #expect(content.contains("Repo: my-app"))
        #expect(!content.contains("__PROJECT_DIR_NAME__"))
        #expect(!content.contains("__REPO_NAME__"))
    }

    @Test("installProjectFile with agent fileType installs to .claude/agents/")
    func installProjectFileAgentType() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let agentFile = tmpDir.appendingPathComponent("code-reviewer.md")
        try "---\nname: Code Reviewer\n---\nReview code".write(
            to: agentFile,
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: agentFile,
            destination: "code-reviewer.md",
            fileType: .agent,
            projectPath: projectPath,
            resolvedValues: [:]
        )

        #expect(!result.paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/agents/code-reviewer.md")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("Code Reviewer"))
    }

    // MARK: - installProjectFile hash recording

    @Test("installProjectFile returns SHA-256 hashes of installed files")
    func installProjectFileRecordsHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let source = tmpDir.appendingPathComponent("test-hook.sh")
        try "#!/bin/bash\necho test".write(to: source, atomically: true, encoding: .utf8)

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: source,
            destination: "test-hook.sh",
            fileType: .hook,
            projectPath: projectPath
        )

        #expect(result.paths.count == 1)
        #expect(result.hashes.count == 1)

        let installed = projectPath.appendingPathComponent(".claude/hooks/test-hook.sh")
        let expectedHash = try FileHasher.sha256(of: installed)
        #expect(result.hashes.values.first == expectedHash)
    }

    // MARK: - installPlugin

    private func makeExecutor(_ cli: MockClaudeCLI, project: URL? = nil) -> ComponentExecutor {
        let env = Environment()
        return ComponentExecutor(
            environment: env,
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false),
            shell: ShellRunner(environment: env),
            claudeCLI: cli,
            mcpWorkingDirectory: project
        )
    }

    @Test("installPlugin registers a repo marketplace and installs by its resolved id")
    func installPluginResolvesRepoMarketplace() {
        let cli = MockClaudeCLI()
        cli.marketplaces = [PluginMarketplace(name: "hud", repo: "org/hud-repo")]
        let project = URL(fileURLWithPath: "/tmp/mcs-exec-project")

        let outcome = makeExecutor(cli, project: project).installPlugin("lint@org/hud-repo", scope: Constants.PluginScope.local)

        #expect(outcome == .installed(id: "lint@hud", userScopeCopy: false))
        #expect(cli.marketplaceAddCalls == ["org/hud-repo"])
        #expect(cli.pluginInstallCalls == [MockClaudeCLI.PluginCall(id: "lint@hud", scope: "local", workingDirectory: project)])
    }

    // MARK: - installPlugin auto-update

    private func installWithSettings(
        _ settingsJSON: String, cli: MockClaudeCLI
    ) throws -> (home: URL, autoUpdate: Any?) {
        let home = try makeTmpDir(label: "autoupdate")
        let env = Environment(home: home)
        try FileManager.default.createDirectory(at: env.claudeDirectory, withIntermediateDirectories: true)
        try settingsJSON.write(to: env.claudeSettings, atomically: true, encoding: .utf8)
        let executor = ComponentExecutor(
            environment: env,
            output: CLIOutput(colorsEnabled: false, interactiveStdin: false),
            shell: ShellRunner(environment: env),
            claudeCLI: cli
        )
        _ = executor.installPlugin("lint@org/hud-repo", scope: Constants.PluginScope.user)
        let json = try Settings.load(from: env.claudeSettings).extraJSONObject
        let entry = (json[Constants.JSONKeys.extraKnownMarketplaces] as? [String: Any])?["hud"] as? [String: Any]
        return (home, entry?[Constants.JSONKeys.autoUpdate])
    }

    private let hudEntry = #"{"extraKnownMarketplaces":{"hud":{"source":{"source":"github","repo":"org/hud-repo"}}}}"#

    @Test("installPlugin turns on auto-update for a marketplace its own add registered")
    func installPluginEnablesAutoUpdateOnNewMarketplace() throws {
        let cli = MockClaudeCLI()
        cli.marketplacesRegisteredOnAdd = ["org/hud-repo": PluginMarketplace(name: "hud", repo: "org/hud-repo")]
        let (home, autoUpdate) = try installWithSettings(hudEntry, cli: cli)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(autoUpdate as? Bool == true)
    }

    @Test("installPlugin leaves auto-update alone on a marketplace that was already registered")
    func installPluginKeepsPreexistingMarketplace() throws {
        let cli = MockClaudeCLI()
        cli.marketplaces = [PluginMarketplace(name: "hud", repo: "org/hud-repo")]
        let (home, autoUpdate) = try installWithSettings(hudEntry, cli: cli)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(autoUpdate == nil)
    }

    @Test("installPlugin never overrides an auto-update choice already in settings")
    func installPluginKeepsExplicitAutoUpdate() throws {
        let cli = MockClaudeCLI()
        cli.marketplacesRegisteredOnAdd = ["org/hud-repo": PluginMarketplace(name: "hud", repo: "org/hud-repo")]
        let settings = #"{"extraKnownMarketplaces":{"hud":{"autoUpdate":false,"source":{"source":"github","repo":"org/hud-repo"}}}}"#
        let (home, autoUpdate) = try installWithSettings(settings, cli: cli)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(autoUpdate as? Bool == false)
    }

    @Test("installPlugin links a pack-hosted plugin through the pack's marketplace, without auto-update")
    func installPluginPackHosted() throws {
        let home = try makeTmpDir(label: "pack-hosted")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)
        let source = home.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // The entry `marketplace add` writes: without it, auto-update could never be set either way.
        try FileManager.default.createDirectory(at: env.claudeDirectory, withIntermediateDirectories: true)
        let settings = #"{"extraKnownMarketplaces":{"mcs-xcrew":{"source":{"source":"directory","path":"/x"}}}}"#
        try settings.write(to: env.claudeSettings, atomically: true, encoding: .utf8)
        let cli = MockClaudeCLI()
        let executor = ComponentExecutor(
            environment: env, output: CLIOutput(colorsEnabled: false, interactiveStdin: false),
            shell: ShellRunner(environment: env), claudeCLI: cli
        )

        let outcome = executor.installPlugin("demo@mcs-xcrew", scope: Constants.PluginScope.user, hostedSource: source)

        #expect(outcome == .installed(id: "demo@mcs-xcrew", userScopeCopy: false))
        #expect(cli.marketplaceAddCalls == [PackMarketplace.wrapperDirectory(packID: "xcrew", environment: env).path])
        #expect(try String(contentsOf: env.claudeSettings, encoding: .utf8) == settings)
    }

    @Test("installPlugin refuses a pack-hosted plugin with no directory in its pack")
    func installPluginPackHostedWithoutSource() {
        let cli = MockClaudeCLI()
        #expect(makeExecutor(cli).installPlugin("demo@mcs-xcrew", scope: Constants.PluginScope.user) == .failed)
        #expect(cli.pluginInstallCalls.isEmpty)
    }

    @Test("installPlugin skips a plugin whose marketplace can't be found")
    func installPluginUnresolvableMarketplace() {
        let cli = MockClaudeCLI()
        let outcome = makeExecutor(cli).installPlugin("lint@org/unknown", scope: Constants.PluginScope.user)
        #expect(outcome == .failed)
        #expect(cli.pluginInstallCalls.isEmpty)
    }

    @Test("installPlugin takes no ownership of an install already at the target scope")
    func installPluginAlreadyInstalled() {
        let cli = MockClaudeCLI()
        cli.installedPlugins = [InstalledPlugin(id: "lint@acme", scope: "user", enabled: true, projectPath: nil)]
        let outcome = makeExecutor(cli).installPlugin("lint@acme", scope: Constants.PluginScope.user)
        #expect(outcome == .alreadyInstalled(id: "lint@acme"))
        #expect(cli.pluginInstallCalls.isEmpty)
    }

    @Test("installPlugin reports a user-scope copy when installing locally")
    func installPluginFlagsUserScopeCopy() {
        let cli = MockClaudeCLI()
        cli.installedPlugins = [InstalledPlugin(id: "lint@acme", scope: "user", enabled: true, projectPath: nil)]
        let project = URL(fileURLWithPath: "/tmp/mcs-exec-project")
        let outcome = makeExecutor(cli, project: project).installPlugin("lint@acme", scope: Constants.PluginScope.local)
        #expect(outcome == .installed(id: "lint@acme", userScopeCopy: true))
    }

    @Test("installPlugin claims nothing when it couldn't see what was installed before")
    func installPluginUnlistedIsUnowned() {
        let cli = MockClaudeCLI()
        cli.pluginListFails = true
        let outcome = makeExecutor(cli).installPlugin("lint@acme", scope: Constants.PluginScope.user)
        #expect(outcome == .installedUnowned(id: "lint@acme"))
        #expect(cli.pluginInstallCalls.count == 1)
    }
}
