import Foundation
@testable import mcs
import Testing

struct PickerDeltaTests {
    // MARK: - RowState

    private let plain = ANSIStyle(enabled: false)
    private let colored = ANSIStyle(enabled: true)

    @Test("RowState classifies all four (isSelected, baselineSelected) combinations")
    func rowStateMatrix() {
        #expect(PickerDelta.RowState.from(isSelected: true, baselineSelected: true) == .installedKept)
        #expect(PickerDelta.RowState.from(isSelected: false, baselineSelected: true) == .installedRemoved)
        #expect(PickerDelta.RowState.from(isSelected: true, baselineSelected: false) == .newInstall)
        #expect(PickerDelta.RowState.from(isSelected: false, baselineSelected: false) == .notInstalled)
    }

    // MARK: - tagString

    @Test("installedKept renders teaching tag only under cursor")
    func installedKeptTag() {
        let cursor = PickerDelta.tagString(state: .installedKept, isCursor: true, style: plain)
        let offCursor = PickerDelta.tagString(state: .installedKept, isCursor: false, style: plain)

        #expect(cursor.contains("installed · uncheck to remove"))
        #expect(offCursor.isEmpty)
    }

    @Test("notInstalled renders plain tag only under cursor")
    func notInstalledTag() {
        let cursor = PickerDelta.tagString(state: .notInstalled, isCursor: true, style: plain)
        let offCursor = PickerDelta.tagString(state: .notInstalled, isCursor: false, style: plain)

        #expect(cursor.contains("not installed"))
        #expect(offCursor.isEmpty)
    }

    @Test("installedRemoved renders tag whether or not cursor is on the row")
    func installedRemovedTagAlwaysShown() {
        let cursor = PickerDelta.tagString(state: .installedRemoved, isCursor: true, style: plain)
        let offCursor = PickerDelta.tagString(state: .installedRemoved, isCursor: false, style: plain)

        #expect(cursor.contains("installed · WILL REMOVE"))
        #expect(offCursor.contains("installed · WILL REMOVE"))
    }

    @Test("newInstall renders tag whether or not cursor is on the row")
    func newInstallTagAlwaysShown() {
        let cursor = PickerDelta.tagString(state: .newInstall, isCursor: true, style: plain)
        let offCursor = PickerDelta.tagString(state: .newInstall, isCursor: false, style: plain)

        #expect(cursor.contains("new · will install"))
        #expect(offCursor.contains("new · will install"))
    }

    @Test("Cursor installedRemoved uses bright red, off-cursor uses dim red")
    func installedRemovedColors() {
        let cursor = PickerDelta.tagString(state: .installedRemoved, isCursor: true, style: colored)
        let offCursor = PickerDelta.tagString(state: .installedRemoved, isCursor: false, style: colored)

        #expect(cursor.contains("\u{1B}[0;31m"))
        #expect(offCursor.contains("\u{1B}[2;31m"))
    }

    @Test("Cursor newInstall uses bright yellow, off-cursor uses dim yellow")
    func newInstallColors() {
        let cursor = PickerDelta.tagString(state: .newInstall, isCursor: true, style: colored)
        let offCursor = PickerDelta.tagString(state: .newInstall, isCursor: false, style: colored)

        #expect(cursor.contains("\u{1B}[1;33m"))
        #expect(offCursor.contains("\u{1B}[2;33m"))
    }

    @Test("Plain style produces no ANSI codes")
    func tagsPlainWhenColorsOff() {
        for state in [PickerDelta.RowState.installedKept, .installedRemoved, .newInstall, .notInstalled] {
            let tag = PickerDelta.tagString(state: state, isCursor: true, style: plain)
            #expect(!tag.contains("\u{1B}["), "State \(state) leaked ANSI")
        }
    }

    // MARK: - footerVerb

