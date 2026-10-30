import Foundation

/// Parsed representation of a plugin reference from `techpack.yaml`.
///
/// Plugin names in manifests use the format `name@source` where `source` is either a
/// marketplace repository (`anthropics/claude-plugins-official`) or a marketplace's name
/// (`claude-plugins-official`). The CLI is driven by the resolved `name@<marketplace-name>` id.
///
/// When no `@source` suffix is present, the official Anthropic marketplace is assumed.
struct PluginRef: Equatable {
    /// The bare plugin name (e.g. `pr-review-toolkit`).
    let bareName: String

    /// The marketplace repo path (e.g. `anthropics/claude-plugins-official`).
    let marketplaceRepo: String

    /// The original full string as declared in the manifest.
    let fullName: String

    /// The marketplace's name as Claude Code keys it, when the reference itself says so.
    ///
    /// `nil` for an `@org/repo` reference: the name is declared by the marketplace, not derivable
    /// from the repo, so it has to be looked up after `marketplace add`.
    let marketplaceName: String?

    /// Parse a plugin reference string.
    ///
    /// Accepted formats:
    /// - `"my-plugin"` — bare name, defaults to official marketplace
    /// - `"my-plugin@claude-plugins-official"` — short marketplace identifier
    /// - `"my-plugin@org/repo"` — full repo path
    init(_ fullName: String) {
        self.fullName = fullName
        let parts = fullName.split(separator: "@", maxSplits: 1)
        if parts.count == 2 {
            bareName = String(parts[0])
            let repoToken = String(parts[1])
            if repoToken.contains("/") {
                marketplaceRepo = repoToken
                marketplaceName = repoToken == Constants.Plugins.officialMarketplaceRepo
                    ? Constants.Plugins.officialMarketplace : nil
            } else if repoToken == Constants.Plugins.officialMarketplace {
                marketplaceRepo = Constants.Plugins.officialMarketplaceRepo
                marketplaceName = repoToken
            } else {
                marketplaceRepo = repoToken
                marketplaceName = repoToken
            }
        } else {
            bareName = fullName
            marketplaceRepo = Constants.Plugins.officialMarketplaceRepo
            marketplaceName = Constants.Plugins.officialMarketplace
        }
    }

    /// Whether the manifest declared `name@pack`, before the adapter resolves it to the pack's marketplace.
    var isPackToken: Bool {
        marketplaceName == Constants.Plugins.packToken
    }

    /// The pack whose checkout this plugin loads from, through the marketplace mcs generates for it.
    var hostingPackID: String? {
        guard let marketplaceName, marketplaceName.hasPrefix(Constants.Plugins.packMarketplacePrefix) else { return nil }
        return String(marketplaceName.dropFirst(Constants.Plugins.packMarketplacePrefix.count))
    }

    var isPackHosted: Bool {
        hostingPackID != nil
    }

    /// Whether `marketplaceRepo` names a repo `claude plugin marketplace add` can register.
    var hasMarketplaceRepo: Bool {
        marketplaceRepo.contains("/")
    }

    /// The `name@marketplace` id Claude Code uses, resolved against the configured marketplaces.
    func pluginID(in marketplaces: [PluginMarketplace]) -> String? {
        if let marketplaceName { return "\(bareName)@\(marketplaceName)" }
        let repo = marketplaceRepo.lowercased()
        return marketplaces.first { $0.repo?.lowercased() == repo }.map { "\(bareName)@\($0.name)" }
    }

    /// Matched by name, except that plugins hosted by different packs, or by a pack and a
    /// marketplace, are different plugins. A pack switching to `@pack` must drop the old install
    /// rather than keep it beside the new one, where Claude Code would load only one copy's hooks;
    /// and one pack's copy must never count as a claim on another pack's.
    func isSamePlugin(as other: PluginRef) -> Bool {
        bareName == other.bareName && hostingPackID == other.hostingPackID
    }

