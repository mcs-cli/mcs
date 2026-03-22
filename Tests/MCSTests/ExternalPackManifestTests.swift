import Foundation
@testable import mcs
import Testing

struct ExternalPackManifestTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-manifest-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Complete manifest parsing

    @Test("Parse a complete manifest with all fields")
    func parseCompleteManifest() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: A test tech pack
        version: "1.0.0"
        minMCSVersion: "2.0.0"
        peerDependencies:
          - pack: ios
            minVersion: "1.0.0"
        components:
          - id: my-pack.server
            displayName: My Server
            description: An MCP server
            type: mcpServer
            dependencies:
              - my-pack.dep
            isRequired: false
            installAction:
              type: mcpServer
              name: my-server
              command: npx
              args:
                - "-y"
                - "my-server@latest"
              env:
                MY_VAR: "1"
          - id: my-pack.dep
            displayName: My Dependency
            description: A brew package
            type: brewPackage
            isRequired: true
            installAction:
              type: brewInstall
              package: my-pkg
        templates:
          - sectionIdentifier: my-pack
            placeholders:
              - __PROJECT__
            contentFile: templates/section.md
        prompts:
          - key: project_name
            type: input
            label: "Project name"
            default: "MyProject"
          - key: framework
            type: select
            label: "Select framework"
            options:
              - value: uikit
                label: UIKit
              - value: swiftui
                label: SwiftUI
        configureProject:
          script: scripts/configure.sh
        supplementaryDoctorChecks:
          - type: commandExists
            name: My Tool
            section: Dependencies
            command: my-tool
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "my-pack")
        #expect(manifest.displayName == "My Pack")
        #expect(manifest.description == "A test tech pack")
        #expect(manifest.minMCSVersion == "2.0.0")

        // Components
        #expect(manifest.components?.count == 2)
        let server = try #require(manifest.components?[0])
        #expect(server.id == "my-pack.server")
        #expect(server.type == .mcpServer)
        #expect(server.dependencies == ["my-pack.dep"])
        #expect(server.isRequired == false)

        let dep = try #require(manifest.components?[1])
        #expect(dep.id == "my-pack.dep")
        #expect(dep.type == .brewPackage)
        #expect(dep.isRequired == true)

        // Templates
        #expect(manifest.templates?.count == 1)
        #expect(manifest.templates?[0].sectionIdentifier == "my-pack")
        #expect(manifest.templates?[0].placeholders == ["__PROJECT__"])
        #expect(manifest.templates?[0].contentFile == "templates/section.md")

        // Prompts
        #expect(manifest.prompts?.count == 2)
        #expect(manifest.prompts?[0].key == "project_name")
        #expect(manifest.prompts?[0].type == .input)
        #expect(manifest.prompts?[0].defaultValue == "MyProject")
        #expect(manifest.prompts?[1].key == "framework")
        #expect(manifest.prompts?[1].type == .select)
        #expect(manifest.prompts?[1].options?.count == 2)

        // Configure project
        #expect(manifest.configureProject?.script == "scripts/configure.sh")

        // Supplementary doctor checks
        #expect(manifest.supplementaryDoctorChecks?.count == 1)
        #expect(manifest.supplementaryDoctorChecks?[0].type == .commandExists)
        #expect(manifest.supplementaryDoctorChecks?[0].name == "My Tool")
        #expect(manifest.supplementaryDoctorChecks?[0].command == "my-tool")
    }

    // MARK: - Minimal manifest

    @Test("Parse minimal manifest with only required fields")
    func parseMinimalManifest() throws {
        let yaml = """
        schemaVersion: 1
        identifier: minimal
        displayName: Minimal Pack
        description: Just the basics
        version: "0.1.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.identifier == "minimal")
        #expect(manifest.author == nil)
        #expect(manifest.minMCSVersion == nil)
        #expect(manifest.components == nil)
        #expect(manifest.templates == nil)
        #expect(manifest.prompts == nil)
        #expect(manifest.configureProject == nil)
        #expect(manifest.supplementaryDoctorChecks == nil)
    }

    // MARK: - Author field

    @Test("Parse manifest with author field")
    func parseAuthorField() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: authored-pack
        displayName: Authored Pack
        description: A pack with author
        version: "1.0.0"
        author: "Jane Doe"
        """
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()

        #expect(manifest.author == "Jane Doe")
    }

    @Test("Normalized manifest preserves author")
    func normalizedPreservesAuthor() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: A pack
        version: "1.0.0"
        author: "John Smith"
        """
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let manifest = try ExternalPackManifest.load(from: file)
        let normalized = try manifest.normalized()

        #expect(normalized.author == "John Smith")
    }

    // MARK: - Validation errors

    @Test("Validation rejects unsupported schema version")
    func rejectBadSchemaVersion() throws {
        let yaml = """
        schemaVersion: 99
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.unsupportedSchemaVersion(99)) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects invalid identifier with uppercase")
    func rejectUppercaseIdentifier() throws {
        let yaml = """
        schemaVersion: 1
        identifier: MyPack
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("MyPack")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects empty identifier")
    func rejectEmptyIdentifier() throws {
        let yaml = """
        schemaVersion: 1
        identifier: ""
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects identifier starting with hyphen")
    func rejectHyphenStartIdentifier() throws {
        let yaml = """
        schemaVersion: 1
        identifier: "-bad"
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.invalidIdentifier("-bad")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects component ID without pack prefix")
    func rejectComponentIDPrefixViolation() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: wrong-prefix.server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.componentIDPrefixViolation(
            componentID: "wrong-prefix.server",
            expectedPrefix: "my-pack."
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects duplicate component IDs")
    func rejectDuplicateComponentIDs() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.server
            displayName: Server 1
            description: First
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
          - id: my-pack.server
            displayName: Server 2
            description: Duplicate
            type: mcpServer
            installAction:
              type: mcpServer
              name: server2
              command: npx
              args: ["-y", "server2@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.duplicateComponentID("my-pack.server")) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects template section not matching pack identifier")
    func rejectTemplateSectionMismatch() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: other-pack
            contentFile: templates/section.md
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.templateSectionMismatch(
            sectionIdentifier: "other-pack",
            packIdentifier: "my-pack"
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation accepts template section with pack identifier prefix")
    func acceptTemplateSectionWithPrefix() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: my-pack.extra
            contentFile: templates/extra.md
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()
    }

    @Test("Validation rejects duplicate prompt keys")
    func rejectDuplicatePromptKeys() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        prompts:
          - key: project
            type: input
            label: "Project"
          - key: project
            type: select
            label: "Project again"
            options:
              - value: a
                label: A
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.duplicatePromptKey("project")) {
            try manifest.validate()
        }
    }

    @Test("Validation accepts valid identifier with hyphens and numbers")
    func acceptValidIdentifier() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack-2
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()
    }

    @Test("Validation rejects hookEventExists without event")
    func rejectHookEventExistsNoEvent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: hookEventExists
            name: Bad hook check
            section: Hooks
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.self) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects hookEventExists with unknown event")
    func rejectHookEventExistsUnknownEvent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: hookEventExists
            name: Bad hook check
            section: Hooks
            event: BogusEvent
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.self) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects settingsKeyEquals without keyPath")
    func rejectSettingsKeyEqualsNoKeyPath() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: settingsKeyEquals
            name: Bad settings check
            section: Settings
            expectedValue: plan
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.self) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects settingsKeyEquals without expectedValue")
    func rejectSettingsKeyEqualsNoExpectedValue() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: settingsKeyEquals
            name: Bad settings check
            section: Settings
            keyPath: permissions.defaultMode
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.self) {
            try manifest.validate()
        }
    }

    // MARK: - Install action types

    @Test("Deserialize mcpServer install action with stdio transport")
    func mcpServerStdioAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.server
            displayName: Server
            description: An MCP server
            type: mcpServer
            installAction:
              type: mcpServer
              name: my-server
              command: npx
              args:
                - "-y"
                - "my-server@latest"
              env:
                DISABLE_TELEMETRY: "1"
              transport: stdio
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .mcpServer(config) = manifest.components?[0].installAction else {
            Issue.record("Expected mcpServer install action")
            return
        }

        #expect(config.name == "my-server")
        #expect(config.command == "npx")
        #expect(config.args == ["-y", "my-server@latest"])
        #expect(config.env == ["DISABLE_TELEMETRY": "1"])
        #expect(config.transport == .stdio)
    }

    @Test("Deserialize mcpServer install action with http transport")
    func mcpServerHTTPAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.http-server
            displayName: HTTP Server
            description: An HTTP MCP server
            type: mcpServer
            installAction:
              type: mcpServer
              name: my-http-server
              transport: http
              url: https://example.com/mcp
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .mcpServer(config) = manifest.components?[0].installAction else {
            Issue.record("Expected mcpServer install action")
            return
        }

        #expect(config.name == "my-http-server")
        #expect(config.transport == .http)
        #expect(config.url == "https://example.com/mcp")

        // Convert to internal config
        let internal_ = config.toMCPServerConfig()
        #expect(internal_.name == "my-http-server")
        #expect(internal_.command == "http")
        #expect(internal_.args == ["https://example.com/mcp"])
    }

    @Test("Deserialize plugin install action")
    func pluginAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.plugin
            displayName: Plugin
            description: A plugin
            type: plugin
            installAction:
              type: plugin
              name: my-plugin@1.0.0
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .plugin(name) = manifest.components?[0].installAction else {
            Issue.record("Expected plugin install action")
            return
        }
        #expect(name == "my-plugin@1.0.0")
    }

    @Test("Deserialize brewInstall install action")
    func brewInstallAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.brew
            displayName: Brew Pkg
            description: A brew package
            type: brewPackage
            installAction:
              type: brewInstall
              package: my-package
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .brewInstall(package) = manifest.components?[0].installAction else {
            Issue.record("Expected brewInstall install action")
            return
        }
        #expect(package == "my-package")
    }

    @Test("Deserialize shellCommand install action")
    func shellCommandAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.skill
            displayName: Skill
            description: A skill via shell command
            type: skill
            installAction:
              type: shellCommand
              command: "npx -y skills add my-skill -g -a claude-code -y"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .shellCommand(command) = manifest.components?[0].installAction else {
            Issue.record("Expected shellCommand install action")
            return
        }
        #expect(command == "npx -y skills add my-skill -g -a claude-code -y")
    }

    @Test("Deserialize gitignoreEntries install action")
    func gitignoreEntriesAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.gitignore
            displayName: Gitignore
            description: Gitignore entries
            type: configuration
            installAction:
              type: gitignoreEntries
              entries:
                - .my-dir
                - "*.generated"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .gitignoreEntries(entries) = manifest.components?[0].installAction else {
            Issue.record("Expected gitignoreEntries install action")
            return
        }
        #expect(entries == [".my-dir", "*.generated"])
    }

    @Test("Deserialize settingsMerge install action")
    func settingsMergeAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.settings
            displayName: Settings
            description: Settings merge
            type: configuration
            installAction:
              type: settingsMerge
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case .settingsMerge = manifest.components?[0].installAction else {
            Issue.record("Expected settingsMerge install action")
            return
        }
    }

    @Test("Deserialize settingsFile install action")
    func settingsFileAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.settings-file
            displayName: Settings File
            description: Custom settings file
            type: configuration
            installAction:
              type: settingsFile
              source: config/settings.json
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .settingsFile(source) = manifest.components?[0].installAction else {
            Issue.record("Expected settingsFile install action")
            return
        }
        #expect(source == "config/settings.json")
    }

    @Test("Deserialize copyPackFile install action")
    func copyPackFileAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.hook
            displayName: Hook
            description: A hook file
            type: hookFile
            installAction:
              type: copyPackFile
              source: hooks/my-hook.sh
              destination: hooks/my-hook.sh
              fileType: hook
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .copyPackFile(config) = manifest.components?[0].installAction else {
            Issue.record("Expected copyPackFile install action")
            return
        }
        #expect(config.source == "hooks/my-hook.sh")
        #expect(config.destination == "hooks/my-hook.sh")
        #expect(config.fileType == .hook)
    }

    @Test("Deserialize copyPackFile install action with agent fileType")
    func copyPackFileAgentAction() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.agent
            displayName: Code Reviewer
            description: A subagent file
            type: agent
            installAction:
              type: copyPackFile
              source: agents/code-reviewer.md
              destination: code-reviewer.md
              fileType: agent
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .copyPackFile(config) = manifest.components?[0].installAction else {
            Issue.record("Expected copyPackFile install action")
            return
        }
        #expect(config.source == "agents/code-reviewer.md")
        #expect(config.destination == "code-reviewer.md")
        #expect(config.fileType == .agent)
    }

    // MARK: - Doctor check types

    @Test("Deserialize all doctor check types")
    func allDoctorCheckTypes() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: commandExists
            name: Tool check
            section: Dependencies
            command: my-tool
          - type: fileExists
            name: Config file
            section: Configuration
            path: ~/.config/my-tool.json
          - type: directoryExists
            name: Data dir
            section: Configuration
            path: ~/.my-tool
          - type: fileContains
            name: Config has key
            section: Configuration
            path: ~/.config/my-tool.json
            pattern: "api_key"
          - type: fileNotContains
            name: No debug flag
            section: Configuration
            path: ~/.config/my-tool.json
            pattern: "debug: true"
          - type: shellScript
            name: Custom check
            section: Custom
            command: "test -f /tmp/ready"
            fixCommand: "touch /tmp/ready"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let checks = try #require(manifest.supplementaryDoctorChecks)

        #expect(checks.count == 6)
        #expect(checks[0].type == .commandExists)
        #expect(checks[0].command == "my-tool")
        #expect(checks[1].type == .fileExists)
        #expect(checks[1].path == "~/.config/my-tool.json")
        #expect(checks[2].type == .directoryExists)
        #expect(checks[3].type == .fileContains)
        #expect(checks[3].pattern == "api_key")
        #expect(checks[4].type == .fileNotContains)
        #expect(checks[4].pattern == "debug: true")
        #expect(checks[5].type == .shellScript)
        #expect(checks[5].fixCommand == "touch /tmp/ready")
    }

    @Test("Deserialize doctor check with scope and fixScript")
    func doctorCheckWithScopeAndFixScript() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: fileExists
            name: Project config
            section: Project
            path: .my-tool/config.yaml
            scope: project
            fixScript: scripts/fix-config.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let check = try #require(manifest.supplementaryDoctorChecks?[0])

        #expect(check.scope == .project)
        #expect(check.fixScript == "scripts/fix-config.sh")
    }

    @Test("Deserialize hookEventExists doctor check")
    func hookEventExistsDoctorCheck() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: hookEventExists
            name: SessionStart hook
            section: Hooks
            event: SessionStart
            isOptional: false
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()

        let check = try #require(manifest.supplementaryDoctorChecks?[0])
        #expect(check.type == .hookEventExists)
        #expect(check.event == "SessionStart")
        #expect(check.isOptional == false)
    }

    @Test("Deserialize settingsKeyEquals doctor check")
    func settingsKeyEqualsDoctorCheck() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        supplementaryDoctorChecks:
          - type: settingsKeyEquals
            name: Plan mode
            section: Settings
            keyPath: permissions.defaultMode
            expectedValue: plan
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()

        let check = try #require(manifest.supplementaryDoctorChecks?[0])
        #expect(check.type == .settingsKeyEquals)
        #expect(check.keyPath == "permissions.defaultMode")
        #expect(check.expectedValue == "plan")
    }

    // MARK: - Prompt types

    @Test("Deserialize all prompt types")
    func allPromptTypes() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        prompts:
          - key: project_file
            type: fileDetect
            label: "Xcode project"
            detectPattern: "*.xcodeproj"
          - key: name
            type: input
            label: "Project name"
            default: "MyApp"
          - key: platform
            type: select
            label: "Target platform"
            options:
              - value: ios
                label: iOS
              - value: macos
                label: macOS
          - key: version
            type: script
            label: "Detected version"
            scriptCommand: "cat VERSION"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let prompts = try #require(manifest.prompts)

        #expect(prompts.count == 4)

        #expect(prompts[0].type == .fileDetect)
        #expect(prompts[0].detectPatterns == ["*.xcodeproj"])

        #expect(prompts[1].type == .input)
        #expect(prompts[1].defaultValue == "MyApp")

        #expect(prompts[2].type == .select)
        #expect(prompts[2].options?.count == 2)
        #expect(prompts[2].options?[0] == PromptOption(value: "ios", label: "iOS"))
        #expect(prompts[2].options?[1] == PromptOption(value: "macos", label: "macOS"))

        #expect(prompts[3].type == .script)
        #expect(prompts[3].scriptCommand == "cat VERSION")
    }

    // MARK: - ExternalComponentType mapping

    @Test("ExternalComponentType maps to ComponentType correctly")
    func componentTypeMapping() {
        #expect(ExternalComponentType.mcpServer.componentType == .mcpServer)
        #expect(ExternalComponentType.plugin.componentType == .plugin)
        #expect(ExternalComponentType.skill.componentType == .skill)
        #expect(ExternalComponentType.hookFile.componentType == .hookFile)
        #expect(ExternalComponentType.command.componentType == .command)
        #expect(ExternalComponentType.agent.componentType == .agent)
        #expect(ExternalComponentType.brewPackage.componentType == .brewPackage)
        #expect(ExternalComponentType.configuration.componentType == .configuration)
    }

    // MARK: - MCPServerConfig conversion

    @Test("ExternalMCPServerConfig converts to MCPServerConfig for stdio")
    func mcpServerConfigConversionStdio() {
        let external = ExternalMCPServerConfig(
            name: "test-server",
            command: "node",
            args: ["server.js"],
            env: ["PORT": "3000"],
            transport: .stdio,
            url: nil,
            scope: nil
        )

        let config = external.toMCPServerConfig()
        #expect(config.name == "test-server")
        #expect(config.command == "node")
        #expect(config.args == ["server.js"])
        #expect(config.env == ["PORT": "3000"])
    }

    @Test("ExternalMCPServerConfig converts to MCPServerConfig for http")
    func mcpServerConfigConversionHTTP() {
        let external = ExternalMCPServerConfig(
            name: "http-server",
            command: nil,
            args: nil,
            env: nil,
            transport: .http,
            url: "https://example.com/mcp",
            scope: nil
        )

        let config = external.toMCPServerConfig()
        #expect(config.name == "http-server")
        #expect(config.command == "http")
        #expect(config.args == ["https://example.com/mcp"])
        #expect(config.env == [:])
    }

    @Test("ExternalMCPServerConfig passes scope through to MCPServerConfig")
    func mcpServerConfigScopePassthrough() {
        let external = ExternalMCPServerConfig(
            name: "test-server",
            command: "node",
            args: ["server.js"],
            env: nil,
            transport: .stdio,
            url: nil,
            scope: .local
        )

        let config = external.toMCPServerConfig()
        #expect(config.scope == "local")
        #expect(config.resolvedScope == "local")
    }

    @Test("ExternalMCPServerConfig with project scope passes through")
    func mcpServerConfigProjectScope() {
        let external = ExternalMCPServerConfig(
            name: "team-server",
            command: "node",
            args: [],
            env: nil,
            transport: nil,
            url: nil,
            scope: .project
        )

        let config = external.toMCPServerConfig()
        #expect(config.scope == "project")
        #expect(config.resolvedScope == "project")
    }

    @Test("MCPServerConfig resolvedScope defaults to local when nil")
    func mcpServerConfigDefaultScope() {
        let config = MCPServerConfig(name: "test", command: "node", args: [], env: [:])
        #expect(config.scope == nil)
        #expect(config.resolvedScope == "local")
    }

    @Test("ExternalScope includes local variant")
    func externalScopeLocal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        let yaml = """
        schemaVersion: 1
        identifier: scope-test
        displayName: Scope Test
        description: Test scope
        version: "1.0.0"
        components:
          - id: scope-test.server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: test-mcp
              command: node
              args: ["server.js"]
              scope: local
        """
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let manifest = try ExternalPackManifest.load(from: file)
        let component = try #require(manifest.components?.first)
        if case let .mcpServer(config) = component.installAction {
            #expect(config.scope == .local)
        } else {
            Issue.record("Expected mcpServer action")
        }
    }

    // MARK: - Component with doctor checks

    @Test("Component with inline doctor checks deserializes correctly")
    func componentWithDoctorChecks() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
            doctorChecks:
              - type: fileExists
                name: Server config
                section: Configuration
                path: ~/.server/config.json
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let component = try #require(manifest.components?[0])

        #expect(component.doctorChecks?.count == 1)
        #expect(component.doctorChecks?[0].type == .fileExists)
        #expect(component.doctorChecks?[0].name == "Server config")
    }

    // MARK: - Default values

    @Test("Component defaults: dependencies is nil, isRequired is nil")
    func componentDefaults() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: test.basic
            displayName: Basic
            description: A basic component
            type: configuration
            installAction:
              type: settingsMerge
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let component = try #require(manifest.components?[0])

        #expect(component.dependencies == nil)
        #expect(component.isRequired == nil)
        #expect(component.doctorChecks == nil)
    }

    // MARK: - Hook contribution default position

    // MARK: - Normalization (auto-prefix)

    @Test("normalized() auto-prefixes short component IDs with pack identifier")
    func normalizeShortIDs() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
          - id: brew
            displayName: Brew
            description: A package
            type: brewPackage
            installAction:
              type: brewInstall
              package: my-pkg
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.components?[0].id == "my-pack.server")
        #expect(normalized.components?[1].id == "my-pack.brew")
    }

    @Test("normalized() rejects component IDs containing dots")
    func normalizeRejectsDottedComponentIDs() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.dotInRawID("my-pack.server")) {
            try raw.normalized()
        }
    }

    @Test("normalized() auto-prefixes intra-pack dependencies")
    func normalizeIntraPackDeps() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: brew
            displayName: Brew
            description: A package
            type: brewPackage
            installAction:
              type: brewInstall
              package: my-pkg
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            dependencies:
              - brew
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.components?[1].dependencies == ["my-pack.brew"])
    }

    @Test("normalized() leaves cross-pack dependencies unchanged")
    func normalizeCrossPackDeps() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            dependencies:
              - other-pack.tool
              - brew
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.components?[0].dependencies == ["other-pack.tool", "my-pack.brew"])
    }

    @Test("normalized() with no components returns manifest unchanged")
    func normalizeNoComponents() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.components == nil)
        #expect(normalized.identifier == "my-pack")
    }

    @Test("normalized() then validate() accepts short IDs")
    func normalizeAndValidate() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        // Should not throw — normalized IDs now have the correct prefix
        try normalized.validate()
    }

    // MARK: - Template section normalization

    @Test("normalized() auto-prefixes short template section identifiers")
    func normalizeTemplateSections() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: ios
            contentFile: templates/ios.md
          - sectionIdentifier: git
            contentFile: templates/git.md
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.templates?[0].sectionIdentifier == "my-pack.ios")
        #expect(normalized.templates?[1].sectionIdentifier == "my-pack.git")
    }

    @Test("normalized() rejects template sectionIdentifiers containing dots")
    func normalizeRejectsDottedSectionIDs() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: my-pack.ios
            contentFile: templates/ios.md
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.dotInRawID("my-pack.ios")) {
            try raw.normalized()
        }
    }

    @Test("normalized() then validate() accepts short template section identifiers")
    func normalizeAndValidateTemplateSections() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: ios
            contentFile: templates/ios.md
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        // Should not throw — normalized section IDs now have the correct prefix
        try normalized.validate()
    }

    // MARK: - Template dependency normalization and validation

    @Test("normalized() auto-prefixes template dependencies")
    func normalizeTemplateDependencies() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: serena
            displayName: Serena
            description: LSP
            type: mcpServer
            installAction:
              type: mcpServer
              name: serena
              command: uvx
              args: [serena]
        templates:
          - sectionIdentifier: serena
            contentFile: templates/serena.md
            dependencies:
              - serena
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(normalized.templates?[0].dependencies == ["my-pack.serena"])
    }

    @Test("validate() rejects template dependency referencing nonexistent component")
    func rejectTemplateDependencyMismatch() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: my-pack.serena
            contentFile: templates/serena.md
            dependencies:
              - my-pack.nonexistent
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.templateDependencyMismatch(
            sectionIdentifier: "my-pack.serena",
            componentID: "my-pack.nonexistent"
        )) {
            try manifest.validate()
        }
    }

    @Test("normalized() rejects template dependency containing dots")
    func normalizeRejectsDottedTemplateDep() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: serena
            contentFile: templates/serena.md
            dependencies:
              - my-pack.serena
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        #expect(throws: ManifestError.dotInRawID("my-pack.serena")) {
            try raw.normalized()
        }
    }

    @Test("validate() accepts template with no dependencies")
    func acceptTemplateWithoutDependencies() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        templates:
          - sectionIdentifier: my-pack.main
            contentFile: templates/main.md
        """
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        try manifest.validate()
        #expect(manifest.templates?[0].dependencies == nil)
    }

    // MARK: - Dependency resolution validation

    @Test("validate() throws unresolvedDependency for nonexistent intra-pack dep")
    func validateUnresolvedIntraPackDep() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            dependencies:
              - nonexistent
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        #expect(throws: ManifestError.unresolvedDependency(
            componentID: "my-pack.server",
            dependency: "my-pack.nonexistent"
        )) {
            try normalized.validate()
        }
    }

    @Test("validate() passes for cross-pack dependencies")
    func validateCrossPackDepsPass() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            dependencies:
              - other-pack.tool
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        // Should not throw — cross-pack deps are not validated
        try normalized.validate()
    }

    @Test("validate() passes when all intra-pack deps resolve")
    func validateResolvedIntraPackDeps() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: Test
        description: Test
        version: "1.0.0"
        components:
          - id: brew
            displayName: Brew
            description: A package
            type: brewPackage
            installAction:
              type: brewInstall
              package: my-pkg
          - id: server
            displayName: Server
            description: A server
            type: mcpServer
            dependencies:
              - brew
            installAction:
              type: mcpServer
              name: server
              command: npx
              args: ["-y", "server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let normalized = try raw.normalized()

        // Should not throw — "brew" normalizes to "my-pack.brew" which exists
        try normalized.validate()
    }

    @Test("validate() rejects bare sectionIdentifier equal to pack identifier")
    func validateRejectsBarePackIdentifierSection() throws {
        // After normalization, sectionIdentifier "my-pack" becomes "my-pack.my-pack"
        // which passes via hasPrefix. But if someone constructs a manifest with
        // a raw sectionIdentifier equal to the identifier, it should be rejected.
        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "my-pack",
            displayName: "Test",
            description: "Test",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: [
                ExternalTemplateDefinition(
                    sectionIdentifier: "my-pack",
                    placeholders: nil,
                    contentFile: "t.md"
                ),
            ],
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil
        )

        #expect(throws: ManifestError.templateSectionMismatch(
            sectionIdentifier: "my-pack",
            packIdentifier: "my-pack"
        )) {
            try manifest.validate()
        }
    }

    // MARK: - hookEvent validation

    @Test("Validation rejects unknown hookEvent on component")
    func rejectUnknownHookEvent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: hook
            description: A hook
            hookEvent: BogusEvent
            hook:
              source: hooks/test.sh
              destination: test.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let manifest = try raw.normalized()

        #expect(throws: ManifestError.invalidHookEvent(
            componentID: "my-pack.hook",
            hookEvent: "BogusEvent"
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation accepts all known hookEvent values")
    func acceptKnownHookEvents() throws {
        for event in Constants.Hooks.validEvents.sorted() {
            let yaml = """
            schemaVersion: 1
            identifier: my-pack
            displayName: My Pack
            description: Test
            version: "1.0.0"
            components:
              - id: hook
                description: A hook
                hookEvent: \(event)
                hook:
                  source: hooks/test.sh
                  destination: test.sh
            """

            let tmpDir = try makeTmpDir()
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let file = tmpDir.appendingPathComponent("techpack.yaml")
            try yaml.write(to: file, atomically: true, encoding: .utf8)

            let raw = try ExternalPackManifest.load(from: file)
            let manifest = try raw.normalized()
            try manifest.validate()
        }
    }

    @Test("Validation rejects negative hookTimeout")
    func rejectNegativeHookTimeout() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: hook
            description: A hook
            hookEvent: SessionStart
            hookTimeout: -5
            hook:
              source: hooks/test.sh
              destination: test.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let raw = try ExternalPackManifest.load(from: file)
        let manifest = try raw.normalized()

        #expect(throws: ManifestError.invalidHookMetadata(
            componentID: "my-pack.hook",
            reason: "hookTimeout must be positive (got -5)"
        )) {
            try manifest.validate()
        }
    }

    @Test("Validation rejects hook metadata without hookEvent")
    func rejectHookMetadataWithoutEvent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.node
            description: Node.js
            type: brewPackage
            hookTimeout: 30
            installAction:
              type: brewInstall
              package: node
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)

        #expect(throws: ManifestError.invalidHookMetadata(
            componentID: "my-pack.node",
            reason: "hookTimeout/hookAsync/hookStatusMessage require hookEvent to be set"
        )) {
            try manifest.validate()
        }
    }

    // MARK: - Shorthand: brew

    @Test("Shorthand brew: infers brewPackage type and brewInstall action")
    func shorthandBrew() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.node
            description: JavaScript runtime
            brew: node
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .brewPackage)
        #expect(comp.displayName == "my-pack.node")
        guard case let .brewInstall(package) = comp.installAction else {
            Issue.record("Expected brewInstall"); return
        }
        #expect(package == "node")
    }

    // MARK: - Shorthand: mcp (stdio)

    @Test("Shorthand mcp: with command infers mcpServer type and stdio config")
    func shorthandMCPStdio() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.serena
            description: Semantic navigation
            mcp:
              command: uvx
              args:
                - "--from"
                - "git+https://github.com/oraios/serena"
              env:
                KEY: value
              scope: local
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .mcpServer)
        guard case let .mcpServer(config) = comp.installAction else {
            Issue.record("Expected mcpServer"); return
        }
        #expect(config.name == "serena")
        #expect(config.command == "uvx")
        #expect(config.args == ["--from", "git+https://github.com/oraios/serena"])
        #expect(config.env == ["KEY": "value"])
        #expect(config.scope == .local)
    }

    // MARK: - Shorthand: mcp (http)

    @Test("Shorthand mcp: with url infers HTTP transport")
    func shorthandMCPHTTP() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.sosumi
            description: Apple docs
            mcp:
              url: https://sosumi.ai/mcp
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .mcpServer)
        guard case let .mcpServer(config) = comp.installAction else {
            Issue.record("Expected mcpServer"); return
        }
        #expect(config.name == "sosumi")
        #expect(config.transport == .http)
        #expect(config.url == "https://sosumi.ai/mcp")

        let resolved = config.toMCPServerConfig()
        #expect(resolved.command == "http")
        #expect(resolved.args == ["https://sosumi.ai/mcp"])
    }

    // MARK: - Shorthand: mcp name derived from prefixed id

    @Test("Shorthand mcp: strips pack prefix from component id for server name")
    func shorthandMCPNameFromPrefixedID() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.docs-mcp-server
            description: Docs search
            mcp:
              command: npx
              args: ["-y", "docs-mcp-server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .mcpServer(config) = manifest.components?.first?.installAction else {
            Issue.record("Expected mcpServer"); return
        }
        #expect(config.name == "docs-mcp-server")
    }

    // MARK: - Shorthand: plugin

    @Test("Shorthand plugin: infers plugin type and name")
    func shorthandPlugin() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.pr-review
            description: PR review toolkit
            plugin: "pr-review-toolkit@claude-plugins-official"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .plugin)
        guard case let .plugin(name) = comp.installAction else {
            Issue.record("Expected plugin"); return
        }
        #expect(name == "pr-review-toolkit@claude-plugins-official")
    }

    // MARK: - Shorthand: shell (requires explicit type)

    @Test("Shorthand shell: requires explicit type field")
    func shorthandShell() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.xcode-skill
            description: Install via shell
            type: skill
            shell: "npx -y skills add xcodebuildmcp -g"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .skill)
        guard case let .shellCommand(command) = comp.installAction else {
            Issue.record("Expected shellCommand"); return
        }
        #expect(command == "npx -y skills add xcodebuildmcp -g")
    }

    // MARK: - Shorthand: hook

    @Test("Shorthand hook: infers hookFile type and copyPackFile action")
    func shorthandHook() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.session-start
            description: Session start hook
            hookEvent: SessionStart
            hook:
              source: hooks/session_start.sh
              destination: session_start.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .hookFile)
        #expect(comp.hookEvent == "SessionStart")
        guard case let .copyPackFile(config) = comp.installAction else {
            Issue.record("Expected copyPackFile"); return
        }
        #expect(config.source == "hooks/session_start.sh")
        #expect(config.destination == "session_start.sh")
        #expect(config.fileType == .hook)
    }

    @Test("Shorthand hook with handler metadata: timeout, async, statusMessage")
    func shorthandHookWithMetadata() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.lint-hook
            description: Lint hook with metadata
            hookEvent: PostToolUse
            hookTimeout: 30
            hookAsync: true
            hookStatusMessage: "Running lint..."
            hook:
              source: hooks/lint.sh
              destination: lint.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.hookEvent == "PostToolUse")
        #expect(comp.hookTimeout == 30)
        #expect(comp.hookAsync == true)
        #expect(comp.hookStatusMessage == "Running lint...")
        #expect(comp.type == .hookFile)
    }

    @Test("Hook handler metadata fields are nil when not specified")
    func hookMetadataFieldsNilWhenAbsent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.session-start
            description: Plain hook
            hookEvent: SessionStart
            hook:
              source: hooks/session_start.sh
              destination: session_start.sh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.hookTimeout == nil)
        #expect(comp.hookAsync == nil)
        #expect(comp.hookStatusMessage == nil)
    }

    // MARK: - Shorthand: command

    @Test("Shorthand command: infers command type and copyPackFile action")
    func shorthandCommand() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.pr
            description: PR command
            command:
              source: commands/pr.md
              destination: pr.md
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .command)
        guard case let .copyPackFile(config) = comp.installAction else {
            Issue.record("Expected copyPackFile"); return
        }
        #expect(config.source == "commands/pr.md")
        #expect(config.fileType == .command)
    }

    // MARK: - Shorthand: skill

    @Test("Shorthand skill: infers skill type and copyPackFile action")
    func shorthandSkill() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.learning
            description: Continuous learning
            skill:
              source: skills/continuous-learning
              destination: continuous-learning
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .skill)
        guard case let .copyPackFile(config) = comp.installAction else {
            Issue.record("Expected copyPackFile"); return
        }
        #expect(config.source == "skills/continuous-learning")
        #expect(config.fileType == .skill)
    }

    // MARK: - Shorthand: agent

    @Test("Shorthand agent: infers agent type and copyPackFile action")
    func shorthandAgent() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.code-reviewer
            description: Expert code reviewer subagent
            agent:
              source: agents/code-reviewer.md
              destination: code-reviewer.md
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .agent)
        guard case let .copyPackFile(config) = comp.installAction else {
            Issue.record("Expected copyPackFile"); return
        }
        #expect(config.source == "agents/code-reviewer.md")
        #expect(config.fileType == .agent)
    }

    // MARK: - Shorthand: settingsFile

    @Test("Shorthand settingsFile: infers configuration type and settingsFile action")
    func shorthandSettingsFile() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.settings
            description: Settings
            settingsFile: config/settings.json
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .configuration)
        guard case let .settingsFile(source) = comp.installAction else {
            Issue.record("Expected settingsFile"); return
        }
        #expect(source == "config/settings.json")
    }

    // MARK: - Shorthand: gitignore

    @Test("Shorthand gitignore: infers configuration type and gitignoreEntries action")
    func shorthandGitignore() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.gitignore
            description: Gitignore entries
            gitignore:
              - .claude/memories
              - .xcodebuildmcp
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .configuration)
        guard case let .gitignoreEntries(entries) = comp.installAction else {
            Issue.record("Expected gitignoreEntries"); return
        }
        #expect(entries == [".claude/memories", ".xcodebuildmcp"])
    }

    // MARK: - Shorthand: displayName defaults to id

    @Test("displayName defaults to id when omitted")
    func shorthandDisplayNameDefault() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.gh
            description: GitHub CLI
            brew: gh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.displayName == "my-pack.gh")
    }

    @Test("displayName can be overridden in shorthand form")
    func shorthandDisplayNameOverride() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.gh
            displayName: GitHub CLI
            description: GitHub CLI for PR operations
            brew: gh
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.displayName == "GitHub CLI")
    }

    // MARK: - Shorthand: displayName defaults to id in verbose form too

    @Test("displayName defaults to id when omitted in verbose form")
    func verboseDisplayNameDefault() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.node
            description: Node.js runtime
            type: brewPackage
            installAction:
              type: brewInstall
              package: node
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.displayName == "my-pack.node")
    }

    // MARK: - Shorthand: mixed verbose and shorthand in same manifest

    @Test("Mixed verbose and shorthand components in same manifest")
    func mixedVerboseAndShorthand() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.homebrew
            displayName: Homebrew
            description: macOS package manager
            type: brewPackage
            installAction:
              type: shellCommand
              command: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
          - id: my-pack.node
            description: Node.js
            dependencies: [my-pack.homebrew]
            brew: node
          - id: my-pack.my-server
            description: MCP server
            mcp:
              command: npx
              args: ["-y", "my-server@latest"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comps = try #require(manifest.components)
        #expect(comps.count == 3)

        // Verbose: homebrew
        #expect(comps[0].type == .brewPackage)
        guard case .shellCommand = comps[0].installAction else {
            Issue.record("Expected shellCommand"); return
        }

        // Shorthand: node
        #expect(comps[1].type == .brewPackage)
        guard case let .brewInstall(package) = comps[1].installAction else {
            Issue.record("Expected brewInstall"); return
        }
        #expect(package == "node")

        // Shorthand: my-server
        #expect(comps[2].type == .mcpServer)
        guard case let .mcpServer(config) = comps[2].installAction else {
            Issue.record("Expected mcpServer"); return
        }
        #expect(config.name == "my-server")
    }

    // MARK: - Shorthand: normalization works with shorthand IDs

    @Test("Shorthand components with short IDs normalize correctly")
    func shorthandNormalization() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: node
            description: Node.js
            dependencies: [homebrew]
            brew: node
          - id: homebrew
            description: Homebrew
            type: brewPackage
            shell: "brew --version"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let normalized = try manifest.normalized()

        let comps = try #require(normalized.components)
        #expect(comps[0].id == "my-pack.node")
        #expect(comps[0].dependencies == ["my-pack.homebrew"])
        #expect(comps[1].id == "my-pack.homebrew")
    }

    // MARK: - Shorthand: mcp name from short id

    @Test("Shorthand mcp: derives name from short id before normalization")
    func shorthandMCPNameFromShortID() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: serena
            description: Code nav
            mcp:
              command: uvx
              args: ["serena", "start-mcp-server"]
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        guard case let .mcpServer(config) = manifest.components?.first?.installAction else {
            Issue.record("Expected mcpServer"); return
        }
        // Short id "serena" → name "serena"
        #expect(config.name == "serena")

        // After normalization, id becomes "my-pack.serena" but name stays "serena"
        let normalized = try manifest.normalized()
        #expect(normalized.components?.first?.id == "my-pack.serena")
        guard case let .mcpServer(normalizedConfig) = normalized.components?.first?.installAction else {
            Issue.record("Expected mcpServer"); return
        }
        #expect(normalizedConfig.name == "serena")
    }

    // MARK: - Shorthand: shorthand with all optional component fields

    @Test("Shorthand component with dependencies, isRequired, and doctorChecks")
    func shorthandWithOptionalFields() throws {
        let yaml = """
        schemaVersion: 1
        identifier: my-pack
        displayName: My Pack
        description: Test
        version: "1.0.0"
        components:
          - id: my-pack.session-hook
            description: Session start hook
            dependencies: [my-pack.jq]
            isRequired: true
            hookEvent: SessionStart
            hook:
              source: hooks/session_start.sh
              destination: session_start.sh
            doctorChecks:
              - type: hookEventExists
                name: SessionStart hook
                event: SessionStart
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        let comp = try #require(manifest.components?.first)

        #expect(comp.type == .hookFile)
        #expect(comp.dependencies == ["my-pack.jq"])
        #expect(comp.isRequired == true)
        #expect(comp.hookEvent == "SessionStart")
        #expect(comp.doctorChecks?.count == 1)
    }
}