    @Test("footerVerb matches each row state's action")
    func footerVerbs() {
        #expect(PickerDelta.footerVerb(state: .installedKept) == "Space to remove")
        #expect(PickerDelta.footerVerb(state: .installedRemoved) == "Space to keep installed")
        #expect(PickerDelta.footerVerb(state: .newInstall) == "Space to cancel install")
        #expect(PickerDelta.footerVerb(state: .notInstalled) == "Space to install")
    }

    // MARK: - counterString

    @Test("counterString plain output matches golden layout")
    func counterFormat() {
        let rendered = PickerDelta.counterString(additions: 2, removals: 1, unchanged: 3, style: plain)
        #expect(rendered == "+2 to add · -1 to remove · 3 unchanged")
    }

    @Test("counterString emits ANSI when colors enabled")
    func counterColors() {
        let rendered = PickerDelta.counterString(additions: 1, removals: 1, unchanged: 1, style: colored)
        #expect(rendered.contains("\u{1B}[0;32m"))
        #expect(rendered.contains("\u{1B}[0;31m"))
        #expect(rendered.contains("\u{1B}[2m"))
    }

    // MARK: - Locked section rendering

    private func render(
        items: [SelectableItem],
        locked: [String],
        colors: Bool = false
    ) -> String {
        let group = SelectableGroup(
            title: "Packs",
            items: items,
            requiredItems: [],
            showsDelta: true,
            lockedItems: locked
        )
        return CLIOutput(colorsEnabled: colors)
            .buildInteractiveListString(groups: [group], cursor: 0, columns: 100)
    }

    private func item(_ name: String, selected: Bool, global: Bool = false) -> SelectableItem {
        SelectableItem(
            number: 1, name: name, description: "desc",
            isSelected: selected, baselineSelected: selected, globallyInstalled: global
        )
    }

    @Test("Locked packs render in their own section, not as selectable rows")
    func lockedSectionRendered() {
        let out = render(items: [item("backend", selected: false)], locked: ["dev-essentials"])

        #expect(out.contains("Already installed globally"))
        #expect(out.contains("dev-essentials"))
        #expect(out.contains("Manage these with 'mcs sync --global'"))
    }

    @Test("Locked packs use the fact glyph, never the selectable toggle glyphs")
    func lockedUsesCheckNotToggle() {
        let out = render(items: [], locked: ["dev-essentials"])

        // Toggle glyphs would read as a checkbox the user can flip; this row is a
        // statement of fact, which is the whole point of the separate section.
        #expect(out.contains("\u{2713} dev-essentials"))
        #expect(!out.contains("\u{25CF} dev-essentials"))
        #expect(!out.contains("\u{25CB} dev-essentials"))
    }

    @Test("Locked check reuses the green always-included check")
    func lockedCheckIsGreen() {
        let out = render(items: [], locked: ["dev-essentials"], colors: true)
        let greenCheck = "\u{1B}[0;32m\u{2713}"

        #expect(out.contains(greenCheck))
    }

    @Test("No locked section rendered when nothing is locked")
    func noLockedSectionWhenEmpty() {
        let out = render(items: [item("backend", selected: false)], locked: [])

        #expect(!out.contains("Already installed globally"))
    }

    @Test("A both-scope pack stays a selectable row and carries the (global) badge")
    func bothScopePackStaysSelectable() {
        let out = render(items: [item("ios", selected: true, global: true)], locked: [])

        #expect(out.contains("(global)"))
        // Still a real toggle: it is installed here and must remain removable.
        #expect(out.contains("\u{25CF}"))
        #expect(out.contains("installed \u{00B7} uncheck to remove"))
    }

    @Test("Locked names are excluded from the add/remove/unchanged counter")
    func lockedNotCounted() {
        let out = render(items: [item("backend", selected: false)], locked: ["a", "b", "c"])

        #expect(out.contains("+0 to add \u{00B7} -0 to remove \u{00B7} 1 unchanged"))
    }
}
