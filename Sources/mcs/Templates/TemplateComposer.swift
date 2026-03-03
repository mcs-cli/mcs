import Foundation

enum TemplateComposer {
    /// A parsed section from a composed file.
    struct Section {
        let identifier: String // e.g., "ios", "swift"
        let content: String // Content between markers
    }

    // MARK: - Marker generation

    static func beginMarker(identifier: String) -> String {
        "<!-- mcs:begin \(identifier) -->"
    }

    static func endMarker(identifier: String) -> String {
        "<!-- mcs:end \(identifier) -->"
    }

    // MARK: - Composition

    /// Compose a file from tech pack template contributions.
    static func compose(
        contributions: [TemplateContribution],
        values: [String: String] = [:],
        emitWarnings: Bool = true
    ) -> String {
        var parts: [String] = []

        for (index, contribution) in contributions.enumerated() {
            let processedContent = TemplateEngine.substitute(
                template: contribution.templateContent,
                values: values,
                emitWarnings: emitWarnings
            )
            if index > 0 { parts.append("") }
            parts.append(beginMarker(identifier: contribution.sectionIdentifier))
            parts.append(processedContent)
            parts.append(endMarker(identifier: contribution.sectionIdentifier))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Parse sections from an existing composed file.
    static func parseSections(from content: String) -> [Section] {
        var sections: [Section] = []
        let lines = content.components(separatedBy: "\n")

        var currentSection: String?
        var currentContent: [String] = []

        for line in lines {
            if let identifier = parseBeginMarker(line) {
                currentSection = identifier
                currentContent = []
            } else if let identifier = parseEndMarker(line),
                      let section = currentSection,
                      section == identifier {
                sections.append(Section(
                    identifier: section,
                    content: currentContent.joined(separator: "\n")
                ))
                currentSection = nil
                currentContent = []
            } else if currentSection != nil {
                currentContent.append(line)
            }
        }

        return sections
    }

    /// Extract content that is NOT inside any section markers (user content).
    static func extractUserContent(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var userLines: [String] = []
        var inSection = false

        for line in lines {
            if parseBeginMarker(line) != nil {
                inSection = true
            } else if parseEndMarker(line) != nil {
                inSection = false
            } else if !inSection {
                userLines.append(line)
            }
        }

        return userLines.joined(separator: "\n")
    }

    /// Validate that all section markers in the content are properly paired.
    /// Returns identifiers of sections that have a begin marker but no matching end marker.
    static func unpairedSections(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var openSections: [String] = []
        var unpaired: [String] = []

        for line in lines {
            if let identifier = parseBeginMarker(line) {
                // If there was already an open section, it's unpaired
                if let previous = openSections.last {
                    unpaired.append(previous)
                }
                openSections.append(identifier)
            } else if let identifier = parseEndMarker(line) {
                if openSections.last == identifier {
                    openSections.removeLast()
                }
            }
        }

        // Any remaining open sections are unpaired
        unpaired.append(contentsOf: openSections)
        return unpaired
    }

    /// Replace a specific section in an existing composed file.
    /// Preserves all content outside the target section markers.
    ///
    /// If the target section has a begin marker but no matching end marker,
    /// returns the original content unchanged to prevent data loss.
    /// Check `unpairedSections(in:)` to detect this condition beforehand.
    static func replaceSection(
        in existingContent: String,
        sectionIdentifier: String,
        newContent: String
    ) -> String {
        // Safety check: refuse to modify if the target section has an unpaired marker.
        // Without this, a missing end marker would cause all subsequent content to be dropped.
        let unpaired = unpairedSections(in: existingContent)
        if unpaired.contains(sectionIdentifier) {
            return existingContent
        }

        let lines = existingContent.components(separatedBy: "\n")
        var result: [String] = []
        var skipUntilEnd = false
        var replaced = false

        for line in lines {
            if let parsed = parseBeginMarker(line),
               parsed == sectionIdentifier {
                // Replace this section
                result.append(beginMarker(identifier: sectionIdentifier))
                result.append(newContent)
                skipUntilEnd = true
                replaced = true
            } else if let identifier = parseEndMarker(line),
                      identifier == sectionIdentifier {
                result.append(endMarker(identifier: sectionIdentifier))
                skipUntilEnd = false
            } else if !skipUntilEnd {
                result.append(line)
            }
        }

        // If section wasn't found, append it
        if !replaced {
            result.append("")
            result.append(beginMarker(identifier: sectionIdentifier))
            result.append(newContent)
            result.append(endMarker(identifier: sectionIdentifier))
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Compose or update

    /// Result of composing or updating CLAUDE.local.md content.
    struct ComposeResult {
        let content: String
        let warnings: [String]
    }

    /// Pure compose-or-update decision: produces final content from contributions
    /// without performing any file I/O.
    ///
    /// - If `existingContent` is nil or has no section markers, produces a fresh compose.
    /// - If `existingContent` has markers, updates each section in place preserving user content.
    static func composeOrUpdate(
        existingContent: String?,
        contributions: [TemplateContribution],
        values: [String: String],
        emitWarnings: Bool = true
    ) -> ComposeResult {
        let hasMarkers = existingContent.map { !parseSections(from: $0).isEmpty } ?? false

        guard let existingContent, hasMarkers else {
            return freshCompose(contributions: contributions, values: values, emitWarnings: emitWarnings)
        }

        return updateExisting(
            existingContent: existingContent,
            contributions: contributions,
            values: values,
            emitWarnings: emitWarnings
        )
    }

    /// Build a fresh composed file from contributions.
    private static func freshCompose(
        contributions: [TemplateContribution],
        values: [String: String],
        emitWarnings: Bool = true
    ) -> ComposeResult {
        let composed = compose(
            contributions: contributions,
            values: values,
            emitWarnings: emitWarnings
        )
        return ComposeResult(content: composed, warnings: [])
    }

    /// Update an existing file that has section markers, preserving user content.
    private static func updateExisting(
        existingContent: String,
        contributions: [TemplateContribution],
        values: [String: String],
        emitWarnings: Bool = true
    ) -> ComposeResult {
        var warnings: [String] = []

        let unpaired = unpairedSections(in: existingContent)
        if !unpaired.isEmpty {
            warnings.append("Unpaired section markers: \(unpaired.joined(separator: ", "))")
            warnings.append("Sections with missing end markers will not be updated to prevent data loss.")
            warnings.append("Add the missing end markers manually, then re-run sync.")
        }

        let userContent = extractUserContent(from: existingContent)

        var updated = existingContent
        for contribution in contributions {
            let processedContent = TemplateEngine.substitute(
                template: contribution.templateContent,
                values: values,
                emitWarnings: emitWarnings
            )
            updated = replaceSection(
                in: updated,
                sectionIdentifier: contribution.sectionIdentifier,
                newContent: processedContent
            )
        }

        let trimmedUser = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUser.isEmpty {
            let currentUser = extractUserContent(from: updated)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentUser.isEmpty {
                updated += "\n\n" + trimmedUser + "\n"
            }
        }

        return ComposeResult(content: updated, warnings: warnings)
    }

    // MARK: - Section removal

    /// Remove a section identified by its begin/end markers from the content.
    /// Cleans up surrounding blank lines left by the removal.
    /// Returns the original content unchanged if the section is not found.
    static func removeSection(
        in existingContent: String,
        sectionIdentifier: String
    ) -> String {
        let lines = existingContent.components(separatedBy: "\n")
        var result: [String] = []
        var skipUntilEnd = false
        var found = false

        for line in lines {
            if let parsed = parseBeginMarker(line),
               parsed == sectionIdentifier {
                skipUntilEnd = true
                found = true
                // Also skip a preceding blank line if we left one
                if let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.removeLast()
                }
            } else if let identifier = parseEndMarker(line),
                      identifier == sectionIdentifier {
                skipUntilEnd = false
            } else if !skipUntilEnd {
                result.append(line)
            }
        }

        guard found else { return existingContent }

        // Clean up leading blank lines left at the top
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeFirst()
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Parse a begin marker, accepting both new and legacy formats:
    /// - New: `<!-- mcs:begin identifier -->`
    /// - Legacy: `<!-- mcs:begin identifier vX.Y.Z -->`
    private static func parseBeginMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!-- mcs:begin "),
              trimmed.hasSuffix(" -->") else { return nil }
        let inner = trimmed
            .dropFirst("<!-- mcs:begin ".count)
            .dropLast(" -->".count)
        let parts = inner.split(separator: " ", maxSplits: 1)
        guard !parts.isEmpty else { return nil }
        return String(parts[0])
    }

    private static func parseEndMarker(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Match: <!-- mcs:end identifier -->
        guard trimmed.hasPrefix("<!-- mcs:end "),
              trimmed.hasSuffix(" -->") else { return nil }
        let identifier = trimmed
            .dropFirst("<!-- mcs:end ".count)
            .dropLast(" -->".count)
        return String(identifier)
    }
}
