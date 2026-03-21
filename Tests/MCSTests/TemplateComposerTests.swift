import Foundation
@testable import mcs
import Testing

struct TemplateComposerTests {
    // MARK: - Composition

    @Test("Compose single contribution")
    func composeSingleContribution() {
        let contribution = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "iOS instructions here",
            placeholders: []
        )

        let result = TemplateComposer.compose(contributions: [contribution])

        #expect(result.contains("<!-- mcs:begin ios -->"))
        #expect(result.contains("iOS instructions here"))
        #expect(result.contains("<!-- mcs:end ios -->"))
    }

    @Test("Compose multiple contributions")
    func composeMultipleContributions() {
        let ios = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "iOS content",
            placeholders: []
        )
        let web = TemplateContribution(
            sectionIdentifier: "web",
            templateContent: "Web-specific content for __PROJECT__",
            placeholders: ["__PROJECT__"]
        )

        let result = TemplateComposer.compose(
            contributions: [ios, web],
            values: ["PROJECT": "MyApp"]
        )

        #expect(result.contains("<!-- mcs:begin ios -->"))
        #expect(result.contains("iOS content"))
        #expect(result.contains("<!-- mcs:end ios -->"))
        #expect(result.contains("<!-- mcs:begin web -->"))
        #expect(result.contains("Web-specific content for MyApp"))
        #expect(result.contains("<!-- mcs:end web -->"))
    }

    @Test("Compose applies template substitution")
    func composeSubstitutes() {
        let contribution = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "Repo: __REPO_NAME__",
            placeholders: ["__REPO_NAME__"]
        )

        let result = TemplateComposer.compose(
            contributions: [contribution],
            values: ["REPO_NAME": "my-repo"]
        )

        #expect(result.contains("Repo: my-repo"))
    }

    // MARK: - Parsing

    @Test("Parse sections from composed file")
    func parseSections() {
        let content = """
        <!-- mcs:begin ios -->
        iOS stuff
        <!-- mcs:end ios -->

        <!-- mcs:begin web -->
        Web stuff
        <!-- mcs:end web -->
        """

        let sections = TemplateComposer.parseSections(from: content)

        #expect(sections.count == 2)
        #expect(sections[0].identifier == "ios")
        #expect(sections[0].content == "iOS stuff")
        #expect(sections[1].identifier == "web")
        #expect(sections[1].content == "Web stuff")
    }

    @Test("Parse sections handles legacy markers with version token")
    func parseSectionsLegacyFormat() {
        let content = """
        <!-- mcs:begin ios v3.2.1 -->
        Content
        <!-- mcs:end ios -->
        """
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "ios")
        #expect(sections[0].content == "Content")
    }

    // MARK: - User content extraction

    @Test("Extract user content outside markers")
    func extractUserContent() {
        let content = """
        User notes at top
        <!-- mcs:begin ios v1.0.0 -->
        Managed content
        <!-- mcs:end ios -->
        User notes at bottom
        """

        let userContent = TemplateComposer.extractUserContent(from: content)

        #expect(userContent.contains("User notes at top"))
        #expect(userContent.contains("User notes at bottom"))
        #expect(!userContent.contains("Managed content"))
    }

    @Test("File with no markers returns all content as user content")
    func noMarkersAllUserContent() {
        let content = "Just some user text\nSecond line"
        let userContent = TemplateComposer.extractUserContent(from: content)
        #expect(userContent == content)
    }

    @Test("File with no markers returns empty sections")
    func noMarkersSections() {
        let content = "No markers here"
        let sections = TemplateComposer.parseSections(from: content)
        #expect(sections.isEmpty)
    }

    // MARK: - Section replacement

    @Test("Replace specific section preserving others")
    func replaceSection() {
        let original = """
        <!-- mcs:begin ios v1.0.0 -->
        Old iOS
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Old Web
        <!-- mcs:end web -->
        """

        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "ios",
            newContent: "New iOS"
        )

        #expect(result.contains("<!-- mcs:begin ios -->"))
        #expect(result.contains("New iOS"))
        #expect(result.contains("<!-- mcs:end ios -->"))
        // Web section preserved (legacy markers remain as-is until replaced)
        #expect(result.contains("Old Web"))
        #expect(result.contains("<!-- mcs:end web -->"))
        // Old iOS replaced
        #expect(!result.contains("Old iOS"))
    }

    @Test("Replace appends section if not found")
    func replaceSectionAppends() {
        let original = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->
        """

        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "android",
            newContent: "Android content"
        )

        #expect(result.contains("<!-- mcs:begin android -->"))
        #expect(result.contains("Android content"))
        #expect(result.contains("<!-- mcs:end android -->"))
        // Original preserved
        #expect(result.contains("iOS content"))
    }

    // MARK: - Unpaired marker detection

    @Test("Detect unpaired begin marker with missing end marker")
    func unpairedBeginMarker() {
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS stuff
        """
        let unpaired = TemplateComposer.unpairedSections(in: content)
        #expect(unpaired == ["ios"])
    }

    @Test("No unpaired markers in well-formed content")
    func noPairedMarkers() {
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS stuff
        <!-- mcs:end ios -->
        """
        let unpaired = TemplateComposer.unpairedSections(in: content)
        #expect(unpaired.isEmpty)
    }

    @Test("replaceSection preserves content when target section has unpaired marker")
    func replaceSectionUnpairedSafety() {
        let original = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS stuff
        User content below
        """
        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "ios",
            newContent: "New iOS"
        )
        // Should return original unchanged to prevent data loss
        #expect(result == original)
    }

    @Test("replaceSection works normally when a different section is unpaired")
    func replaceSectionOtherUnpaired() {
        let original = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS stuff
        <!-- mcs:end ios -->
        <!-- mcs:begin web v1.0.0 -->
        Web stuff without end marker
        """
        let result = TemplateComposer.replaceSection(
            in: original,
            sectionIdentifier: "ios",
            newContent: "New iOS"
        )
        // iOS section should be replaced (it's well-formed)
        #expect(result.contains("New iOS"))
        #expect(!result.contains("iOS stuff"))
        // Web section preserved as-is (not the target)
        #expect(result.contains("Web stuff without end marker"))
    }

    // MARK: - Section removal

    @Test("Remove a section from composed content")
    func removeSection() {
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Web content
        <!-- mcs:end web -->

        <!-- mcs:begin android v1.0.0 -->
        Android content
        <!-- mcs:end android -->
        """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "web"
        )

        #expect(!result.contains("Web content"))
        #expect(!result.contains("mcs:begin web"))
        #expect(!result.contains("mcs:end web"))
        // Others preserved
        #expect(result.contains("iOS content"))
        #expect(result.contains("Android content"))
    }

    @Test("Remove nonexistent section returns original")
    func removeSectionNotFound() {
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->
        """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "nonexistent"
        )

        #expect(result == content)
    }

    @Test("Remove last section returns clean content")
    func removeLastSection() {
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->
        """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "ios"
        )

        #expect(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Remove section preserves user content outside markers")
    func removeSectionPreservesUserContent() {
        let content = """
        User notes at top
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Web content
        <!-- mcs:end web -->
        User notes at bottom
        """

        let result = TemplateComposer.removeSection(
            in: content,
            sectionIdentifier: "web"
        )

        #expect(result.contains("User notes at top"))
        #expect(result.contains("iOS content"))
        #expect(result.contains("User notes at bottom"))
        #expect(!result.contains("Web content"))
    }

    // MARK: - Round-trip

    @Test("Compose then parse round-trip preserves content")
    func composeParseRoundTrip() {
        let ios = TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: "iOS rules",
            placeholders: []
        )
        let web = TemplateContribution(
            sectionIdentifier: "web",
            templateContent: "Web rules",
            placeholders: []
        )

        let composed = TemplateComposer.compose(contributions: [ios, web])

        let sections = TemplateComposer.parseSections(from: composed)
        #expect(sections.count == 2)
        #expect(sections[0].identifier == "ios")
        #expect(sections[0].content == "iOS rules")
        #expect(sections[1].identifier == "web")
        #expect(sections[1].content == "Web rules")
    }
}

