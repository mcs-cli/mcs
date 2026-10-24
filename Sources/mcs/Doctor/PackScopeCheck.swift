import Foundation

/// Reports a pack configured in a scope its manifest no longer supports.
///
/// Sync only rejects a pack *entering* an unsupported scope (`ConfiguratorSupport.scopeUnsupportedIDs`),
/// so one installed before it declared `scopes:` stays and keeps being re-applied. Removing it is
/// the user's call, so there is no fix.
struct PackScopeCheck: DoctorCheck {
    let packID: String
    let scope: PackScope

    var name: String {
        "Pack scope: \(packID)"
    }

    var section: String {
        "Packs"
    }

    func check() -> CheckResult {
        .warn("does not support \(scope.rawValue) scope — \(remedy)")
    }

    func fix() -> FixResult {
        .notFixable(remedy)
    }

    private var remedy: String {
        let sync = scope == .global ? "mcs sync --global" : "mcs sync"
        return "deselect it with '\(sync)', or run 'mcs pack remove \(packID)'"
    }
}
