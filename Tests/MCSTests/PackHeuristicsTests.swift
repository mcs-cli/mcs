import Foundation
@testable import mcs
import Testing

struct PackHeuristicsTests {
    private func minimalManifest(
        identifier: String = "test-pack",
        components: [ExternalComponentDefinition]? = nil,
        supplementaryDoctorChecks: [ExternalDoctorCheckDefinition]? = nil,
        ignore: [String]? = nil
    ) -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1,
            identifier: identifier,
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: components,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: supplementaryDoctorChecks,
            ignore: ignore
        )
    }

    // MARK: - Hook Interpreters

    private func hookComponent(
        id: String = "test-pack.hook",
        source: String,
        destination: String,
        interpreter: String? = nil,
        doctorChecks: [ExternalDoctorCheckDefinition]? = nil
    ) -> ExternalComponentDefinition {
        ExternalComponentDefinition(
            id: id,
            displayName: "Hook",
            description: "A hook",
            type: .hookFile,
            hookRegistration: HookRegistration(event: .sessionStart, interpreter: interpreter),
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: source,
                destination: destination,
                fileType: .hook
            )),
            doctorChecks: doctorChecks
        )
    }

    @Test("Warns when a hook interpreter has no brew component installing it")
    func warnsOnUninstalledInterpreter() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = minimalManifest(components: [
            hookComponent(source: "hooks/fmt.js", destination: "fmt.js"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("uses node but no brew component installs node")
        })
    }

    @Test("No interpreter warning when a brew component installs it")
    func noWarningWhenBrewInstallsInterpreter() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let brew = ExternalComponentDefinition(
            id: "test-pack.node",
            displayName: "Node",
            description: "Node runtime",
            type: .brewPackage,
            installAction: .brewInstall(package: "node")
        )
        let manifest = minimalManifest(components: [
            brew,
            hookComponent(source: "hooks/fmt.js", destination: "fmt.js"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("installs node") })
    }

    @Test("Bash hooks never warn about their interpreter")
    func bashNeverWarns() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = minimalManifest(components: [
            hookComponent(source: "hooks/start.sh", destination: "start.sh"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("hookInterpreter") })
        #expect(!findings.contains { $0.message.contains("installs bash") })
    }

    @Test("Warns when a TypeScript hook declares no interpreter")
    func warnsOnAmbiguousExtension() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = minimalManifest(components: [
            hookComponent(source: "hooks/gate.ts", destination: "gate.ts"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("declares no")
                && $0.message.contains("hookInterpreter")
        })
    }

    @Test("No ambiguity warning once the TypeScript hook declares an interpreter")
    func noAmbiguityWarningWhenDeclared() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = minimalManifest(components: [
            hookComponent(
                source: "hooks/gate.ts",
                destination: "gate.ts",
                interpreter: "node --experimental-strip-types"
            ),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("declares no") })
    }

    @Test("Warns when a hookEventExists check asserts bash against a non-bash hook")
    func warnsOnInconsistentDoctorCheck() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let check = ExternalDoctorCheckDefinition(
            type: .hookEventExists,
            name: "Session hook registered",
            command: "bash .claude/hooks/fmt.js",
            event: "SessionStart"
        )
        let manifest = minimalManifest(components: [
            hookComponent(source: "hooks/fmt.js", destination: "fmt.js", doctorChecks: [check]),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("the check will never match")
        })
    }

    // MARK: - Root Source Copy

    @Test("Detects source: '.' copying pack root")
    func detectsRootSourceDot() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.my-hook",
            displayName: "My Hook",
            description: "A hook",
            type: .hookFile,
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: ".",
                destination: "my-hook",
                fileType: .hook
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.count == 1)
        #expect(findings[0].severity == .error)
        #expect(findings[0].message.contains("source '.'"))
        #expect(findings[0].message.contains("entire pack root"))
    }

    @Test("Detects source: './' copying pack root")
    func detectsRootSourceDotSlash() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.my-hook",
            displayName: "My Hook",
            description: "A hook",
            type: .hookFile,
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: "./",
                destination: "my-hook",
                fileType: .hook
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains(where: { $0.message.contains("source '.'") }))
    }

    @Test("No warning for normal copyPackFile source")
    func noWarningForNormalSource() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.my-hook",
            displayName: "My Hook",
            description: "A hook",
            type: .hookFile,
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: "hooks/my-hook.sh",
                destination: "my-hook",
                fileType: .hook
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("source '.'") }))
    }

    // MARK: - Settings File Source

    @Test("Detects missing settingsFile source")
    func detectsMissingSettingsFile() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.settings",
            displayName: "Settings",
            description: "Pack settings",
            type: .configuration,
            installAction: .settingsFile(source: "config/settings.json")
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let settingsFindings = findings.filter { $0.message.contains("settings file") && $0.message.contains("does not exist") }
        #expect(!settingsFindings.isEmpty)
        #expect(settingsFindings.allSatisfy { $0.severity == .error })
    }

    @Test("No warning when settingsFile source exists")
    func noWarningWhenSettingsFileExists() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configDir = tmpDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "{}".write(to: configDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let component = ExternalComponentDefinition(
            id: "test-pack.settings",
            displayName: "Settings",
            description: "Pack settings",
            type: .configuration,
            installAction: .settingsFile(source: "config/settings.json")
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("settings file") }))
    }

    // MARK: - Unreferenced Files

    @Test("Detects unreferenced file in hooks directory")
    func detectsUnreferencedHookFile() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(to: hooksDir.appendingPathComponent("orphan.sh"), atomically: true, encoding: .utf8)

        let manifest = minimalManifest(components: [])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let orphanFindings = findings.filter { $0.message.contains("hooks/orphan.sh") && $0.message.contains("not referenced") }
        #expect(!orphanFindings.isEmpty)
        #expect(orphanFindings.allSatisfy { $0.severity == .warning })
    }

    @Test("No warning when hooks file is referenced by a component")
    func noWarningWhenHookReferenced() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let hooksDir = tmpDir.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(to: hooksDir.appendingPathComponent("my-hook.sh"), atomically: true, encoding: .utf8)

        let component = ExternalComponentDefinition(
            id: "test-pack.hook",
            displayName: "My Hook",
            description: "A hook",
            type: .hookFile,
            installAction: .copyPackFile(ExternalCopyPackFileConfig(
                source: "hooks/my-hook.sh",
                destination: "my-hook",
                fileType: .hook
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("hooks/my-hook.sh") }))
    }

    @Test("Scans all non-infrastructure subdirectories")
    func scansAllSubdirectories() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for dir in ["hooks", "templates", "adapters", "docs"] {
            let dirURL = tmpDir.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try "content".write(to: dirURL.appendingPathComponent("orphan.txt"), atomically: true, encoding: .utf8)
        }

        let manifest = minimalManifest(components: [])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains(where: { $0.message.contains("hooks/orphan.txt") }))
        #expect(findings.contains(where: { $0.message.contains("templates/orphan.txt") }))
        #expect(findings.contains(where: { $0.message.contains("adapters/orphan.txt") }))
        #expect(findings.contains(where: { $0.message.contains("docs/orphan.txt") }))
    }

    @Test("Ignores .git and other infrastructure directories")
    func ignoresInfrastructureDirs() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let gitDir = tmpDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let nodeModules = tmpDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "{}".write(to: nodeModules.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let manifest = minimalManifest(components: [])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains(".git/") }))
        #expect(!findings.contains(where: { $0.message.contains("node_modules/") }))
    }

    @Test("Template contentFile references are not flagged")
    func templateContentFileNotFlagged() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let templatesDir = tmpDir.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templatesDir, withIntermediateDirectories: true)
        try "content".write(to: templatesDir.appendingPathComponent("main.md"), atomically: true, encoding: .utf8)
        try "orphan".write(to: templatesDir.appendingPathComponent("orphan.md"), atomically: true, encoding: .utf8)

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: [ExternalTemplateDefinition(
                sectionIdentifier: "test-pack.main",
                placeholders: nil,
                contentFile: "templates/main.md",
                dependencies: nil
            )],
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("templates/main.md") }))
        #expect(findings.contains(where: { $0.message.contains("templates/orphan.md") }))
    }

    // MARK: - MCP Dependency Gaps

    @Test("Detects python MCP server without brew python")
    func detectsPythonMCPWithoutBrew() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "python3",
                args: ["-m", "my_module"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let pythonFindings = findings.filter { $0.message.contains("MCP server 'my-server'") && $0.message.contains("python") }
        #expect(!pythonFindings.isEmpty)
        #expect(pythonFindings.allSatisfy { $0.severity == .warning })
    }

    @Test("No warning when brew python is present")
    func noWarningWhenBrewPythonPresent() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let server = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "python3",
                args: nil,
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let brew = ExternalComponentDefinition(
            id: "test-pack.python",
            displayName: "Python",
            description: "Python runtime",
            type: .brewPackage,
            installAction: .brewInstall(package: "python@3.12")
        )
        let manifest = minimalManifest(components: [server, brew])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("MCP server") && $0.message.contains("python") }))
    }

    @Test("Detects node MCP server without brew node")
    func detectsNodeMCPWithoutBrew() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-node-server",
                command: "npx",
                args: ["some-server"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let nodeFindings = findings.filter { $0.message.contains("MCP server 'my-node-server'") && $0.message.contains("node") }
        #expect(!nodeFindings.isEmpty)
        #expect(nodeFindings.allSatisfy { $0.severity == .warning })
    }

    // MARK: - Python Module Path

    @Test("Detects missing python module directory")
    func detectsMissingPythonModuleDir() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "python3",
                args: ["-m", "my_module"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let moduleFindings = findings.filter { $0.message.contains("module 'my_module'") && $0.message.contains("not found") }
        #expect(!moduleFindings.isEmpty)
        #expect(moduleFindings.allSatisfy { $0.severity == .warning })
    }

    @Test("No warning when python module directory exists")
    func noWarningWhenModuleDirExists() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let moduleDir = tmpDir.appendingPathComponent("my_module")
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "python3",
                args: ["-m", "my_module"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("module 'my_module'") }))
    }

    // MARK: - Empty Pack

    @Test("Warns when pack has no components, templates, or configure script")
    func warnsEmptyPack() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = minimalManifest()
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        let emptyFindings = findings.filter { $0.message.contains("nothing to install") }
        #expect(!emptyFindings.isEmpty)
        #expect(emptyFindings.allSatisfy { $0.severity == .error })
    }

    @Test("No empty-pack warning when components exist")
    func noEmptyWarningWithComponents() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.brew",
            displayName: "Node",
            description: "Node runtime",
            type: .brewPackage,
            installAction: .brewInstall(package: "node")
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("nothing to install") }))
    }

    @Test("No empty-pack warning when only templates exist")
    func noEmptyWarningWithTemplates() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let contentFile = tmpDir.appendingPathComponent("content.md")
        try "# Content".write(to: contentFile, atomically: true, encoding: .utf8)

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: [ExternalTemplateDefinition(
                sectionIdentifier: "test-pack.main",
                placeholders: nil,
                contentFile: "content.md",
                dependencies: nil
            )],
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("nothing to install") }))
    }

    @Test("No empty-pack warning when only configureProject exists")
    func noEmptyWarningWithConfigureProject() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let script = tmpDir.appendingPathComponent("configure.sh")
        try "#!/bin/bash".write(to: script, atomically: true, encoding: .utf8)

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: ExternalConfigureProject(script: "configure.sh"),
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("nothing to install") }))
    }

    // MARK: - Root-Level Content Files

    @Test("Detects unreferenced root-level content files")
    func detectsRootLevelContentFiles() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "#!/bin/bash".write(to: tmpDir.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try "config".write(to: tmpDir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        let manifest = minimalManifest(components: [])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains(where: { $0.message.contains("install.sh") && $0.severity == .warning }))
        #expect(findings.contains(where: { $0.message.contains("config.yaml") && $0.severity == .warning }))
    }

    @Test("configureProject script is not flagged as unreferenced at root")
    func configureScriptNotFlaggedAtRoot() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "#!/bin/bash".write(to: tmpDir.appendingPathComponent("configure.sh"), atomically: true, encoding: .utf8)

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: ExternalConfigureProject(script: "configure.sh"),
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("configure.sh") && $0.message.contains("not referenced") }))
    }

    @Test("configureProject script in subdirectory is not flagged as unreferenced")
    func configureScriptInSubdirNotFlagged() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let scriptsDir = tmpDir.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(to: scriptsDir.appendingPathComponent("configure.sh"), atomically: true, encoding: .utf8)

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: ExternalConfigureProject(script: "scripts/configure.sh"),
            supplementaryDoctorChecks: nil,
            ignore: nil
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("scripts/configure.sh") && $0.message.contains("not referenced") }))
    }

    @Test("Does not flag infrastructure files at root")
    func doesNotFlagInfrastructureFiles() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "# readme".write(to: tmpDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "MIT".write(to: tmpDir.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        try "schema: 1".write(to: tmpDir.appendingPathComponent("techpack.yaml"), atomically: true, encoding: .utf8)

        let manifest = minimalManifest(components: [])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("README.md") }))
        #expect(!findings.contains(where: { $0.message.contains("LICENSE") }))
        #expect(!findings.contains(where: { $0.message.contains("techpack.yaml") }))
    }

    // MARK: - Full Path Commands

    @Test("Detects python MCP server with full path command")
    func detectsFullPathPythonMCP() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "/usr/local/bin/python3",
                args: nil,
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains(where: { $0.message.contains("MCP server 'my-server'") && $0.message.contains("python") }))
    }

    // MARK: - Edge Cases

    @Test("python -m as last argument does not crash")
    func pythonDashMAsLastArg() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-server",
                command: "python3",
                args: ["-m"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("module") }))
    }

    @Test("python -m check does not trigger for non-python MCP servers")
    func pythonModuleCheckSkipsNonPython() throws {
        let tmpDir = try makeTmpDir(label: "heuristics")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let component = ExternalComponentDefinition(
            id: "test-pack.server",
            displayName: "Server",
            description: "MCP server",
            type: .mcpServer,
            installAction: .mcpServer(ExternalMCPServerConfig(
                name: "my-node-server",
                command: "node",
                args: ["-m", "some_module"],
                env: nil,
                transport: nil,
                url: nil,
                scope: nil
            ))
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains(where: { $0.message.contains("module 'some_module'") }))
    }

    // MARK: - Filesystem Error Handling

    @Test("Emits warning when pack directory does not exist")
    func warnsOnNonExistentPackDir() {
        let nonExistent = URL(fileURLWithPath: "/tmp/mcs-test-nonexistent-\(UUID().uuidString)")

        let component = ExternalComponentDefinition(
            id: "test-pack.brew",
            displayName: "Node",
            description: "Node runtime",
            type: .brewPackage,
            installAction: .brewInstall(package: "node")
        )
        let manifest = minimalManifest(components: [component])
        let findings = PackHeuristics.check(manifest: manifest, packPath: nonExistent)

        let dirWarnings = findings.filter { $0.message.contains("Could not list") }
        #expect(!dirWarnings.isEmpty)
        #expect(dirWarnings.allSatisfy { $0.severity == .warning })
    }

    // MARK: - infrastructureFilesForUpdateCheck (issue #338)

    @Test("infrastructureFilesForUpdateCheck excludes techpack.yaml (supply-chain invariant)")
    func updateCheckSetExcludesManifest() {
        #expect(!PackHeuristics.infrastructureFilesForUpdateCheck.contains(
            Constants.ExternalPacks.manifestFilename
        ))
    }

    @Test("infrastructureFilesForUpdateCheck still contains the other infra files")
    func updateCheckSetContainsInfraFiles() {
        let set = PackHeuristics.infrastructureFilesForUpdateCheck
        #expect(set.contains("README.md"))
        #expect(set.contains("LICENSE"))
        #expect(set.contains("CHANGELOG.md"))
        #expect(set.contains(".gitignore"))
        #expect(set.contains("Makefile"))
    }

    @Test("ignoredDirectories is accessible and contains expected entries")
    func ignoredDirsAccessible() {
        let dirs = PackHeuristics.ignoredDirectories
        #expect(dirs.contains(".git"))
        #expect(dirs.contains(".github"))
        #expect(dirs.contains("node_modules"))
        #expect(dirs.contains(".build"))
    }

    // MARK: - manifest ignore: silences checkUnreferencedFiles (issue #338 Phase 2)

    @Test("ignore: directory entry silences unreferenced-file warnings for that dir")
    func ignoreSilencesDirWarnings() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-ignore")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a docs/ directory that is NOT referenced by any component.
        let docsDir = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Guide".write(
            to: docsDir.appendingPathComponent("guide.md"),
            atomically: true, encoding: .utf8
        )

        let manifestWithoutIgnore = minimalManifest(components: [
            ExternalComponentDefinition(
                id: "test-pack.brew",
                displayName: "Brew",
                description: "Some package",
                type: .brewPackage,
                installAction: .brewInstall(package: "git")
            ),
        ])
        // Without ignore:, docs/guide.md is flagged.
        let baseFindings = PackHeuristics.check(manifest: manifestWithoutIgnore, packPath: tmpDir)
        let baseDocsWarnings = baseFindings.filter { $0.message.contains("docs/guide.md") }
        #expect(baseDocsWarnings.count == 1)

        // With ignore: ["docs/"], no warning.
        let manifestWithIgnore = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "test",
            author: nil,
            minMCSVersion: nil,
            components: manifestWithoutIgnore.components,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: ["docs/"]
        )
        let ignoredFindings = PackHeuristics.check(manifest: manifestWithIgnore, packPath: tmpDir)
        let ignoredDocsWarnings = ignoredFindings.filter { $0.message.contains("docs/guide.md") }
        #expect(ignoredDocsWarnings.isEmpty)
    }

    @Test("ignore: glob entry silences unreferenced-file warnings matching the pattern")
    func ignoreGlobSilencesWarnings() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-ignore-glob")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let assetsDir = tmpDir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try Data().write(to: assetsDir.appendingPathComponent("logo.png"))
        try Data().write(to: assetsDir.appendingPathComponent("notes.txt"))

        let manifest = ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "test",
            author: nil,
            minMCSVersion: nil,
            components: [
                ExternalComponentDefinition(
                    id: "test-pack.brew",
                    displayName: "Brew",
                    description: "package",
                    type: .brewPackage,
                    installAction: .brewInstall(package: "git")
                ),
            ],
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil,
            ignore: ["assets/*.png"]
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        // logo.png matches the glob → silenced; notes.txt is still flagged.
        #expect(findings.filter { $0.message.contains("assets/logo.png") }.isEmpty)
        #expect(findings.contains { $0.message.contains("assets/notes.txt") })
    }

    @Test("isIgnoredByManifest returns false when manifest has no ignore:")
    func isIgnoredByManifestEmpty() {
        let manifest = minimalManifest()
        #expect(!PackHeuristics.isIgnoredByManifest("docs/guide.md", manifest: manifest))
    }

    // MARK: - ignore: remediation hint

    @Test("Unreferenced files trigger the ignore: remediation hint")
    func unreferencedFilesEmitHint() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-hint")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let docsDir = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Guide".write(
            to: docsDir.appendingPathComponent("guide.md"),
            atomically: true, encoding: .utf8
        )

        let manifest = minimalManifest(components: [
            ExternalComponentDefinition(
                id: "test-pack.brew",
                displayName: "Brew",
                description: "package",
                type: .brewPackage,
                installAction: .brewInstall(package: "git")
            ),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(findings.contains { $0.message.contains("Add intentional non-material paths") })
    }

    @Test("No unreferenced files → no remediation hint")
    func noUnreferencedFilesNoHint() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-no-hint")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Only the techpack.yaml-equivalent root content; no extra files.
        let manifest = minimalManifest(components: [
            ExternalComponentDefinition(
                id: "test-pack.brew",
                displayName: "Brew",
                description: "package",
                type: .brewPackage,
                installAction: .brewInstall(package: "git")
            ),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("Add intentional non-material paths") })
    }

    @Test("ignore: silencing all unreferenced files removes the hint")
    func ignoreSilencesHint() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-hint-ignored")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let docsDir = tmpDir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Guide".write(
            to: docsDir.appendingPathComponent("guide.md"),
            atomically: true, encoding: .utf8
        )

        let manifest = minimalManifest(
            components: [
                ExternalComponentDefinition(
                    id: "test-pack.brew",
                    displayName: "Brew",
                    description: "package",
                    type: .brewPackage,
                    installAction: .brewInstall(package: "git")
                ),
            ],
            ignore: ["docs/"]
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("Add intentional non-material paths") })
    }

    @Test("ignore: silences root-level unreferenced file warnings")
    func ignoreSilencesRootLevelUnreferencedFile() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-root-ignore")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tmpDir.appendingPathComponent("screenshot.png"))

        let manifest = minimalManifest(
            components: [
                ExternalComponentDefinition(
                    id: "test-pack.brew",
                    displayName: "Brew",
                    description: "package",
                    type: .brewPackage,
                    installAction: .brewInstall(package: "git")
                ),
            ],
            ignore: ["screenshot.png"]
        )
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)
        #expect(!findings.contains { $0.message.contains("screenshot.png") && $0.message.contains(PackHeuristics.unreferencedMarker) })
    }

    // MARK: - Doctor Check Scope Usage (issue #354)

    private func doctorCheck(
        type: ExternalDoctorCheckType,
        name: String,
        scope: ExternalDoctorCheckScope? = nil,
        matcher: String? = nil
    ) -> ExternalDoctorCheckDefinition {
        ExternalDoctorCheckDefinition(
            type: type,
            name: name,
            section: nil,
            command: nil,
            args: nil,
            path: type == .fileExists ? ".claude/hooks/run.sh" : nil,
            pattern: nil,
            scope: scope,
            fixCommand: nil,
            fixScript: nil,
            event: type == .hookEventExists ? "SessionStart" : nil,
            matcher: matcher,
            keyPath: type == .settingsKeyEquals ? "permissions.defaultMode" : nil,
            expectedValue: type == .settingsKeyEquals ? "plan" : nil,
            isOptional: nil
        )
    }

    /// A pack with one inert component, so the empty-pack heuristic stays quiet.
    private func manifestWithDoctorChecks(
        supplementary: [ExternalDoctorCheckDefinition]? = nil,
        componentChecks: [ExternalDoctorCheckDefinition]? = nil
    ) -> ExternalPackManifest {
        minimalManifest(
            components: [
                ExternalComponentDefinition(
                    id: "test-pack.brew",
                    displayName: "Brew",
                    description: "package",
                    type: .brewPackage,
                    installAction: .brewInstall(package: "git"),
                    doctorChecks: componentChecks
                ),
            ],
            supplementaryDoctorChecks: supplementary
        )
    }

    @Test("Warns when scope is declared on a check type that ignores it")
    func warnsOnIgnoredScope() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-scope")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = manifestWithDoctorChecks(supplementary: [
            doctorCheck(type: .hookEventExists, name: "SessionStart hook", scope: .project),
            doctorCheck(type: .settingsKeyEquals, name: "Plan mode", scope: .global),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("'SessionStart hook' declares `scope`")
        })
        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("'Plan mode' declares `scope`")
        })
    }

    @Test("Does not warn about scope on path-based checks or when scope is omitted")
    func noWarningForValidScopeUsage() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-scope-ok")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = manifestWithDoctorChecks(supplementary: [
            doctorCheck(type: .fileExists, name: "Hook file", scope: .project),
            doctorCheck(type: .hookEventExists, name: "SessionStart hook", scope: nil),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains { $0.message.contains("declares `scope`") })
    }

    @Test("Warns for scope on a component-level doctor check")
    func warnsOnIgnoredScopeInComponentCheck() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-scope-component")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = manifestWithDoctorChecks(componentChecks: [
            doctorCheck(type: .settingsKeyEquals, name: "Plan mode", scope: .project),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("'Plan mode' declares `scope`")
        })
    }

    @Test("Warns when matcher is declared on a check type that ignores it")
    func warnsOnIgnoredMatcher() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-matcher")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = manifestWithDoctorChecks(supplementary: [
            doctorCheck(type: .fileExists, name: "Hook file", matcher: "Agent"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(findings.contains {
            $0.severity == .warning && $0.message.contains("'Hook file' declares `matcher`")
        })
    }

    @Test("Does not warn about matcher on hookEventExists or when matcher is omitted")
    func noWarningForValidMatcherUsage() throws {
        let tmpDir = try makeTmpDir(label: "heuristics-matcher-ok")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifest = manifestWithDoctorChecks(supplementary: [
            doctorCheck(type: .hookEventExists, name: "SessionStart hook", matcher: "Agent"),
            doctorCheck(type: .fileExists, name: "Hook file"),
        ])
        let findings = PackHeuristics.check(manifest: manifest, packPath: tmpDir)

        #expect(!findings.contains { $0.message.contains("declares `matcher`") })
    }
}
