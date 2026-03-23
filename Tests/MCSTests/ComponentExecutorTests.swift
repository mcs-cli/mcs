import Foundation
@testable import mcs
import Testing

struct ComponentExecutorTests {
    private func makeExecutor() -> ComponentExecutor {
        let env = Environment()
        return ComponentExecutor(
            environment: env,
            output: CLIOutput(),
            shell: ShellRunner(environment: env),
            claudeCLI: ClaudeIntegration(shell: ShellRunner(environment: env))
        )
    }

    // MARK: - removeProjectFile path containment

    @Test("Removes file within project directory")
    func removesFileInsideProject() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let exec = makeExecutor()
        exec.removeProjectFile(relativePath: "test.txt", projectPath: tmpDir)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Blocks path traversal via ../")
    func blocksPathTraversal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a file outside the project directory
        let outsideFile = tmpDir
            .deletingLastPathComponent()
            .appendingPathComponent("mcs-traversal-target-\(UUID().uuidString).txt")
        try "sensitive".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let exec = makeExecutor()
        exec.removeProjectFile(
            relativePath: "../\(outsideFile.lastPathComponent)",
            projectPath: tmpDir
        )

        // File outside project must NOT be deleted
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    @Test("Blocks deeply nested path traversal")
    func blocksDeeplyNestedTraversal() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outsideFile = tmpDir
            .deletingLastPathComponent()
            .appendingPathComponent("mcs-deep-target-\(UUID().uuidString).txt")
        try "sensitive".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let exec = makeExecutor()
        exec.removeProjectFile(
            relativePath: "subdir/../../\(outsideFile.lastPathComponent)",
            projectPath: tmpDir
        )

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    // MARK: - installProjectFile placeholder substitution

    @Test("installProjectFile substitutes PROJECT_DIR_NAME and REPO_NAME placeholders")
    func projectDirNameSubstitution() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let packDir = tmpDir.appendingPathComponent("pack/my-skill")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
        try "Dir: __PROJECT_DIR_NAME__, Repo: __REPO_NAME__".write(
            to: packDir.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: packDir,
            destination: "my-skill",
            fileType: .skill,
            projectPath: projectPath,
            resolvedValues: ["PROJECT_DIR_NAME": "my-folder", "REPO_NAME": "my-app"]
        )

        #expect(!result.paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/skills/my-skill/SKILL.md")
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("Dir: my-folder"))
        #expect(content.contains("Repo: my-app"))
        #expect(!content.contains("__PROJECT_DIR_NAME__"))
        #expect(!content.contains("__REPO_NAME__"))
    }

    @Test("installProjectFile with agent fileType installs to .claude/agents/")
    func installProjectFileAgentType() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let agentFile = tmpDir.appendingPathComponent("code-reviewer.md")
        try "---\nname: Code Reviewer\n---\nReview code".write(
            to: agentFile,
            atomically: true, encoding: .utf8
        )

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: agentFile,
            destination: "code-reviewer.md",
            fileType: .agent,
            projectPath: projectPath,
            resolvedValues: [:]
        )

        #expect(!result.paths.isEmpty)

        let installed = projectPath.appendingPathComponent(".claude/agents/code-reviewer.md")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        let content = try String(contentsOf: installed, encoding: .utf8)
        #expect(content.contains("Code Reviewer"))
    }

    // MARK: - installProjectFile hash recording

    @Test("installProjectFile returns SHA-256 hashes of installed files")
    func installProjectFileRecordsHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let projectPath = tmpDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let source = tmpDir.appendingPathComponent("test-hook.sh")
        try "#!/bin/bash\necho test".write(to: source, atomically: true, encoding: .utf8)

        var exec = makeExecutor()
        let result = exec.installProjectFile(
            source: source,
            destination: "test-hook.sh",
            fileType: .hook,
            projectPath: projectPath
        )

        #expect(result.paths.count == 1)
        #expect(result.hashes.count == 1)

        let installed = projectPath.appendingPathComponent(".claude/hooks/test-hook.sh")
        let expectedHash = try FileHasher.sha256(of: installed)
        #expect(result.hashes.values.first == expectedHash)
    }
}
