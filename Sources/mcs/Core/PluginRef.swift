import Foundation

/// Parsed representation of a plugin reference from `techpack.yaml`.
///
/// Plugin names in manifests use the format `name@repo` where:
/// - `name` is the bare plugin name passed to `claude plugin install/remove`
/// - `repo` is the marketplace repository (e.g. `anthropics/claude-plugins-official`)
///
/// When no `@repo` suffix is present, the official Anthropic marketplace is assumed.
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

    /// Whether `id` (`name@marketplace`) is this plugin.
    func matches(id: String) -> Bool {
        let parts = id.split(separator: "@", maxSplits: 1)
        guard String(parts[0]) == bareName else { return false }
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

    /// Whether this install is the one a sync at `scope` (in `projectDirectory`, for `local`) owns.
    func isInstall(atScope scope: String, projectDirectory: URL?) -> Bool {
        guard self.scope == scope else { return false }
        guard scope == Constants.PluginScope.local else { return true }
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
        let bareName = PluginRef(name).bareName
        return plugins.contains { PluginRef($0).bareName == bareName }
    }
}

extension TechPack {
    func declaresPlugin(_ name: String) -> Bool {
        let bareName = PluginRef(name).bareName
        return components.contains { component in
            guard case let .plugin(declared) = component.installAction else { return false }
            return PluginRef(declared).bareName == bareName
        }
    }
}
