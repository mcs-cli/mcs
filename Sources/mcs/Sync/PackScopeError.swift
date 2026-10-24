import Foundation

/// Raised before any removal or install, so a rejected selection leaves the scope untouched.
struct PackScopeError: Error, LocalizedError {
    let packs: [any TechPack]
    let scope: PackScope

    var errorDescription: String? {
        let lines = packs.map { pack in
            let supported = PackScope.allCases.filter(pack.supportedScopes.contains).map(\.rawValue)
            return "  - \(pack.displayName): supports \(supported.joined(separator: ", ")) only"
        }
        return (["\(packs.count) pack(s) cannot be installed in \(scope.rawValue) scope:"] + lines)
            .joined(separator: "\n")
    }
}
