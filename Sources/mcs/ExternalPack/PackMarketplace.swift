import Foundation

/// A pack's own `.claude-plugin/marketplace.json`, and the marketplace mcs generates so Claude Code
/// loads the pack's plugins from its checkout.
///
/// The generated marketplace links to the checkout instead of registering it directly: the pack's
/// manifest names its marketplace (often the author's general one), and a second registration
/// under that name would collide with an existing one, whose removal uninstalls its plugins.
enum PackMarketplace {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case manifestMissing
        case manifestUnreadable(String)
        case pluginNotListed(String)
        case sourceNotLocal(String)
        case sourceEscapesPack(String)

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                "no \(PackMarketplace.manifestPath) in the pack"
            case let .manifestUnreadable(reason):
                "\(PackMarketplace.manifestPath) could not be read: \(reason)"
            case let .pluginNotListed(name):
                "\(PackMarketplace.manifestPath) lists no plugin named '\(name)'"
            case let .sourceNotLocal(name):
                "plugin '\(name)' in \(PackMarketplace.manifestPath) needs a relative `source` such as \"./\""
            case let .sourceEscapesPack(name):
                "the source of plugin '\(name)' in \(PackMarketplace.manifestPath) points outside the pack"
            }
        }
    }

    static let manifestPath = ".claude-plugin/marketplace.json"

    static func marketplaceName(packID: String) -> String {
        Constants.Plugins.packMarketplacePrefix + packID
    }

    /// The plugin id a manifest's `name@pack` resolves to.
    static func pluginID(bareName: String, packID: String) -> String {
        "\(bareName)@\(marketplaceName(packID: packID))"
    }

    static func wrapperDirectory(packID: String, environment: Environment) -> URL {
        environment.packMarketplacesDirectory.appendingPathComponent(packID)
    }

    /// A plugin the pack declares as `name@pack`, resolved against the pack's own marketplace.
    struct HostedPlugin: Equatable {
        let name: String
        let source: URL
        /// Relative to the pack root; `"."` when the plugin is the whole pack.
        let relativePath: String
    }

    /// Every `name@pack` plugin `manifest` declares, resolved against the marketplace in `packPath`.
    static func hostedPlugins(in manifest: ExternalPackManifest, packPath: URL) throws -> [HostedPlugin] {
        let names = (manifest.components ?? []).compactMap { component -> String? in
            guard case let .plugin(name) = component.installAction else { return nil }
            let ref = PluginRef(name)
            return ref.isPackToken ? ref.bareName : nil
        }
        guard !names.isEmpty else { return [] }
        let entries = try marketplaceEntries(in: packPath)
        return try names.map { try resolve($0, entries: entries, packPath: packPath) }
    }

    /// The plugin `pluginName` as the pack's marketplace lists it.
    static func hostedPlugin(named pluginName: String, in packPath: URL) throws -> HostedPlugin {
        try resolve(pluginName, entries: marketplaceEntries(in: packPath), packPath: packPath)
    }

    private static func marketplaceEntries(in packPath: URL) throws -> [[String: Any]] {
        let manifestURL = packPath.appendingPathComponent(manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw Error.manifestMissing }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            return (object as? [String: Any])?["plugins"] as? [[String: Any]] ?? []
        } catch {
            throw Error.manifestUnreadable(error.localizedDescription)
        }
    }

    private static func resolve(_ pluginName: String, entries: [[String: Any]], packPath: URL) throws -> HostedPlugin {
        guard let entry = entries.first(where: { $0["name"] as? String == pluginName }) else {
            throw Error.pluginNotListed(pluginName)
        }
        // Only a relative-path source loads in place; a remote one is copied from its own origin.
        guard let source = entry["source"] as? String, source == "." || source.hasPrefix("./") else {
            throw Error.sourceNotLocal(pluginName)
        }
        if source == "." || source == "./" {
            return HostedPlugin(name: pluginName, source: packPath, relativePath: ".")
        }
        let relative = String(source.dropFirst(2))
        guard let resolved = PathContainment.safePath(relativePath: relative, within: packPath) else {
            throw Error.sourceEscapesPack(pluginName)
        }
        return HostedPlugin(name: pluginName, source: resolved, relativePath: relative)
    }

    /// Link `pluginName` to `source` in the pack's generated marketplace. Returns the marketplace
    /// directory to register with `claude plugin marketplace add`.
    static func link(pluginName: String, to source: URL, packID: String, environment: Environment) throws -> URL {
        let wrapper = wrapperDirectory(packID: packID, environment: environment)
        let pluginsDir = wrapper.appendingPathComponent("plugins")
        let link = pluginsDir.appendingPathComponent(pluginName)
        let fm = FileManager.default
        // Untouched when already current, so a re-sync never makes the marketplace look changed.
        let isCurrent = (try? fm.destinationOfSymbolicLink(atPath: link.path)) == source.path
        if isCurrent, fm.fileExists(atPath: wrapper.appendingPathComponent(manifestPath).path) {
            return wrapper
        }
        if !isCurrent {
            try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            if isSymbolicLink(link) || fm.fileExists(atPath: link.path) {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        }
        try writeManifest(packID: packID, wrapper: wrapper)
        return wrapper
    }

    /// Stop Claude Code loading the plugin without uninstalling it, so its options and data survive
    /// until a trusted sync links it again.
    static func unlink(pluginName: String, packID: String, environment: Environment) throws {
        let wrapper = wrapperDirectory(packID: packID, environment: environment)
        let link = wrapper.appendingPathComponent("plugins").appendingPathComponent(pluginName)
        guard isSymbolicLink(link) else { return }
        try FileManager.default.removeItem(at: link)
        try writeManifest(packID: packID, wrapper: wrapper)
    }

    static func remove(packID: String, environment: Environment) throws {
        let wrapper = wrapperDirectory(packID: packID, environment: environment)
        guard FileManager.default.fileExists(atPath: wrapper.path) else { return }
        try FileManager.default.removeItem(at: wrapper)
    }

    static func linkedPlugins(packID: String, environment: Environment) throws -> [String] {
        try linkNames(in: wrapperDirectory(packID: packID, environment: environment).appendingPathComponent("plugins"))
    }

    private static func linkNames(in pluginsDir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)
            .filter { isSymbolicLink(pluginsDir.appendingPathComponent($0)) }
            .sorted()
    }

    private static func writeManifest(packID: String, wrapper: URL) throws {
        let names = try linkNames(in: wrapper.appendingPathComponent("plugins"))
        let manifest: [String: Any] = [
            "name": marketplaceName(packID: packID),
            "owner": ["name": "mcs"],
            "metadata": ["description": "Plugins hosted by the \(packID) tech pack, loaded from its mcs checkout"],
            "plugins": names.map { ["name": $0, "source": "./plugins/\($0)"] },
        ]
        let manifestURL = wrapper.appendingPathComponent(manifestPath)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
