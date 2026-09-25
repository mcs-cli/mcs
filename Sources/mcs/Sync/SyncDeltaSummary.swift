import Foundation

/// `additions`, `removals`, `keeps` form a disjoint partition of `previous ∪ selected` —
/// the three-way split is the whole reason this type exists.
struct SyncDeltaSummary {
    let additions: [String]
    let removals: [String]
    let keeps: [String]

    init(previous: Set<String>, selected: Set<String>) {
        additions = selected.subtracting(previous).sorted()
        removals = previous.subtracting(selected).sorted()
        keeps = previous.intersection(selected).sorted()
    }

    var hasRemovals: Bool {
        !removals.isEmpty
    }

    /// True when the delta is "remove every previously configured pack with nothing to keep or add."
    /// Callers use this to render a stronger warning before confirming a full wipe.
    var isFullWipe: Bool {
        !removals.isEmpty && additions.isEmpty && keeps.isEmpty
    }

    func renderReviewBlock(style: ANSIStyle) -> String {
        var lines: [String] = []
        if !additions.isEmpty {
            lines.append("  \(style.green)+ add:\(style.reset)      \(additions.joined(separator: ", "))")
        }
        if !removals.isEmpty {
            lines.append("  \(style.red)- remove:\(style.reset)   \(removals.joined(separator: ", "))")
        }
        if !keeps.isEmpty {
            lines.append("  \(style.dim)= keep:\(style.reset)     \(keeps.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
