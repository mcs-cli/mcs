import Foundation

/// The marketplace mcs generates so Claude Code loads a copy of each of a pack's `name@pack` plugins.
///
/// The plugin's directory comes from the pack's techpack.yaml, never from the pack's own
/// `.claude-plugin/marketplace.json`: a repo that is also a public marketplace keeps that catalog
/// pointed wherever direct Claude Code installs need it (a release branch, say). The generated
/// marketplace holds copies instead of registering the checkout directly, because a second
/// registration under the author's marketplace name would collide with an existing one, whose
/// removal uninstalls its plugins.
enum PackMarketplace {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case sourceEscapesPack(String)
        case sourceMissing(String)
        case pluginManifestMissing(name: String, path: String)
        case pluginManifestUnreadable(name: String, reason: String)
        case pluginNameMismatch(name: String, declared: String)
        case unregisterFailed(name: String, stderr: String)

        var errorDescription: String? {
            switch self {
            case let .sourceEscapesPack(name):
                "the directory of plugin '\(name)' points outside the pack"
            case let .sourceMissing(name):
                "the directory of plugin '\(name)' is not a directory in the pack"
            case let .pluginManifestMissing(name, path):
                "plugin '\(name)' has no \(path)"
            case let .pluginManifestUnreadable(name, reason):
                "the \(PackMarketplace.pluginManifestPath) of plugin '\(name)' could not be read: \(reason)"
            case let .pluginNameMismatch(name, declared):
                "plugin '\(name)' is named '\(declared)' in its \(PackMarketplace.pluginManifestPath)"
            case let .unregisterFailed(name, stderr):
                "could not remove marketplace '\(name)': \(stderr)"
            }
        }
    }

    static let manifestPath = ".claude-plugin/marketplace.json"
    static let pluginManifestPath = ".claude-plugin/plugin.json"

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

    /// A plugin the pack declares as `name@pack`, resolved to its directory in the checkout.
    struct HostedPlugin: Equatable {
        let name: String
        let source: URL
        /// Relative to the pack root; `"."` when the plugin is the whole pack.
        let relativePath: String
    }

    /// Every `name@pack` plugin `manifest` declares, resolved against `packPath`.
    static func hostedPlugins(in manifest: ExternalPackManifest, packPath: URL) throws -> [HostedPlugin] {
        try (manifest.components ?? []).compactMap { component in
            guard case let .plugin(name, source) = component.installAction else { return nil }
            let ref = PluginRef(name)
            return ref.isPackToken ? try hostedPlugin(named: ref.bareName, source: source, packPath: packPath) : nil
        }
    }

    /// The plugin in `source` (the pack root when nil), checked to be a directory in the pack whose
    /// plugin.json names it `pluginName`.
    static func hostedPlugin(named pluginName: String, source: String?, packPath: URL) throws -> HostedPlugin {
        let directory: URL
        if let source {
            guard let resolved = PathContainment.safePath(relativePath: source, within: packPath) else {
                throw Error.sourceEscapesPack(pluginName)
            }
            directory = resolved
        } else {
            directory = packPath
        }
        // A missing directory would hash as empty and store nothing, so the pack could never be trusted.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.sourceMissing(pluginName)
        }
        let plugin = HostedPlugin(name: pluginName, source: directory, relativePath: source ?? ".")
        try verifyPluginManifest(of: plugin)
        return plugin
    }

    /// The generated marketplace lists the plugin under its name, so a plugin.json naming it
    /// otherwise would be installed under one id and identify itself by another.
    private static func verifyPluginManifest(of plugin: HostedPlugin) throws {
        let manifestURL = plugin.source.appendingPathComponent(pluginManifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            let path = plugin.relativePath == "." ? pluginManifestPath : "\(plugin.relativePath)/\(pluginManifestPath)"
            throw Error.pluginManifestMissing(name: plugin.name, path: path)
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        } catch {
            throw Error.pluginManifestUnreadable(name: plugin.name, reason: error.localizedDescription)
        }
        guard let declared = (object as? [String: Any])?["name"] as? String else {
            throw Error.pluginManifestUnreadable(name: plugin.name, reason: "expected an object with a `name` string")
        }
        guard declared == plugin.name else {
            throw Error.pluginNameMismatch(name: plugin.name, declared: declared)
        }
    }

    /// Where mcs keeps its copy of a pack-hosted plugin, and where Claude Code must read it from.
    static func pluginDirectory(pluginName: String, packID: String, environment: Environment) -> URL {
        wrapperDirectory(packID: packID, environment: environment)
            .appendingPathComponent("plugins").appendingPathComponent(pluginName)
    }

    /// Copy `pluginName` from `source` into the pack's generated marketplace. Returns the marketplace
    /// directory to register with `claude plugin marketplace add`.
    ///
    /// A copy, not a symlink: Claude Code resolves symlinks and refuses any plugin path that then
    /// lands outside the marketplace, which drops hook modules and anything else loaded by path.
    static func link(pluginName: String, to source: URL, packID: String, environment: Environment) throws -> URL {
        let wrapper = wrapperDirectory(packID: packID, environment: environment)
        let destination = pluginDirectory(pluginName: pluginName, packID: packID, environment: environment)
        let fm = FileManager.default
        let fingerprint = try Data(sourceFingerprint(of: source).utf8)
        // Untouched when already current, so a re-sync never makes the marketplace look changed. A
        // legacy symlink points at the source, which never carries the fingerprint, so it is replaced.
        if fm.contents(atPath: destination.appendingPathComponent(fingerprintFile).path) != fingerprint {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(pluginName).staging")
            // A run that failed mid-copy leaves this behind; it is hidden from `linkNames`.
            if entryExists(staging) {
                try fm.removeItem(at: staging)
            }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: source.path) where item != ".git" {
                try fm.copyItem(at: source.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            try fingerprint.write(to: staging.appendingPathComponent(fingerprintFile))
            if entryExists(destination) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: staging, to: destination)
        }
        try writeManifest(packID: packID, wrapper: wrapper)
        return wrapper
    }

    /// Stop Claude Code loading the plugin without uninstalling it, so its options and data survive
    /// until a trusted sync copies it again.
    static func unlink(pluginName: String, packID: String, environment: Environment) throws {
        let entry = pluginDirectory(pluginName: pluginName, packID: packID, environment: environment)
        guard entryExists(entry) else { return }
        try FileManager.default.removeItem(at: entry)
        try writeManifest(packID: packID, wrapper: wrapperDirectory(packID: packID, environment: environment))
    }

    /// Unregister the pack's generated marketplace and delete it. Claude Code uninstalls its
    /// plugins from every scope, so this runs only after every scope is unconfigured.
    static func unregister(packID: String, claudeCLI: any ClaudeCLI, environment: Environment) throws {
        guard FileManager.default.fileExists(atPath: wrapperDirectory(packID: packID, environment: environment).path) else { return }
        let name = marketplaceName(packID: packID)
        let result = claudeCLI.pluginMarketplaceRemove(name: name)
        // Unregistered already (e.g. by hand) is the state removal wants.
        if !result.succeeded, try claudeCLI.marketplaces().contains(where: { $0.name == name }) {
            throw Error.unregisterFailed(name: name, stderr: String(result.stderr.prefix(200)))
        }
        try remove(packID: packID, environment: environment)
    }

    static func remove(packID: String, environment: Environment) throws {
        let wrapper = wrapperDirectory(packID: packID, environment: environment)
        guard FileManager.default.fileExists(atPath: wrapper.path) else { return }
        try FileManager.default.removeItem(at: wrapper)
    }

    static func linkedPlugins(packID: String, environment: Environment) throws -> [String] {
        try linkNames(in: wrapperDirectory(packID: packID, environment: environment).appendingPathComponent("plugins"))
    }

    /// Copied plugins, plus symlinks an older mcs left so they are found and replaced.
    private static func linkNames(in pluginsDir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)
            .filter { name in
                guard !name.hasPrefix(".") else { return false }
                let url = pluginsDir.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                return isSymbolicLink(url)
                    || (FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            }
            .sorted()
    }

    /// Path, size, modification time and file number of every entry the copy takes (all but the
    /// top-level `.git`): a checkout move or an edit changes at least one of them, and nothing is read.
    private static func sourceFingerprint(of source: URL) throws -> String {
        let fm = FileManager.default
        let root = source.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else {
            throw MCSError.fileOperationFailed(path: root.path, reason: "Could not enumerate the plugin directory")
        }
        var lines: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level == 1, url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let relative = PathContainment.relativePath(of: url.path, within: root.path)
            lines.append("\(relative)\u{0}\(size)\u{0}\(modified)\u{0}\(fileNumber)")
        }
        return FileHasher.sha256(data: Data(lines.sorted().joined(separator: "\n").utf8))
    }

    private static func writeManifest(packID: String, wrapper: URL) throws {
        let names = try linkNames(in: wrapper.appendingPathComponent("plugins"))
        let manifest: [String: Any] = [
            "name": marketplaceName(packID: packID),
            "owner": ["name": "mcs"],
            "metadata": ["description": "Plugins hosted by the \(packID) tech pack, copied from its mcs checkout"],
            "plugins": names.map { ["name": $0, "source": "./plugins/\($0)"] },
        ]
        let manifestURL = wrapper.appendingPathComponent(manifestPath)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        guard FileManager.default.contents(atPath: manifestURL.path) != data else { return }
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: manifestURL, options: .atomic)
    }

    private static let fingerprintFile = ".mcs-fingerprint"

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// Without following a final symlink, so a legacy link to a moved checkout still counts.
    private static func entryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
