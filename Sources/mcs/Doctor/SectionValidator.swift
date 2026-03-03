import CryptoKit
import Foundation

/// Validates managed sections in composed template files.
///
/// Parses `<!-- mcs:begin/end -->` section markers, compares each section's
/// content hash against the expected template, and can re-render outdated
/// sections while preserving user content outside markers.
struct SectionValidator: Sendable {
    /// Describes a single section that was checked.
    struct SectionStatus: Sendable {
        let identifier: String
        let isOutdated: Bool
        let detail: String
    }

    /// Result of validating all sections in a file.
    struct ValidationResult: Sendable {
        let filePath: URL
        let sections: [SectionStatus]

        var hasOutdated: Bool {
            sections.contains { $0.isOutdated }
        }

        var outdatedSections: [SectionStatus] {
            sections.filter(\.isOutdated)
        }
    }

    // MARK: - Validation

    /// Validate sections in a composed file against expected templates.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the composed file on disk.
    ///   - expectedSections: Dictionary of section identifier to rendered content.
    /// - Returns: Validation result with per-section status.
    static func validate(
        fileURL: URL,
        expectedSections: [String: String]
    ) -> ValidationResult {
        guard let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ValidationResult(filePath: fileURL, sections: [])
        }

        let installedSections = TemplateComposer.parseSections(from: fileContent)
        var statuses: [SectionStatus] = []

        for installed in installedSections {
            if let expectedContent = expectedSections[installed.identifier] {
                let installedHash = contentHash(installed.content)
                let expectedHash = contentHash(expectedContent)
                let isOutdated = installedHash != expectedHash

                statuses.append(SectionStatus(
                    identifier: installed.identifier,
                    isOutdated: isOutdated,
                    detail: isOutdated ? "content outdated" : "up to date"
                ))
            } else {
                // Section exists in file but has no expected template --
                // could be from an unregistered pack; skip it.
                statuses.append(SectionStatus(
                    identifier: installed.identifier,
                    isOutdated: false,
                    detail: "unmanaged section, skipped"
                ))
            }
        }

        // Check for expected sections that are missing from the file
        for (identifier, _) in expectedSections
            where !installedSections.contains(where: { $0.identifier == identifier }) {
            statuses.append(SectionStatus(
                identifier: identifier,
                isOutdated: true,
                detail: "section not found in file"
            ))
        }

