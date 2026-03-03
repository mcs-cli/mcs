import Foundation
@testable import mcs
import Testing

@Suite("PromptExecutor")
struct PromptExecutorTests {
    /// Create a unique temp directory for each test.
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-prompt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a PromptExecutor for testing.
    private func makeExecutor() -> PromptExecutor {
        PromptExecutor(
            output: CLIOutput(colorsEnabled: false),
            scriptRunner: ScriptRunner(
                shell: ShellRunner(environment: Environment()),
                output: CLIOutput(colorsEnabled: false)
            )
        )
    }

    /// Write a script file to disk with executable permission.
    private func writeScript(_ content: String, at url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - File Detection (static method)

    @Test("detectFiles finds files matching extension pattern")
    func detectFilesWithExtension() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("App.xcodeproj"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Lib.xcodeproj"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: "*.xcodeproj", in: tmpDir)

        #expect(matches.count == 2)
        #expect(matches.contains("App.xcodeproj"))
        #expect(matches.contains("Lib.xcodeproj"))
        #expect(!matches.contains("README.md"))
    }

    @Test("detectFiles returns sorted results")
    func detectFilesSorted() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("Zebra.swift"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Apple.swift"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Mango.swift"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: "*.swift", in: tmpDir)

        #expect(matches == ["Apple.swift", "Mango.swift", "Zebra.swift"])
    }

    @Test("detectFiles with wildcard pattern returns all non-hidden files")
    func detectFilesWildcard() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("script.sh"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: "*", in: tmpDir)

