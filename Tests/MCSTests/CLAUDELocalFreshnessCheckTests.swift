import Foundation
@testable import mcs
import Testing

struct CLAUDEMDFreshnessCheckTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-freshness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a CLAUDE.local.md file with section markers and content.
    private func writeClaudeLocal(at projectRoot: URL, sections: [(id: String, content: String)]) throws {
        var lines: [String] = []
        for section in sections {
            lines.append("<!-- mcs:begin \(section.id) -->")
            lines.append(section.content)
            lines.append("<!-- mcs:end \(section.id) -->")
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        try content.write(
            to: projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Create a ProjectState with configured packs and resolved values, then save it.
    private func writeProjectState(
        at projectRoot: URL,
        packs: [String],
        resolvedValues: [String: String]? = nil,
        artifacts: [String: PackArtifactRecord]? = nil
    ) throws {
        var state = try ProjectState(projectRoot: projectRoot)
        for pack in packs {
            state.recordPack(pack)
        }
        if let values = resolvedValues {
            state.setResolvedValues(values)
        }
        if let artifacts {
            for (packID, record) in artifacts {
                state.setArtifacts(record, for: packID)
            }
        }
        try state.save()
    }

    /// Build a fake registry with packs that have the given template contributions.
    private func makeRegistry(packs: [(id: String, templates: [TemplateContribution])]) -> TechPackRegistry {
        let fakePacks: [any TechPack] = packs.map { pack in
            StubTechPack(identifier: pack.id, templates: pack.templates)
        }
        return TechPackRegistry(packs: fakePacks)
    }

    /// Build a CLAUDEMDFreshnessCheck configured for project-scoped CLAUDE.local.md.
    private func makeProjectCheck(projectRoot: URL, registry: TechPackRegistry) -> CLAUDEMDFreshnessCheck {
        CLAUDEMDFreshnessCheck(
            fileURL: projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: projectRoot) },
            registry: registry,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )
    }

    // MARK: - Content matches (pass)

    @Test("Content matches stored values — pass")
    func contentMatches() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]
        let rendered = TemplateEngine.substitute(template: templateContent, values: resolvedValues)

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: rendered),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .pass(msg) = result {
            #expect(msg.contains("content verified"))
        } else {
            Issue.record("Expected pass but got \(result)")
        }
    }

    // MARK: - Content drifted (fail)

    @Test("Content manually edited — fail with drift detection")
    func contentDrifted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]

        // Write CLAUDE.local.md with manually-modified content
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Hello World — I edited this!"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("outdated sections"))
        } else {
            Issue.record("Expected fail but got \(result)")
        }
    }

    // MARK: - No resolvedValues (warns to run sync)

    @Test("State without resolvedValues — warns to run sync")
    func noResolvedValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Some content"),
        ])
        // Save state WITHOUT resolved values
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: "Different template", placeholders: []),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("no stored values"))
        } else {
            Issue.record("Expected .warn but got \(result)")
        }
    }

    // MARK: - No CLAUDE.local.md file (skip)

    @Test("No CLAUDE.local.md — skip")
    func noFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .skip(msg) = result {
            #expect(msg.contains("not found"))
        } else {
            Issue.record("Expected skip but got \(result)")
        }
    }

    // MARK: - Fix re-renders drifted content

    @Test("Fix re-renders drifted content from stored values")
    func fixReRenders() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateContent = "Hello __NAME__"
        let resolvedValues = ["NAME": "World"]

        // Write drifted content
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Hello World — tampered!"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let fixResult = check.fix()
        if case let .fixed(msg) = fixResult {
            #expect(msg.contains("re-rendered"))
        } else {
            Issue.record("Expected fixed but got \(fixResult)")
        }

        // Verify the file was restored
        let fileContent = try String(
            contentsOf: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            encoding: .utf8
        )
        #expect(fileContent.contains("Hello World"))
        #expect(!fileContent.contains("tampered"))
    }

    // MARK: - Missing pack in registry

    @Test("Pack removed from registry — section reported as unmanaged, still passes")
    func missingPack() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolvedValues = ["NAME": "World"]

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "removed-pack", content: "Hello World"),
        ])
        try writeProjectState(at: tmpDir, packs: ["removed-pack"], resolvedValues: resolvedValues)

        // Empty registry — pack no longer exists
        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        // With no expected sections, SectionValidator marks them as unmanaged (not outdated) → passes
        if case let .pass(msg) = result {
            #expect(msg.contains("content verified"))
        } else {
            Issue.record("Expected pass but got \(result)")
        }
    }

    // MARK: - resolvedValues round-trip

    @Test("ProjectState save/load preserves resolvedValues")
    func resolvedValuesRoundTrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let values = ["PROJECT": "MyApp", "REPO": "my-repo", "CUSTOM_KEY": "custom-value"]

        var state = try ProjectState(projectRoot: tmpDir)
        state.recordPack("test-pack")
        state.setResolvedValues(values)
        try state.save()

        // Reload from disk
        let loaded = try ProjectState(projectRoot: tmpDir)
        #expect(loaded.resolvedValues == values)
        #expect(loaded.configuredPacks.contains("test-pack"))
    }

    // MARK: - Outdated markers without stored values

    @Test("Outdated version markers without stored values — warns to run sync")
    func outdatedMarkersNoStoredValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Old content"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: "New template", placeholders: []),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("no stored values"))
        } else {
            Issue.record("Expected warn but got \(result)")
        }
    }

    // MARK: - Fix not fixable without stored values

    @Test("Fix without stored values — not fixable")
    func fixNotFixableWithoutValues() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Old content"),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: nil)

        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let fixResult = check.fix()
        if case let .notFixable(msg) = fixResult {
            #expect(msg.contains("no stored values"))
        } else {
            Issue.record("Expected notFixable but got \(fixResult)")
        }
    }

    // MARK: - Multiple sections with partial drift

    @Test("Multiple sections — only drifted one is reported")
    func partialDrift() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolvedValues = ["NAME": "World"]
        let goodRendered = TemplateEngine.substitute(template: "Hello __NAME__", values: resolvedValues)

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "pack-a", content: goodRendered),
            (id: "pack-b", content: "This was tampered"),
        ])
        try writeProjectState(at: tmpDir, packs: ["pack-a", "pack-b"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "pack-a", templates: [
                TemplateContribution(sectionIdentifier: "pack-a", templateContent: "Hello __NAME__", placeholders: ["__NAME__"]),
            ]),
            (id: "pack-b", templates: [
                TemplateContribution(sectionIdentifier: "pack-b", templateContent: "Original content", placeholders: []),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("pack-b"))
            #expect(!msg.contains("pack-a"))
        } else {
            Issue.record("Expected fail but got \(result)")
        }
    }

    // MARK: - Template loading error surfaced

    @Test("Pack with throwing templates — warns instead of silent skip")
    func templateLoadingError() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolvedValues = ["NAME": "World"]
        let rendered = TemplateEngine.substitute(template: "Hello __NAME__", values: resolvedValues)

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "good-pack", content: rendered),
            (id: "bad-pack", content: "Some content"),
        ])
        try writeProjectState(at: tmpDir, packs: ["good-pack", "bad-pack"], resolvedValues: resolvedValues)

        let goodPack = StubTechPack(
            identifier: "good-pack",
            templates: [TemplateContribution(sectionIdentifier: "good-pack", templateContent: "Hello __NAME__", placeholders: ["__NAME__"])]
        )
        let badPack = ThrowingTechPack(identifier: "bad-pack")
        let registry = TechPackRegistry(packs: [goodPack, badPack])

        let check = CLAUDEMDFreshnessCheck(
            fileURL: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD),
            stateLoader: { try ProjectState(projectRoot: tmpDir) },
            registry: registry,
            displayName: "CLAUDE.local.md freshness",
            syncHint: "mcs sync"
        )

        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("bad-pack"))
            #expect(msg.contains("could not fully verify"))
        } else {
            Issue.record("Expected warn but got \(result)")
        }
    }

    // MARK: - Outdated sections multi-line format

    @Test("Outdated sections message uses multi-line format with indentation")
    func outdatedSectionsFormat() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resolvedValues = ["NAME": "World"]

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "pack-a", content: "Tampered A"),
            (id: "pack-b", content: "Tampered B"),
        ])
        try writeProjectState(at: tmpDir, packs: ["pack-a", "pack-b"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "pack-a", templates: [
                TemplateContribution(sectionIdentifier: "pack-a", templateContent: "Original A", placeholders: []),
            ]),
            (id: "pack-b", templates: [
                TemplateContribution(sectionIdentifier: "pack-b", templateContent: "Original B", placeholders: []),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .fail(msg) = result {
            // Each section appears on its own indented line
            #expect(msg.contains("↳ pack-a"))
            #expect(msg.contains("↳ pack-b"))
            // Hint appears on its own line
            #expect(msg.contains("run 'mcs sync' or 'mcs doctor --fix'"))
            // Multi-line format uses newlines
            #expect(msg.contains("\n"))
        } else {
            Issue.record("Expected fail but got \(result)")
        }
    }

    // MARK: - fixCommandPreview

    @Test("fixCommandPreview returns a descriptive string")
    func fixCommandPreviewIsSet() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)
        #expect(check.fixCommandPreview != nil)
    }

    // MARK: - Unreplaced placeholders warn

    @Test("Sections up to date but with unreplaced placeholders — warns")
    func unreplacedPlaceholdersWarn() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Template has __REPO_NAME__ with no value provided
        let templateContent = "Project: __REPO_NAME__"
        let resolvedValues: [String: String] = [:]
        let rendered = TemplateEngine.substitute(
            template: templateContent,
            values: resolvedValues,
            emitWarnings: false
        )
        // rendered = "Project: __REPO_NAME__" (unreplaced)

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: rendered),
        ])
        try writeProjectState(at: tmpDir, packs: ["test-pack"], resolvedValues: resolvedValues)

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack", templateContent: templateContent, placeholders: ["__REPO_NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("unresolved placeholders"))
            #expect(msg.contains("__REPO_NAME__"))
        } else {
            Issue.record("Expected warn but got \(result)")
        }
    }

    // MARK: - Corrupt state file

    // MARK: - Skipped sections (global placeholder skip)

    @Test("Skipped sections are not reported as missing when artifact record excludes them")
    func skippedSectionsNotReportedAsMissing() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateA = "Section A content"
        let templateB = "Section B with __REPO_NAME__"
        let resolvedValues: [String: String] = [:]

        // Only section-a was written (user skipped section-b due to unresolved placeholder)
        let renderedA = TemplateEngine.substitute(template: templateA, values: resolvedValues, emitWarnings: false)
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack.section-a", content: renderedA),
        ])

        // Artifact record tracks only section-a (section-b was skipped)
        try writeProjectState(
            at: tmpDir,
            packs: ["test-pack"],
            resolvedValues: resolvedValues,
            artifacts: ["test-pack": PackArtifactRecord(templateSections: ["test-pack.section-a"])]
        )

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack.section-a", templateContent: templateA, placeholders: []),
                TemplateContribution(sectionIdentifier: "test-pack.section-b", templateContent: templateB, placeholders: ["__REPO_NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .pass(msg) = result {
            #expect(msg.contains("content verified"))
        } else {
            Issue.record("Expected pass but got \(result)")
        }
    }

    @Test("Fix does not add back skipped sections")
    func fixDoesNotAddSkippedSections() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templateA = "Section A __NAME__"
        let templateB = "Section B with __REPO_NAME__"
        let resolvedValues = ["NAME": "World"]

        // Write section-a with drifted content to trigger a fix
        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack.section-a", content: "Tampered content"),
        ])

        // Artifact record tracks only section-a
        try writeProjectState(
            at: tmpDir,
            packs: ["test-pack"],
            resolvedValues: resolvedValues,
            artifacts: ["test-pack": PackArtifactRecord(templateSections: ["test-pack.section-a"])]
        )

        let registry = makeRegistry(packs: [
            (id: "test-pack", templates: [
                TemplateContribution(sectionIdentifier: "test-pack.section-a", templateContent: templateA, placeholders: ["__NAME__"]),
                TemplateContribution(sectionIdentifier: "test-pack.section-b", templateContent: templateB, placeholders: ["__REPO_NAME__"]),
            ]),
        ])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let fixResult = check.fix()
        if case .fixed = fixResult {
            // Verify section-b was NOT added to the file
            let content = try String(contentsOf: tmpDir.appendingPathComponent(Constants.FileNames.claudeLocalMD), encoding: .utf8)
            #expect(!content.contains("section-b"))
            #expect(!content.contains("__REPO_NAME__"))
            // Verify section-a was fixed
            #expect(content.contains("Section A World"))
        } else {
            Issue.record("Expected fixed but got \(fixResult)")
        }
    }

    // MARK: - Corrupt state file

    @Test("Corrupt state — check warns with descriptive message")
    func corruptStateFileCheck() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Some content"),
        ])

        // Write corrupt (non-JSON) data to .mcs-project
        let claudeDir = tmpDir.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(Constants.FileNames.mcsProject)
        try "{corrupt json!!!}".write(to: stateFile, atomically: true, encoding: .utf8)

        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("could not read state"))
        } else {
            Issue.record("Expected warn but got \(result)")
        }
    }

    @Test("Corrupt state — fix fails instead of misdiagnosing as 'never synced'")
    func corruptStateFileFix() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try writeClaudeLocal(at: tmpDir, sections: [
            (id: "test-pack", content: "Some content"),
        ])

        let claudeDir = tmpDir.appendingPathComponent(Constants.FileNames.claudeDirectory)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let stateFile = claudeDir.appendingPathComponent(Constants.FileNames.mcsProject)
        try "{corrupt json!!!}".write(to: stateFile, atomically: true, encoding: .utf8)

        let registry = makeRegistry(packs: [])
        let check = makeProjectCheck(projectRoot: tmpDir, registry: registry)

        let fixResult = check.fix()
        if case let .failed(msg) = fixResult {
            #expect(msg.contains("could not read state"))
        } else {
            Issue.record("Expected failed but got \(fixResult)")
        }
    }
}

// MARK: - Test doubles

private struct StubTechPack: TechPack {
    let identifier: String
    let displayName: String = "Stub Pack"
    let description: String = "A stub pack for testing"
    let components: [ComponentDefinition] = []
    let templates: [TemplateContribution]

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}

private struct ThrowingTechPack: TechPack {
    let identifier: String
    let displayName: String = "Throwing Pack"
    let description: String = "A pack whose templates throw"
    let components: [ComponentDefinition] = []
    var templates: [TemplateContribution] {
        get throws { throw TestError.templateLoadFailed }
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        []
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}

    private enum TestError: Error, LocalizedError {
        case templateLoadFailed
        var errorDescription: String? {
            "simulated template load failure"
        }
    }
}
