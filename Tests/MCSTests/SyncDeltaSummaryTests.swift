import Foundation
@testable import mcs
import Testing

struct SyncDeltaSummaryTests {
    @Test("Buckets additions, removals, and keeps from arbitrary sets")
    func buckets() {
        let summary = SyncDeltaSummary(
            previous: ["ios", "swift", "android"],
            selected: ["ios", "swift", "kotlin"]
        )

        #expect(summary.additions == ["kotlin"])
        #expect(summary.removals == ["android"])
        #expect(summary.keeps == ["ios", "swift"])
    }

    @Test("Empty previous means everything is an addition")
    func allAdditions() {
        let summary = SyncDeltaSummary(
            previous: [],
            selected: ["ios", "swift"]
        )

        #expect(summary.additions == ["ios", "swift"])
        #expect(summary.removals.isEmpty)
        #expect(summary.keeps.isEmpty)
    }

    @Test("Empty selected means everything is a removal")
    func allRemovals() {
        let summary = SyncDeltaSummary(
            previous: ["ios", "swift"],
            selected: []
        )

        #expect(summary.additions.isEmpty)
        #expect(summary.removals == ["ios", "swift"])
        #expect(summary.keeps.isEmpty)
    }

    @Test("Identical sets produce keeps only")
    func noChanges() {
        let summary = SyncDeltaSummary(
            previous: ["ios", "swift"],
            selected: ["ios", "swift"]
        )

        #expect(summary.additions.isEmpty)
        #expect(summary.removals.isEmpty)
        #expect(summary.keeps == ["ios", "swift"])
        #expect(summary.hasRemovals == false)
    }

    @Test("hasRemovals reflects removal presence")
    func hasRemovalsFlag() {
        let withRemovals = SyncDeltaSummary(previous: ["a"], selected: [])
        let withoutRemovals = SyncDeltaSummary(previous: [], selected: ["a"])
        #expect(withRemovals.hasRemovals)
        #expect(!withoutRemovals.hasRemovals)
    }

    @Test("Sorting is deterministic")
    func sorting() {
        let summary = SyncDeltaSummary(
            previous: ["zebra", "alpha", "mike"],
            selected: ["zebra", "alpha"]
        )
        #expect(summary.keeps == ["alpha", "zebra"])
        #expect(summary.removals == ["mike"])
    }

    @Test("renderReviewBlock plain output matches golden layout")
    func renderPlainGolden() {
        let summary = SyncDeltaSummary(
            previous: ["android", "swift"],
            selected: ["swift", "kotlin"]
        )
        let block = summary.renderReviewBlock(style: ANSIStyle(enabled: false))
        let expected = """
          + add:      kotlin
          - remove:   android
          = keep:     swift
        """
        #expect(block == expected)
    }

    @Test("renderReviewBlock colored output emits green, red, AND dim")
    func renderColored() {
        let summary = SyncDeltaSummary(
            previous: ["android", "shared"],
            selected: ["kotlin", "shared"]
        )
        let block = summary.renderReviewBlock(style: ANSIStyle(enabled: true))

        #expect(block.contains("\u{1B}[0;32m"))
        #expect(block.contains("\u{1B}[0;31m"))
        #expect(block.contains("\u{1B}[2m"))
        #expect(block.contains("\u{1B}[0m"))
    }

    @Test("renderReviewBlock omits sections that are empty")
    func renderOmitsEmpty() {
        let summary = SyncDeltaSummary(previous: [], selected: ["ios"])
        let block = summary.renderReviewBlock(style: ANSIStyle(enabled: false))

        #expect(block.contains("+ add:"))
        #expect(!block.contains("- remove:"))
        #expect(!block.contains("= keep:"))
    }

    @Test("isFullWipe true when removing every previous pack with nothing to keep or add")
    func fullWipe() {
        let wipe = SyncDeltaSummary(previous: ["ios", "swift"], selected: [])
        #expect(wipe.isFullWipe)

        let partialRemoval = SyncDeltaSummary(previous: ["ios", "swift"], selected: ["ios"])
        #expect(!partialRemoval.isFullWipe)

        let additionsOnly = SyncDeltaSummary(previous: [], selected: ["ios"])
        #expect(!additionsOnly.isFullWipe)
    }
}
