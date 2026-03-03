/// Parsed representation of a plugin reference from `techpack.yaml`.
///
/// Plugin names in manifests use the format `name@repo` where:
/// - `name` is the bare plugin name passed to `claude plugin install/remove`
/// - `repo` is the marketplace repository (e.g. `anthropics/claude-plugins-official`)
///
/// When no `@repo` suffix is present, the official Anthropic marketplace is assumed.
struct PluginRef: Sendable, Equatable {
    /// The bare plugin name (e.g. `pr-review-toolkit`).
    let bareName: String

    /// The marketplace repo path (e.g. `anthropics/claude-plugins-official`).
    let marketplaceRepo: String

    /// The original full string as declared in the manifest.
    let fullName: String

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
            } else if repoToken == Constants.Plugins.officialMarketplace {
                marketplaceRepo = Constants.Plugins.officialMarketplaceRepo
            } else {
                marketplaceRepo = repoToken
            }
        } else {
            bareName = fullName
            marketplaceRepo = Constants.Plugins.officialMarketplaceRepo
        }
    }
}