    /// Whether `id` (`name@marketplace`) is this plugin.
    func matches(id: String) -> Bool {
        let parts = id.split(separator: "@", maxSplits: 1)
        guard let name = parts.first, String(name) == bareName else { return false }
        guard let marketplaceName, parts.count == 2 else { return true }
        return String(parts[1]) == marketplaceName
    }
}

/// One entry of `claude plugin marketplace list --json`.
struct PluginMarketplace: Codable, Equatable {
    let name: String
    let repo: String?
}

/// One entry of `claude plugin list --json`.
struct InstalledPlugin: Codable, Equatable {
    let id: String
    let scope: String
    let enabled: Bool
    /// The project a `local`- or `project`-scoped install belongs to.
    let projectPath: String?
    var version: String?
    /// Set when the plugin loads in place from a local marketplace folder rather than a cached copy.
    var readFromFolder: String?
    /// Why Claude Code refused part or all of the plugin, e.g. a path that escapes its directory.
    var errors: [String]?

    /// Whether this install is at `scope` and, unless that is `user`, belongs to `projectDirectory`.
    func isInstall(atScope scope: String, projectDirectory: URL?) -> Bool {
        guard self.scope == scope else { return false }
        // `local` and `project` installs are listed for every project; only `user` applies everywhere.
        guard scope != Constants.PluginScope.user else { return true }
        guard let projectDirectory, let projectPath else { return false }
        return URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
            == projectDirectory.resolvingSymlinksInPath().path
    }
}

/// `claude plugin list --json`, run once per directory for the life of one sync or doctor run.
///
/// Every plugin component and every `PluginCheck` needs the same listing, and each CLI call costs
/// a process start. Installs and removals made through it invalidate what they changed.
final class PluginListing: @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
    }

    let claudeCLI: any ClaudeCLI
    private let lock = NSLock()
    private var byDirectory: [String: Result<[InstalledPlugin], Failure>] = [:]

    init(claudeCLI: any ClaudeCLI) {
        self.claudeCLI = claudeCLI
    }

    /// Listed from `directory`, `enabled` is what that directory's project actually loads.
    func plugins(in directory: URL?) -> Result<[InstalledPlugin], Failure> {
        let key = directory?.path ?? ""
        lock.lock()
        defer { lock.unlock() }
        if let cached = byDirectory[key] { return cached }
        let listed = list(in: directory)
        byDirectory[key] = listed
        return listed
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        byDirectory.removeAll()
    }

    private func list(in directory: URL?) -> Result<[InstalledPlugin], Failure> {
        guard claudeCLI.isAvailable else { return .failure(Failure(errorDescription: "Claude Code CLI not found")) }
        let result = claudeCLI.pluginList(workingDirectory: directory)
        guard result.succeeded else {
            return .failure(Failure(errorDescription: "could not list plugins: \(String(result.stderr.prefix(200)))"))
        }
        do {
            return try .success(JSONDecoder().decode([InstalledPlugin].self, from: Data(result.stdout.utf8)))
        } catch {
            return .failure(Failure(errorDescription: "could not read the plugin list: \(error.localizedDescription)"))
        }
    }
}

extension PackArtifactRecord {
    func ownsPlugin(_ name: String) -> Bool {
        let ref = PluginRef(name)
        return plugins.contains { PluginRef($0).isSamePlugin(as: ref) }
    }

    /// A re-sync finds an owned plugin already installed and does not record it again, so ownership
    /// is carried over, but only while the pack still declares it: a dropped one must read as stale.
    func pluginsStillDeclared(by pack: any TechPack) -> [String] {
        plugins.filter { pack.declaresPlugin($0) }
    }
}

extension TechPack {
    func declaresPlugin(_ name: String) -> Bool {
        let ref = PluginRef(name)
        return components.contains { component in
            guard case let .plugin(declared) = component.installAction else { return false }
            return PluginRef(declared).isSamePlugin(as: ref)
        }
    }
}
