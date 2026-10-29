import Foundation
@testable import mcs
import Testing

struct PackMarketplaceTests {
    private func makePack(source: Any) throws -> URL {
        let pack = try makeTmpDir(label: "pack-marketplace")
        try writePackMarketplace(at: pack, plugins: ["demo": source])
        return pack
    }

    @Test("A root source resolves to the pack itself")
    func rootSource() throws {
        let pack = try makePack(source: "./")
        defer { try? FileManager.default.removeItem(at: pack) }
        #expect(try PackMarketplace.hostedPlugin(named: "demo", in: pack)
            == PackMarketplace.HostedPlugin(name: "demo", source: pack, relativePath: "."))
    }

    @Test("A subdirectory source resolves inside the pack")
    func subdirectorySource() throws {
        let pack = try makePack(source: "./plugin")
        defer { try? FileManager.default.removeItem(at: pack) }
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("plugin"), withIntermediateDirectories: true)
        let plugin = try PackMarketplace.hostedPlugin(named: "demo", in: pack)
        #expect(plugin.relativePath == "plugin")
        #expect(plugin.source.resolvingSymlinksInPath().path == pack.appendingPathComponent("plugin").resolvingSymlinksInPath().path)
    }

    @Test("A source that is remote, unlisted, or escapes the pack is rejected")
    func rejectedSources() throws {
        let remote = try makePack(source: ["source": "github", "repo": "acme/demo"])
        let escaping = try makePack(source: "./../elsewhere")
        defer {
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: escaping)
        }
        #expect(throws: PackMarketplace.Error.sourceNotLocal("demo")) {
            try PackMarketplace.hostedPlugin(named: "demo", in: remote)
        }
        #expect(throws: PackMarketplace.Error.pluginNotListed("other")) {
            try PackMarketplace.hostedPlugin(named: "other", in: remote)
        }
        #expect(throws: PackMarketplace.Error.sourceEscapesPack("demo")) {
            try PackMarketplace.hostedPlugin(named: "demo", in: escaping)
        }
    }

    @Test("Linking writes a marketplace named for the pack that lists the linked plugin")
    func linkWritesWrapper() throws {
        let home = try makeTmpDir(label: "pack-marketplace-home")
        let pack = try makePack(source: "./")
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
        let pack = try makePack(source: "./")
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

    @Test("A source directory missing from the pack is rejected")
    func missingSource() throws {
        let pack = try makePack(source: "./plugins/fooo")
        defer { try? FileManager.default.removeItem(at: pack) }
        #expect(throws: PackMarketplace.Error.sourceMissing("demo")) {
            try PackMarketplace.hostedPlugin(named: "demo", in: pack)
        }
    }

    @Test("A marketplace manifest whose plugins value isn't a list is unreadable, not empty")
    func malformedPluginsList() throws {
        let pack = try makeTmpDir(label: "pack-marketplace")
        defer { try? FileManager.default.removeItem(at: pack) }
        let manifest = pack.appendingPathComponent(PackMarketplace.manifestPath)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"name":"acme","plugins":{"demo":"./"}}"#.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(throws: PackMarketplace.Error.manifestUnreadable("expected an object with a `plugins` list")) {
            try PackMarketplace.hostedPlugin(named: "demo", in: pack)
        }
    }
}
