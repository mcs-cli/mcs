import Foundation
@testable import mcs
import Testing

struct PackDiffTests {
    // MARK: - Builders

    private func hookComponent(
        id: String,
        description: String = "A hook",
        source: String = "hooks/lint.sh",
        destination: String = "lint.sh"
    ) -> ExternalComponentDefinition {
        ExternalComponentDefinition(
            id: id,
            displayName: id,
            description: description,
            type: .hookFile,
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: source, destination: destination, fileType: .hook
            ))
        )
    }

    private func brewComponent(id: String, package: String = "jq") -> ExternalComponentDefinition {
        ExternalComponentDefinition(
            id: id,
            displayName: id,
            description: "A brew package",
            type: .brewPackage,
            installAction: .brewInstall(package: package)
        )
    }

    /// `ExternalDoctorCheckDefinition`'s `let` optionals get no defaults in the synthesized
    /// memberwise init, so spell the unused ones out once here rather than at each call site.
    private func commandCheck(name: String, command: String) -> ExternalDoctorCheckDefinition {
        ExternalDoctorCheckDefinition(
            type: .commandExists,
            name: name,
            section: nil,
            command: command,
            args: nil,
            path: nil,
            pattern: nil,
            scope: nil,
            fixCommand: nil,
            fixScript: nil,
            event: nil,
            keyPath: nil,
            expectedValue: nil,
            isOptional: nil
        )
    }

    private func inputPrompt(key: String, label: String = "Enter a value") -> PromptDefinition {
        PromptDefinition(
            key: key,
            type: .input,
            label: label,
            defaultValue: nil,
            options: nil,
            detectPatterns: nil,
            scriptCommand: nil
        )
    }

    private func manifest(
        components: [ExternalComponentDefinition]? = nil,
        templates: [ExternalTemplateDefinition]? = nil,
        prompts: [PromptDefinition]? = nil,
        configureProject: ExternalConfigureProject? = nil,
        supplementaryDoctorChecks: [ExternalDoctorCheckDefinition]? = nil
    ) -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: components,
            templates: templates,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks,
            ignore: nil
        )
    }

    private func snapshot(
        _ manifest: ExternalPackManifest,
        fileHashes: [String: String] = [:]
    ) -> PackSnapshot {
        PackSnapshot(manifest: manifest, fileHashes: fileHashes)
    }

    private let plainStyle = ANSIStyle(enabled: false)

    // MARK: - Components

    @Test("Component present only in the new manifest is added")
    func componentAdded() {
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [hookComponent(id: "test-pack.lint")])),
            new: snapshot(manifest(components: [
                hookComponent(id: "test-pack.lint"),
                brewComponent(id: "test-pack.jq"),
            ]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .component, name: "test-pack.jq", change: .added),
        ])
    }

    @Test("Component present only in the old manifest is removed")
    func componentRemoved() {
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [
                hookComponent(id: "test-pack.lint"),
                brewComponent(id: "test-pack.jq"),
            ])),
            new: snapshot(manifest(components: [hookComponent(id: "test-pack.lint")]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .component, name: "test-pack.jq", change: .removed),
        ])
    }

    @Test("Changed declaration reports modified with no file path")
    func componentDeclarationModified() {
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [brewComponent(id: "test-pack.jq", package: "jq")])),
            new: snapshot(manifest(components: [brewComponent(id: "test-pack.jq", package: "yq")]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .component, name: "test-pack.jq", change: .modified(path: nil)),
        ])
    }

    @Test("Unchanged declaration with changed file content reports the file path")
    func componentFileContentModified() {
        let component = hookComponent(id: "test-pack.lint", source: "hooks/lint.sh")
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [component]), fileHashes: ["hooks/lint.sh": "aaa"]),
            new: snapshot(manifest(components: [component]), fileHashes: ["hooks/lint.sh": "bbb"])
        )

        #expect(diff.entries == [
            PackDiff.Entry(
                kind: .component, name: "test-pack.lint",
                change: .modified(path: "hooks/lint.sh")
            ),
        ])
    }

    @Test("Declaration change wins over file change — one entry, no file path")
    func declarationChangeTakesPrecedenceOverFileChange() {
        let diff = PackDiff.between(
            old: snapshot(
                manifest(components: [hookComponent(id: "test-pack.lint", description: "old")]),
                fileHashes: ["hooks/lint.sh": "aaa"]
            ),
            new: snapshot(
                manifest(components: [hookComponent(id: "test-pack.lint", description: "new")]),
                fileHashes: ["hooks/lint.sh": "bbb"]
            )
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .component, name: "test-pack.lint", change: .modified(path: nil)),
        ])
    }

    @Test("A file appearing where none was hashed before counts as changed")
    func missingFileHashCountsAsChange() {
        let component = hookComponent(id: "test-pack.lint", source: "hooks/lint.sh")
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [component])),
            new: snapshot(manifest(components: [component]), fileHashes: ["hooks/lint.sh": "bbb"])
        )

        #expect(diff.entries == [
            PackDiff.Entry(
                kind: .component, name: "test-pack.lint",
                change: .modified(path: "hooks/lint.sh")
            ),
        ])
    }

    @Test("Component that references no file is never reported via file hashes")
    func nonCopyingComponentIgnoresFileHashes() {
        let component = brewComponent(id: "test-pack.jq")
        let diff = PackDiff.between(
            old: snapshot(manifest(components: [component]), fileHashes: ["hooks/lint.sh": "aaa"]),
            new: snapshot(manifest(components: [component]), fileHashes: ["hooks/lint.sh": "bbb"])
        )

        #expect(diff.isEmpty)
    }

    // MARK: - Templates and doctor checks

    @Test("Template content change is attributed to its section")
    func templateContentModified() {
        let template = ExternalTemplateDefinition(
            sectionIdentifier: "test-pack.main",
            placeholders: nil,
            contentFile: "templates/main.md",
            dependencies: nil
        )
        let diff = PackDiff.between(
            old: snapshot(manifest(templates: [template]), fileHashes: ["templates/main.md": "aaa"]),
            new: snapshot(manifest(templates: [template]), fileHashes: ["templates/main.md": "bbb"])
        )

        #expect(diff.entries == [
            PackDiff.Entry(
                kind: .template, name: "test-pack.main",
                change: .modified(path: "templates/main.md")
            ),
        ])
    }

    @Test("Supplementary doctor checks diff by name")
    func doctorCheckAddedAndRemoved() {
        let diff = PackDiff.between(
            old: snapshot(manifest(supplementaryDoctorChecks: [
                commandCheck(name: "git present", command: "git"),
            ])),
            new: snapshot(manifest(supplementaryDoctorChecks: [
                commandCheck(name: "jq present", command: "jq"),
            ]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .doctorCheck, name: "jq present", change: .added),
            PackDiff.Entry(kind: .doctorCheck, name: "git present", change: .removed),
        ])
    }

    // MARK: - Prompts

    @Test("Prompts diff by key")
    func promptAddedAndRemoved() {
        let diff = PackDiff.between(
            old: snapshot(manifest(prompts: [inputPrompt(key: "apiKey")])),
            new: snapshot(manifest(prompts: [inputPrompt(key: "token")]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .prompt, name: "token", change: .added),
            PackDiff.Entry(kind: .prompt, name: "apiKey", change: .removed),
        ])
    }

    @Test("Prompt kept under the same key but redefined is modified")
    func promptModified() {
        let diff = PackDiff.between(
            old: snapshot(manifest(prompts: [inputPrompt(key: "apiKey", label: "Old label")])),
            new: snapshot(manifest(prompts: [inputPrompt(key: "apiKey", label: "New label")]))
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .prompt, name: "apiKey", change: .modified(path: nil)),
        ])
    }

    // MARK: - Configure script

    @Test("Adding a configure script is reported")
    func configureScriptAdded() {
        let diff = PackDiff.between(
            old: snapshot(manifest()),
            new: snapshot(
                manifest(configureProject: ExternalConfigureProject(script: "scripts/setup.sh")),
                fileHashes: ["scripts/setup.sh": "aaa"]
            )
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .configureScript, name: "scripts/setup.sh", change: .added),
        ])
    }

    @Test("Editing the configure script body is reported — the gap this closes")
    func configureScriptContentModified() {
        let configure = ExternalConfigureProject(script: "scripts/setup.sh")
        let diff = PackDiff.between(
            old: snapshot(manifest(configureProject: configure), fileHashes: ["scripts/setup.sh": "aaa"]),
            new: snapshot(manifest(configureProject: configure), fileHashes: ["scripts/setup.sh": "bbb"])
        )

        #expect(diff.entries == [
            PackDiff.Entry(
                kind: .configureScript, name: "scripts/setup.sh",
                change: .modified(path: "scripts/setup.sh")
            ),
        ])
    }

    @Test("Repointing the configure script reads as a removal plus an addition")
    func configureScriptRepointed() {
        let diff = PackDiff.between(
            old: snapshot(
                manifest(configureProject: ExternalConfigureProject(script: "scripts/old.sh")),
                fileHashes: ["scripts/old.sh": "aaa"]
            ),
            new: snapshot(
                manifest(configureProject: ExternalConfigureProject(script: "scripts/new.sh")),
                fileHashes: ["scripts/new.sh": "bbb"]
            )
        )

        #expect(diff.entries == [
            PackDiff.Entry(kind: .configureScript, name: "scripts/new.sh", change: .added),
            PackDiff.Entry(kind: .configureScript, name: "scripts/old.sh", change: .removed),
        ])
    }

    @Test("Configure script content change renders without repeating the path")
    func configureScriptRendersWithoutRedundantSuffix() {
        let diff = PackDiff(entries: [
            PackDiff.Entry(
                kind: .configureScript, name: "scripts/setup.sh",
                change: .modified(path: "scripts/setup.sh")
            ),
        ])

        #expect(diff.render(style: plainStyle) == "  ~ configure script: scripts/setup.sh")
    }

    // MARK: - Empty

    @Test("Identical snapshots produce an empty diff that renders as nothing")
    func identicalSnapshotsAreEmpty() {
        let same = manifest(components: [hookComponent(id: "test-pack.lint")])
        let diff = PackDiff.between(
            old: snapshot(same, fileHashes: ["hooks/lint.sh": "aaa"]),
            new: snapshot(same, fileHashes: ["hooks/lint.sh": "aaa"])
        )

        #expect(diff.isEmpty)
        #expect(diff.render(style: plainStyle).isEmpty)
    }

    // MARK: - Rendering

    @Test("Render groups added, then modified, then removed")
    func renderGroupsByChangeKind() {
        let diff = PackDiff(entries: [
            PackDiff.Entry(kind: .component, name: "test-pack.gone", change: .removed),
            PackDiff.Entry(kind: .component, name: "test-pack.lint", change: .modified(path: "hooks/lint.sh")),
            PackDiff.Entry(kind: .component, name: "test-pack.new", change: .added),
        ])

        #expect(diff.render(style: plainStyle) == """
          + component: test-pack.new
          ~ component: test-pack.lint (hooks/lint.sh changed)
          - component: test-pack.gone
        """)
    }

    @Test("Render honors a custom indent")
    func renderHonorsIndent() {
        let diff = PackDiff(entries: [
            PackDiff.Entry(kind: .template, name: "test-pack.main", change: .added),
        ])

        #expect(diff.render(style: plainStyle, indent: "    ") == "    + template: test-pack.main")
    }

    @Test("Render truncates past the limit with a remainder line")
    func renderTruncatesPastLimit() {
        let entries = (1 ... 5).map {
            PackDiff.Entry(kind: .component, name: "test-pack.c\($0)", change: .added)
        }
        let rendered = PackDiff(entries: entries).render(style: plainStyle, limit: 3)

        #expect(rendered == """
          + component: test-pack.c1
          + component: test-pack.c2
          + component: test-pack.c3
          … and 2 more changes
        """)
    }

    @Test("Exactly at the limit renders no remainder line")
    func renderAtLimitHasNoRemainder() {
        let entries = (1 ... 3).map {
            PackDiff.Entry(kind: .component, name: "test-pack.c\($0)", change: .added)
        }
        let rendered = PackDiff(entries: entries).render(style: plainStyle, limit: 3)

        #expect(!rendered.contains("more change"))
        #expect(rendered.split(separator: "\n").count == 3)
    }

    @Test("A single hidden change is singular")
    func renderSingularRemainder() {
        let entries = (1 ... 4).map {
            PackDiff.Entry(kind: .component, name: "test-pack.c\($0)", change: .added)
        }
        let rendered = PackDiff(entries: entries).render(style: plainStyle, limit: 3)

        #expect(rendered.hasSuffix("… and 1 more change"))
    }
}
