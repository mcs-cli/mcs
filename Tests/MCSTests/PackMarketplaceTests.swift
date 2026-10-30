import Foundation
@testable import mcs
import Testing

struct PackMarketplaceTests {
    private func resolve(_ source: String?, in pack: URL) throws -> PackMarketplace.HostedPlugin {
        try PackMarketplace.hostedPlugin(named: "demo", source: source, packPath: pack)
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
        let plugin = try resolve("plugins/demo", in: pack)
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
        #expect(try resolve(nil, in: pack).relativePath == ".")
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

    private func makeLinkFixture() throws -> (home: URL, pack: URL, env: Environment) {
        let home = try makeTmpDir(label: "pack-marketplace-home")
        let pack = try makeTmpDir(label: "pack-marketplace")
        try writePluginManifest(at: pack, name: "demo")
        try FileManager.default.createDirectory(at: pack.appendingPathComponent("hooks/mod"), withIntermediateDirectories: true)
        try "export {}".write(to: pack.appendingPathComponent("hooks/mod/register.ts"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: pack.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref".write(to: pack.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return (home, pack, Environment(home: home))
    }

    @Test("Linking copies the plugin into a marketplace named for the pack, so no plugin path leaves it")
    func linkWritesWrapper() throws {
        let (home, pack, env) = try makeLinkFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }

        let wrapper = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)

        let data = try Data(contentsOf: wrapper.appendingPathComponent(".claude-plugin/marketplace.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["name"] as? String == "mcs-xcrew")
        let plugins = try #require(manifest["plugins"] as? [[String: String]])
        #expect(plugins == [["name": "demo", "source": "./plugins/demo"]])
        let copy = wrapper.appendingPathComponent("plugins/demo")
        let isLink = try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        #expect(isLink == false)
        #expect(try String(contentsOf: copy.appendingPathComponent("hooks/mod/register.ts"), encoding: .utf8) == "export {}")
        #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent(".git").path))
    }

    @Test("Linking again leaves an unchanged copy alone and re-copies a changed one")
    func relinkOnlyWhenChanged() throws {
        let (home, pack, env) = try makeLinkFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }
        let wrapper = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)
        let copied = wrapper.appendingPathComponent("plugins/demo/hooks/mod/register.ts")
        // Claude Code writes into the plugin folder it loads; an unchanged source must not wipe that.
        try "generated".write(to: wrapper.appendingPathComponent("plugins/demo/runtime.txt"), atomically: true, encoding: .utf8)

        _ = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)
        #expect(FileManager.default.fileExists(atPath: wrapper.appendingPathComponent("plugins/demo/runtime.txt").path))

        try "export const changed = 1".write(to: pack.appendingPathComponent("hooks/mod/register.ts"), atomically: true, encoding: .utf8)
        _ = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)
        #expect(try String(contentsOf: copied, encoding: .utf8) == "export const changed = 1")
    }

    @Test("A symlink an older mcs left is replaced by a copy")
    func legacySymlinkMigrates() throws {
        let (home, pack, env) = try makeLinkFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }
        let plugins = PackMarketplace.wrapperDirectory(packID: "xcrew", environment: env).appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plugins.appendingPathComponent("demo"), withDestinationURL: pack)
        #expect(try PackMarketplace.linkedPlugins(packID: "xcrew", environment: env) == ["demo"])

        _ = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)

        let isLink = try plugins.appendingPathComponent("demo").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
        #expect(isLink == false)
        #expect(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("demo/hooks/mod/register.ts").path))
    }

    @Test("Unlinking drops the plugin from the marketplace without removing the marketplace")
    func unlink() throws {
        let (home, pack, env) = try makeLinkFixture()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: pack)
        }
        _ = try PackMarketplace.link(pluginName: "demo", to: pack, packID: "xcrew", environment: env)

        try PackMarketplace.unlink(pluginName: "demo", packID: "xcrew", environment: env)

        #expect(try PackMarketplace.linkedPlugins(packID: "xcrew", environment: env).isEmpty)
        let plugins = PackMarketplace.wrapperDirectory(packID: "xcrew", environment: env).appendingPathComponent("plugins")
        #expect(try FileManager.default.contentsOfDirectory(atPath: plugins.path).isEmpty)
        let manifestURL = PackMarketplace.wrapperDirectory(packID: "xcrew", environment: env)
            .appendingPathComponent(PackMarketplace.manifestPath)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        #expect((manifest["plugins"] as? [Any])?.isEmpty == true)
    }
}
