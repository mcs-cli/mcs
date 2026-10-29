import Foundation
@testable import mcs
import Testing

struct PluginRefresherTests {
    private func makeProject(recording plugins: [String]) throws -> (root: URL, scope: SyncScope) {
        let root = try makeTmpDir(label: "refresher")
        var state = try ProjectState(projectRoot: root)
        state.recordPack("pack")
        var record = PackArtifactRecord()
        record.plugins = plugins
        state.setArtifacts(record, for: "pack")
        try state.save()
        return (root, SyncScope.project(at: root, environment: Environment(home: root)))
    }

    private func refresher(_ cli: MockClaudeCLI) -> PluginRefresher {
        PluginRefresher(claudeCLI: cli, output: CLIOutput(colorsEnabled: false, interactiveStdin: false))
    }

    @Test("refresh updates each recorded plugin at its scope and reports the version change")
    func refreshUpdatesRecordedPlugins() throws {
        let (root, scope) = try makeProject(recording: ["lint@acme"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = MockClaudeCLI()
        cli.installedPlugins = [InstalledPlugin(
            id: "lint@acme", scope: "local", enabled: true, projectPath: root.path, version: "1.0.0"
        )]
        cli.latestPluginVersions = ["lint@acme": "1.1.0"]

        let changes = refresher(cli).refresh(scopes: [scope], dryRun: false)

        #expect(cli.marketplaceUpdateCalls == ["acme"])
        #expect(cli.pluginUpdateCalls == [MockClaudeCLI.PluginCall(id: "lint@acme", scope: "local", workingDirectory: root)])
        #expect(changes == [PluginRefresher.Change(scopeLabel: scope.label, id: "lint@acme", from: "1.0.0", to: "1.1.0")])
    }

    @Test("refresh leaves plugins mcs did not record untouched")
    func refreshSkipsUnrecordedPlugins() throws {
        let (root, scope) = try makeProject(recording: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = MockClaudeCLI()
        cli.installedPlugins = [InstalledPlugin(id: "lint@acme", scope: "local", enabled: true, projectPath: root.path)]

        refresher(cli).refresh(scopes: [scope], dryRun: false)

        #expect(cli.marketplaceUpdateCalls.isEmpty)
        #expect(cli.pluginUpdateCalls.isEmpty)
    }

    @Test("refresh resolves a repo reference through the marketplace list")
    func refreshResolvesRepoReference() throws {
        let (root, scope) = try makeProject(recording: ["lint@org/hud-repo"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = MockClaudeCLI()
        cli.marketplaces = [PluginMarketplace(name: "hud", repo: "org/hud-repo")]

        refresher(cli).refresh(scopes: [scope], dryRun: false)

        #expect(cli.pluginUpdateCalls.map(\.id) == ["lint@hud"])
    }

    @Test("refresh refreshes a marketplace shared by two scopes once")
    func refreshDedupesMarketplaces() throws {
        let (first, firstScope) = try makeProject(recording: ["lint@acme"])
        let (second, secondScope) = try makeProject(recording: ["fmt@acme"])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let cli = MockClaudeCLI()

        refresher(cli).refresh(scopes: [firstScope, secondScope], dryRun: false)

        #expect(cli.marketplaceUpdateCalls == ["acme"])
        #expect(cli.pluginUpdateCalls.map(\.id) == ["lint@acme", "fmt@acme"])
    }

    @Test("refresh on a dry run changes nothing")
    func refreshDryRun() throws {
        let (root, scope) = try makeProject(recording: ["lint@acme"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = MockClaudeCLI()

        refresher(cli).refresh(scopes: [scope], dryRun: true)

        #expect(cli.marketplaceUpdateCalls.isEmpty)
        #expect(cli.pluginUpdateCalls.isEmpty)
    }

    @Test("refresh reports no version change when the listing before the update fails")
    func refreshIgnoresFailedListing() throws {
        let (root, scope) = try makeProject(recording: ["lint@acme"])
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = MockClaudeCLI()
        cli.installedPlugins = [InstalledPlugin(
            id: "lint@acme", scope: "local", enabled: true, projectPath: root.path, version: "1.0.0"
        )]
        cli.pluginListFailuresRemaining = 1

        let changes = refresher(cli).refresh(scopes: [scope], dryRun: false)

        #expect(cli.pluginUpdateCalls.map(\.id) == ["lint@acme"])
        #expect(changes.isEmpty)
    }
}