        #expect(matches.contains("file.txt"))
        #expect(matches.contains("script.sh"))
        #expect(!matches.contains(".hidden"))
    }

    @Test("detectFiles returns empty array for missing directory")
    func detectFilesMissingDir() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        let matches = PromptExecutor.detectFiles(matching: "*.txt", in: missing)

        #expect(matches.isEmpty)
    }

    @Test("detectFiles returns empty array when no files match")
    func detectFilesNoMatches() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: "*.swift", in: tmpDir)

        #expect(matches.isEmpty)
    }

    @Test("detectFiles with literal filename matches exact name")
    func detectFilesLiteralName() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Makefile.bak"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: "Makefile", in: tmpDir)

        #expect(matches == ["Makefile"])
    }

    // MARK: - Multi-pattern detection

    @Test("detectFiles with multiple patterns returns results in pattern order")
    func detectFilesMultiplePatterns() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("App.xcodeproj"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("App.xcworkspace"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Lib.xcodeproj"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Workspaces first, then projects
        let matches = PromptExecutor.detectFiles(
            matching: ["*.xcworkspace", "*.xcodeproj"],
            in: tmpDir
        )

        #expect(matches == ["App.xcworkspace", "App.xcodeproj", "Lib.xcodeproj"])
        #expect(!matches.contains("README.md"))
    }

    @Test("detectFiles with multiple patterns deduplicates across patterns")
    func detectFilesMultiPatternDedup() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("App.xcodeproj"), atomically: true, encoding: .utf8)

        // Same file matched by both patterns — should appear only once
        let matches = PromptExecutor.detectFiles(
            matching: ["*.xcodeproj", "*.xcodeproj"],
            in: tmpDir
        )

        #expect(matches == ["App.xcodeproj"])
    }

    @Test("detectFiles with empty patterns array returns empty")
    func detectFilesEmptyPatterns() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "".write(to: tmpDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let matches = PromptExecutor.detectFiles(matching: [], in: tmpDir)

        #expect(matches.isEmpty)
    }

    // MARK: - YAML deserialization (string vs array)

    @Test("detectPattern YAML string deserializes to single-element array")
    func detectPatternYAMLString() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        prompts:
          - key: project
            type: fileDetect
            label: "Project"
            detectPattern: "*.xcodeproj"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(manifest.prompts?[0].detectPatterns == ["*.xcodeproj"])
    }

    @Test("detectPattern YAML array deserializes to array")
    func detectPatternYAMLArray() throws {
        let yaml = """
        schemaVersion: 1
        identifier: test
        displayName: Test
        description: Test
        version: "1.0.0"
        prompts:
          - key: project
            type: fileDetect
            label: "Project"
            detectPattern:
              - "*.xcworkspace"
              - "*.xcodeproj"
        """

        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("techpack.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)

        let manifest = try ExternalPackManifest.load(from: file)
        #expect(manifest.prompts?[0].detectPatterns == ["*.xcworkspace", "*.xcodeproj"])
    }

    // MARK: - Script Prompt Execution

    @Test("Script prompt captures stdout as value")
    func scriptPromptCapturesStdout() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let prompt = PromptDefinition(
            key: "version",
            type: .script,
            label: "Detected version",
            defaultValue: nil,
            options: nil,
            detectPatterns: nil,
            scriptCommand: "echo 2.1.0"
        )

        let executor = makeExecutor()
        let value = try executor.execute(
            prompt: prompt,
            packPath: packDir,
            projectPath: tmpDir
        )

        #expect(value == "2.1.0")
    }

    @Test("Script prompt throws on failure")
    func scriptPromptThrowsOnFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let prompt = PromptDefinition(
            key: "broken",
            type: .script,
            label: "Broken script",
            defaultValue: nil,
            options: nil,
            detectPatterns: nil,
            scriptCommand: "echo error >&2 && exit 1"
        )

        let executor = makeExecutor()
        #expect(throws: PromptExecutor.PromptError.self) {
            try executor.execute(
                prompt: prompt,
                packPath: packDir,
                projectPath: tmpDir
            )
        }
    }

    @Test("Script prompt returns default when no scriptCommand")
    func scriptPromptDefaultValue() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let prompt = PromptDefinition(
            key: "fallback",
            type: .script,
            label: "No script",
            defaultValue: "default-val",
            options: nil,
            detectPatterns: nil,
            scriptCommand: nil
        )

        let executor = makeExecutor()
        let value = try executor.execute(
            prompt: prompt,
            packPath: tmpDir,
            projectPath: tmpDir
        )

        #expect(value == "default-val")
    }

    // MARK: - executeAll

    @Test("executeAll runs multiple script prompts and returns all values")
    func executeAllPrompts() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packDir = tmpDir.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        let prompts = [
            PromptDefinition(
                key: "version",
                type: .script,
                label: nil,
                defaultValue: nil,
                options: nil,
                detectPatterns: nil,
                scriptCommand: "echo 1.0.0"
            ),
            PromptDefinition(
                key: "name",
                type: .script,
                label: nil,
                defaultValue: nil,
                options: nil,
                detectPatterns: nil,
                scriptCommand: "echo my-app"
            ),
        ]

        let executor = makeExecutor()
        let resolved = try executor.executeAll(
            prompts: prompts,
            packPath: packDir,
            projectPath: tmpDir
        )

        #expect(resolved["version"] == "1.0.0")
        #expect(resolved["name"] == "my-app")
    }

    // MARK: - Select prompt (non-interactive verification)

    @Test("Select prompt with no options returns default value")
    func selectPromptNoOptions() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let prompt = PromptDefinition(
            key: "empty-select",
            type: .select,
            label: "Pick one",
            defaultValue: "fallback",
            options: [],
            detectPatterns: nil,
            scriptCommand: nil
        )

        let executor = makeExecutor()
        let value = try executor.execute(
            prompt: prompt,
            packPath: tmpDir,
            projectPath: tmpDir
        )

        #expect(value == "fallback")
    }

    @Test("Select prompt with nil options returns default value")
    func selectPromptNilOptions() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let prompt = PromptDefinition(
            key: "nil-select",
            type: .select,
            label: "Pick one",
            defaultValue: "default-pick",
            options: nil,
            detectPatterns: nil,
            scriptCommand: nil
        )

        let executor = makeExecutor()
        let value = try executor.execute(
            prompt: prompt,
            packPath: tmpDir,
            projectPath: tmpDir
        )

        #expect(value == "default-pick")
    }
}
