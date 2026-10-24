import Foundation

/// A pack the run would add to a scope its manifest does not support.
struct UnsupportedScopePack: Equatable {
    let displayName: String
    let supported: Set<PackScope>
}

/// Raised before any removal or install, so a rejected selection leaves the scope untouched.
struct PackScopeError: Error, Equatable, LocalizedError {
    let packs: [UnsupportedScopePack]
    let scope: PackScope

    var errorDescription: String? {
        lines.joined(separator: "\n")
    }

    var lines: [String] {
        ["\(packs.count) pack(s) cannot be installed in \(scope.rawValue) scope:"]
            + packs.map { pack in
                let supported = PackScope.allCases.filter { pack.supported.contains($0) }.map(\.rawValue)
                return "  - \(pack.displayName): supports \(supported.joined(separator: ", ")) only"
            }
    }
}
