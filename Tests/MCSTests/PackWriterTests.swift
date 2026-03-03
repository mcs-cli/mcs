import Foundation
@testable import mcs
import Testing

@Suite("PackWriter")
struct PackWriterTests {
    // MARK: - Helpers

    private let output = CLIOutput(colorsEnabled: false)

    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-pack-writer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func minimalManifest() -> ExternalPackManifest {
        ExternalPackManifest(
            schemaVersion: 1,
            identifier: "test-pack",
            displayName: "Test Pack",
            description: "A test pack",
            author: nil,
            minMCSVersion: nil,
            components: nil,
            templates: nil,
            prompts: nil,
            configureProject: nil,
            supplementaryDoctorChecks: nil
        )
    }

    private func minimalResult() -> ManifestBuilder.BuildResult {
        ManifestBuilder.BuildResult(
            manifest: minimalManifest(),
            manifestYAML: "schemaVersion: 1\nidentifier: test-pack\n",
            filesToCopy: [],
            settingsToWrite: nil,
            templateFiles: []
        )
    }

    // MARK: - Happy Path

    @Test("write creates expected files")
    func writeCreatesExpectedFiles() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a source file to copy
        let sourceFile = tmpDir.appendingPathComponent("hook.sh")
        try "#!/bin/bash".write(to: sourceFile, atomically: true, encoding: .utf8)

        let outputDir = tmpDir.appendingPathComponent("output")
        let settingsJSON = try JSONSerialization.data(
            withJSONObject: ["key": "value"], options: .prettyPrinted
        )

        let result = ManifestBuilder.BuildResult(
            manifest: minimalManifest(),
            manifestYAML: "schemaVersion: 1\n",
            filesToCopy: [
                ManifestBuilder.FileCopy(
                    source: sourceFile,
                    destinationDir: "hooks",
                    filename: "hook.sh"
                ),
            ],
            settingsToWrite: settingsJSON,
            templateFiles: [
                ManifestBuilder.TemplateFile(
                    sectionIdentifier: "test-pack.claude-md",
                    filename: "claude.md.template",
                    content: "# Template"
                ),
            ]
        )

        let writer = PackWriter(output: output)
        try writer.write(result: result, to: outputDir)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("techpack.yaml").path))
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("hooks/hook.sh").path))
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("config/settings.json").path))
        #expect(fm.fileExists(atPath: outputDir.appendingPathComponent("templates/claude.md.template").path))
    }

    // MARK: - Cleanup on Failure

    @Test("write cleans up partial directory on failure")
    func writeCleansUpOnFailure() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputDir = tmpDir.appendingPathComponent("output")

        // Reference a non-existent source file to trigger a copy failure
        let bogusSource = tmpDir.appendingPathComponent("does-not-exist.sh")
        let result = ManifestBuilder.BuildResult(
            manifest: minimalManifest(),
            manifestYAML: "schemaVersion: 1\n",
            filesToCopy: [
                ManifestBuilder.FileCopy(
                    source: bogusSource,
                    destinationDir: "hooks",
                    filename: "hook.sh"
                ),
            ],
            settingsToWrite: nil,
            templateFiles: []
        )

        let writer = PackWriter(output: output)
        #expect(throws: Error.self) {
            try writer.write(result: result, to: outputDir)
        }

        // The partial output directory should have been removed
        #expect(!FileManager.default.fileExists(atPath: outputDir.path))
    }

    // MARK: - Pre-existing Directory

    @Test("write throws if output directory already exists")
    func writeThrowsIfOutputExists() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let outputDir = tmpDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let writer = PackWriter(output: output)
        #expect(throws: ExportError.self) {
            try writer.write(result: minimalResult(), to: outputDir)
        }
    }
}
