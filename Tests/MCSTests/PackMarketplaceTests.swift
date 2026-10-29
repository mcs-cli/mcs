import Foundation
@testable import mcs
import Testing

struct PackMarketplaceTests {
    private func manifest(_ plugin: ExternalInstallAction) -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1, identifier: "test", displayName: "Test", description: "Test",
            author: nil, minMCSVersion: nil,
            components: [ExternalComponentDefinition(
                id: "test.plugin", displayName: "Plugin", description: "Plugin", type: .plugin, installAction: plugin
            )],
            templates: nil, prompts: nil, configureProject: nil, supplementaryDoctorChecks: nil, ignore: nil
        )
    }

    private func resolve(_ source: String?, in pack: URL) throws -> PackMarketplace.HostedPlugin? {
        try PackMarketplace.hostedPlugin(named: "demo", in: manifest(.plugin(name: "demo@pack", source: source)), packPath: pack)
    }

    @Test("Without a pluginSource the plugin is the pack root")
    func rootSource() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        try writePluginManifest(at: pack, name: "demo")
        #expect(try resolve(nil, in: pack) == PackMarketplace.HostedPlugin(name: "demo", source: pack, relativePath: "."))
    }

    @Test("A pluginSource resolves inside the pack")
    func subdirectorySource() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        try writePluginManifest(at: pack.appendingPathComponent("plugins/demo"), name: "demo")
        let plugin = try #require(try resolve("plugins/demo", in: pack))
        #expect(plugin.relativePath == "plugins/demo")
        #expect(plugin.source.resolvingSymlinksInPath().path
            == pack.appendingPathComponent("plugins/demo").resolvingSymlinksInPath().path)
    }

    @Test("The pack's own marketplace.json is never read, even when it points the plugin at GitHub")
    func ignoresPackMarketplace() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        try writePluginManifest(at: pack, name: "demo")
        try #"{"name":"acme","plugins":[{"name":"demo","source":{"source":"github","repo":"acme/demo","ref":"stable"}}]}"#
            .write(to: pack.appendingPathComponent(PackMarketplace.manifestPath), atomically: true, encoding: .utf8)
        #expect(try resolve(nil, in: pack)?.relativePath == ".")
    }

    @Test("A missing directory, a missing or unreadable plugin.json, and a name mismatch are rejected")
    func rejectedDirectories() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        #expect(throws: PackMarketplace.Error.sourceMissing("demo")) { try resolve("plugins/fooo", in: pack) }
        #expect(throws: PackMarketplace.Error.pluginManifestMissing(name: "demo", path: ".claude-plugin/plugin.json")) {
            try resolve(nil, in: pack)
        }

        try writePluginManifest(at: pack, name: "other")
        #expect(throws: PackMarketplace.Error.pluginNameMismatch(name: "demo", declared: "other")) { try resolve(nil, in: pack) }

        try #"["demo"]"#.write(to: pack.appendingPathComponent(PackMarketplace.pluginManifestPath), atomically: true, encoding: .utf8)
        #expect(throws: PackMarketplace.Error.pluginManifestUnreadable(name: "demo", reason: "expected an object with a `name` string")) {
            try resolve(nil, in: pack)
        }
    }

    @Test("A plugin the manifest doesn't host resolves to nothing")
    func notHosted() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        #expect(try PackMarketplace.hostedPlugin(named: "demo", in: manifest(.plugin(name: "demo@acme/demo")), packPath: pack) == nil)
    }

    @Test("Linking writes a marketplace named for the pack that lists the linked plugin")
    func linkWritesWrapper() throws {
        let home = try makeTmpDir(label: "pack-marketplace-home")
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }
        let env = Environment(home: home)

        let wrapper = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)

        let data = try Data(contentsOf: wrapper.appendingPathComponent(".claude-plugin/marketplace.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["name"] as? String == "mcs-xcrew")
        let plugins = try #require(manifest["plugins"] as? [[String: String]])
        #expect(plugins == [["name": "demo", "source": "./plugins/demo"]])
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: wrapper.appendingPathComponent("plugins/demo").path)
        #expect(target == pack.path)
    }

    @Test("Unlinking drops the plugin from the marketplace without removing the marketplace")
    func unlink() throws {
        let home = try makeTmpDir(label: "pack-marketplace-home")
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }
        let env = Environment(home: home)
        _ = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)

        try PackMarketplace.unlink(pluginName: "demo", packID: "xcrew", environment: env)

        #expect(try PackMarketplace.linkedPlugins(packID: "xcrew", environment: env).isEmpty)
        let manifestURL = PackMarketplace.wrapperDirectory(packID: "xcrew", environment: env)
            .appendingPathComponent(PackMarketplace.manifestPath)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        #expect((manifest["plugins"] as? [Any])?.isEmpty == true)
    }
}
