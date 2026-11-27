import Foundation

/// Raised before any removal or install, so a rejected selection leaves the scope untouched.
struct PackScopeError: Error, LocalizedError {
    let packs: [any TechPack]
    let scope: PackScope

    var errorDescription: String? {
        let lines = packs.map { pack in
            let supported = PackScope.allCases.filter(pack.supportedScopes.contains)
            guard !supported.isEmpty else {
                return "  - \(pack.displayName): its techpack.yaml declares no valid `scopes:` value"
            }
            let command = supported.contains(.global)
                ? "mcs sync --global --pack \(pack.identifier)"
                : "mcs sync --pack \(pack.identifier)"
            return "  - \(pack.displayName): supports \(supported.map(\.rawValue).joined(separator: ", ")) only"
                + " — install it with '\(command)'"
        }
        return (["\(packs.count) pack(s) cannot be installed in \(scope.rawValue) scope:"] + lines)
            .joined(separator: "\n")
    }
}