        return ValidationResult(filePath: fileURL, sections: statuses)
    }

    // MARK: - Fix

    /// Re-render outdated managed sections in a composed file.
    ///
    /// Replaces only sections that have a matching expected template.
    /// User content (anything outside section markers) is preserved.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the composed file.
    ///   - expectedSections: Dictionary of section identifier to rendered content.
    /// - Returns: `true` if the file was updated, `false` if no changes were needed or the file could not be read.
    @discardableResult
    static func fix(
        fileURL: URL,
        expectedSections: [String: String]
    ) throws -> Bool {
        guard let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }

        let result = validate(fileURL: fileURL, expectedSections: expectedSections)
        guard result.hasOutdated else { return false }

        var updatedContent = fileContent

        for section in result.outdatedSections {
            guard let expectedContent = expectedSections[section.identifier] else { continue }

            updatedContent = TemplateComposer.replaceSection(
                in: updatedContent,
                sectionIdentifier: section.identifier,
                newContent: expectedContent
            )
        }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Helpers

    /// Compute a SHA-256 hash of a string's content (trimmed of leading/trailing whitespace).
    private static func contentHash(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CLAUDE.md / CLAUDE.local.md freshness check

/// Verifies managed CLAUDE.md sections via content-hash comparison against stored values.
/// Used by both project-scoped (CLAUDE.local.md) and global-scoped (~/.claude/CLAUDE.md)
/// doctor checks — the file path, state source, and display strings are configurable.
struct CLAUDEMDFreshnessCheck: DoctorCheck, Sendable {
    let fileURL: URL
    let stateLoader: @Sendable () throws -> ProjectState
    let registry: TechPackRegistry
    let displayName: String
    let syncHint: String

    var name: String {
        displayName
    }

    var section: String {
        "Templates"
    }

    var fixCommandPreview: String? {
        "re-render outdated sections from stored values"
    }

    private var fileName: String {
        fileURL.lastPathComponent
    }

    func check() -> CheckResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .skip("\(fileName) not found")
        }
        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return .fail("\(fileName) exists but could not be read: \(error.localizedDescription)")
        }

        let sections = TemplateComposer.parseSections(from: content)
        guard !sections.isEmpty else {
            return .warn("\(fileName) has no mcs section markers — run '\(syncHint)'")
        }

        let state: ProjectState
        do {
            state = try stateLoader()
        } catch {
            return .warn("could not read state: \(error.localizedDescription) — run '\(syncHint)' to regenerate")
        }

        guard let storedValues = state.resolvedValues else {
            return .warn("no stored values for verification — run '\(syncHint)'")
        }

        let (expectedSections, buildErrors) = buildExpectedSections(state: state, values: storedValues)

        if !buildErrors.isEmpty {
            return .warn("could not fully verify: \(buildErrors.joined(separator: "; "))")
        }

        let result = SectionValidator.validate(fileURL: fileURL, expectedSections: expectedSections)

        if result.sections.isEmpty, !expectedSections.isEmpty {
            return .fail("could not validate sections — file may have changed during check")
        }

        if result.hasOutdated {
            var lines = ["outdated sections"]
            for section in result.outdatedSections {
                lines.append("  ↳ \(section.identifier) (\(section.detail))")
            }
            lines.append("  run '\(syncHint)' or 'mcs doctor --fix'")
            return .fail(lines.joined(separator: "\n"))
        }

        // Warn about unreplaced placeholders in installed sections
        let unreplacedPlaceholders = Set(sections.flatMap {
            TemplateEngine.findUnreplacedPlaceholders(in: $0.content)
        })
        if !unreplacedPlaceholders.isEmpty {
            var lines = ["unresolved placeholders in \(fileName)"]
            for placeholder in unreplacedPlaceholders.sorted() {
                lines.append("  ↳ \(placeholder)")
            }
            return .warn(lines.joined(separator: "\n"))
        }

        return .pass("all sections up to date (content verified)")
    }

    func fix() -> FixResult {
        let state: ProjectState
        do {
            state = try stateLoader()
        } catch {
            return .failed("could not read state: \(error.localizedDescription)")
        }

        guard let storedValues = state.resolvedValues else {
            return .notFixable("Run '\(syncHint)' to update \(fileName) (no stored values for auto-fix)")
        }

        let (expectedSections, buildErrors) = buildExpectedSections(state: state, values: storedValues)

        if !buildErrors.isEmpty {
            return .failed("could not build expected sections: \(buildErrors.joined(separator: "; "))")
        }

        do {
            let updated = try SectionValidator.fix(fileURL: fileURL, expectedSections: expectedSections)
            if updated {
                return .fixed("re-rendered outdated sections from stored values")
            }
            // SectionValidator.fix returns false both when nothing needs fixing
            // AND when it cannot read the file — distinguish by checking readability.
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                return .failed("\(fileName) became unreadable during fix")
            }
            return .fixed("no changes needed")
        } catch {
            return .failed("could not fix \(fileName): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Build expected sections by re-rendering current pack templates with stored values.
    private func buildExpectedSections(
        state: ProjectState,
        values: [String: String]
    ) -> (sections: [String: String], errors: [String]) {
        var expected: [String: String] = [:]
        var errors: [String] = []

        for packID in state.configuredPacks {
            guard let pack = registry.pack(for: packID) else { continue }
            let templates: [TemplateContribution]
            do {
                templates = try pack.templates
            } catch {
                errors.append("\(packID): failed to load templates — \(error.localizedDescription)")
                continue
            }

            // Only expect sections that were actually written to the file.
            // When user skips sections with unresolved placeholders during
            // global sync, those section IDs are removed from the artifact
            // record's templateSections. If no artifact record exists
            // (backward compat), include all sections.
            let writtenSections = state.artifacts(for: packID)?.templateSections

            for contribution in templates {
                if let writtenSections, !writtenSections.contains(contribution.sectionIdentifier) {
                    continue
                }
                let rendered = TemplateEngine.substitute(
                    template: contribution.templateContent,
                    values: values,
                    emitWarnings: false
                )
                expected[contribution.sectionIdentifier] = rendered
            }
        }

        return (expected, errors)
    }
}