// MARK: - composeOrUpdate

struct ComposeOrUpdateTests {
    private func packContribution(
        _ id: String,
        _ content: String,
        placeholders: [String] = []
    ) -> TemplateContribution {
        TemplateContribution(
            sectionIdentifier: id,
            templateContent: content,
            placeholders: placeholders
        )
    }

    @Test("Fresh compose when no existing content")
    func freshCompose() {
        let result = TemplateComposer.composeOrUpdate(
            existingContent: nil,
            contributions: [packContribution("ios", "iOS rules")],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "ios")
        #expect(sections[0].content == "iOS rules")
        #expect(result.warnings.isEmpty)
    }

    @Test("v1 content without markers produces fresh compose")
    func v1MigrationCompose() {
        let result = TemplateComposer.composeOrUpdate(
            existingContent: "Old v1 content without any markers",
            contributions: [packContribution("ios", "New iOS")],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].identifier == "ios")
        #expect(sections[0].content == "New iOS")
        #expect(!result.content.contains("Old v1 content"))
        #expect(result.warnings.isEmpty)
    }

    @Test("v2 content with markers is updated in place")
    func v2Update() {
        let existing = TemplateComposer.compose(
            contributions: [packContribution("ios", "Old iOS")]
        )

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [packContribution("ios", "Updated iOS")],
            values: [:]
        )

        let sections = TemplateComposer.parseSections(from: result.content)
        #expect(sections.count == 1)
        #expect(sections[0].content == "Updated iOS")
        #expect(!result.content.contains("Old iOS"))
        #expect(result.warnings.isEmpty)
    }

    @Test("v2 update preserves user content outside markers")
    func v2UpdatePreservesUserContent() {
        let existing = TemplateComposer.compose(
            contributions: [packContribution("ios", "iOS")]
        ) + "\n\nMy custom notes\n"

        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [packContribution("ios", "New iOS")],
            values: [:]
        )

        #expect(result.content.contains("New iOS"))
        #expect(result.content.contains("My custom notes"))
        #expect(result.warnings.isEmpty)
    }

    @Test("Template values are substituted during compose")
    func valuesSubstituted() {
        let ios = packContribution("ios", "iOS rules for __PROJECT__", placeholders: ["__PROJECT__"])

        let result = TemplateComposer.composeOrUpdate(
            existingContent: nil,
            contributions: [ios],
            values: ["PROJECT": "MyApp.xcodeproj"]
        )

        #expect(result.content.contains("MyApp.xcodeproj"))
        #expect(!result.content.contains("__PROJECT__"))
    }

    @Test("Unpaired markers produce warnings and leave damaged section unchanged")
    func unpairedMarkersWarn() {
        let existing = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS rules
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Web rules without end marker
        """

        let web = packContribution("web", "Updated Web")
        let result = TemplateComposer.composeOrUpdate(
            existingContent: existing,
            contributions: [packContribution("ios", "New iOS"), web],
            values: [:]
        )

        #expect(result.warnings.count == 3)
        #expect(result.warnings[0].contains("Unpaired section markers"))
        // The unpaired "web" section is left unchanged by replaceSection's safety check
        #expect(result.content.contains("Web rules without end marker"))
    }
}
