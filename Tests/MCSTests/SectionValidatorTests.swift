import Foundation
@testable import mcs
import Testing

struct SectionValidatorTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-section-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Parse section markers (via validate)

    @Test("Validate detects up-to-date section when content matches")
    func upToDateSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS instructions
        <!-- mcs:end ios -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["ios": "iOS instructions"]
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].identifier == "ios")
        #expect(result.sections[0].isOutdated == false)
        #expect(!result.hasOutdated)
    }

    // MARK: - Detect outdated sections

    @Test("Validate detects outdated section when content differs")
    func outdatedSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        Old content
        <!-- mcs:end ios -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["ios": "New content"]
        )

        #expect(result.sections.count == 1)
        #expect(result.sections[0].isOutdated == true)
        #expect(result.hasOutdated)
        #expect(result.outdatedSections.count == 1)
    }

    @Test("Validate detects missing expected section")
    func missingSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS only
        <!-- mcs:end ios -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [
                "ios": "iOS only",
                "web": "Web stuff",
            ]
        )

        let webStatus = result.sections.first { $0.identifier == "web" }
        #expect(webStatus != nil)
        #expect(webStatus?.isOutdated == true)
        #expect(webStatus?.detail == "section not found in file")
    }

    // MARK: - Preserve user content outside markers

    @Test("Fix preserves user content outside section markers")
    func fixPreservesUserContent() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        My custom notes
        <!-- mcs:begin ios v1.0.0 -->
        Old iOS content
        <!-- mcs:end ios -->
        More custom notes
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["ios": "Updated iOS content"]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result.contains("My custom notes"))
        #expect(result.contains("More custom notes"))
        #expect(result.contains("Updated iOS content"))
        #expect(!result.contains("Old iOS content"))
    }

    // MARK: - Re-render section preserving surrounding content

    @Test("Fix re-renders outdated section")
    func fixReRendersSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        Stale content
        <!-- mcs:end ios -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["ios": "Fresh content"]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        #expect(result.contains("<!-- mcs:begin ios -->"))
        #expect(result.contains("Fresh content"))
        #expect(result.contains("<!-- mcs:end ios -->"))
        #expect(!result.contains("Stale content"))
    }

    @Test("Fix returns false when nothing is outdated")
    func fixNoOpWhenUpToDate() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        Current content
        <!-- mcs:end ios -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: ["ios": "Current content"]
        )

        #expect(updated == false)
    }

    // MARK: - File with no markers

    @Test("Validate file with no markers returns empty sections")
    func noMarkers() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("plain.md")
        try "Just plain text, no markers".write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [:]
        )

        #expect(result.sections.isEmpty)
        #expect(!result.hasOutdated)
    }

    @Test("Validate nonexistent file returns empty sections")
    func nonexistentFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).md")

        let result = SectionValidator.validate(
            fileURL: missing,
            expectedSections: ["ios": "stuff"]
        )

        #expect(result.sections.isEmpty)
    }

    // MARK: - Multiple sections

    @Test("Validate file with multiple sections")
    func multipleSections() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Web content
        <!-- mcs:end web -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: [
                "ios": "iOS content",
                "web": "Web content",
            ]
        )

        #expect(result.sections.count == 2)
        #expect(!result.hasOutdated)

        let iosStatus = result.sections.first { $0.identifier == "ios" }
        let webStatus = result.sections.first { $0.identifier == "web" }
        #expect(iosStatus?.isOutdated == false)
        #expect(webStatus?.isOutdated == false)
    }

    @Test("Fix updates only outdated section among multiple")
    func fixOnlyOutdatedAmongMultiple() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS content
        <!-- mcs:end ios -->

        <!-- mcs:begin web v1.0.0 -->
        Old Web
        <!-- mcs:end web -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let updated = try SectionValidator.fix(
            fileURL: file,
            expectedSections: [
                "ios": "iOS content",
                "web": "New Web",
            ]
        )

        #expect(updated == true)

        let result = try String(contentsOf: file, encoding: .utf8)
        // iOS unchanged (content matches, so legacy marker preserved)
        #expect(result.contains("iOS content"))
        // Web updated
        #expect(result.contains("<!-- mcs:begin web -->"))
        #expect(result.contains("New Web"))
        #expect(!result.contains("Old Web"))
    }

    // MARK: - Unmanaged sections

    @Test("Unmanaged section in file is reported but not marked outdated")
    func unmanagedSection() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("CLAUDE.local.md")
        let content = """
        <!-- mcs:begin ios v1.0.0 -->
        iOS
        <!-- mcs:end ios -->

        <!-- mcs:begin custom-pack v0.1.0 -->
        Custom stuff
        <!-- mcs:end custom-pack -->
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let result = SectionValidator.validate(
            fileURL: file,
            expectedSections: ["ios": "iOS"]
        )

        #expect(result.sections.count == 2)
        let customStatus = result.sections.first { $0.identifier == "custom-pack" }
        #expect(customStatus?.isOutdated == false)
        #expect(customStatus?.detail == "unmanaged section, skipped")
    }
}
