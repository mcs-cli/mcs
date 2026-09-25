import Foundation
@testable import mcs
import Testing

struct SyncStrategyTests {
    private func makeStrategy(projectPath: URL) -> ProjectSyncStrategy {
        ProjectSyncStrategy(projectPath: projectPath, environment: Environment())
    }

    private func makeOutsideFile(near dir: URL) throws -> URL {
        let file = dir
            .deletingLastPathComponent()
            .appendingPathComponent("mcs-traversal-target-\(UUID().uuidString).txt")
        try "sensitive".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: - removeFileArtifact path containment

    @Test("Removes file within the artifact base")
    func removesFileInsideBase() throws {
        let tmpDir = try makeTmpDir(label: "strategy")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("test.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let removed = makeStrategy(projectPath: tmpDir)
            .removeFileArtifact(relativePath: "test.txt", output: CLIOutput(colorsEnabled: false))

        #expect(removed)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Blocks path traversal", arguments: ["../", "subdir/../../"])
    func blocksPathTraversal(prefix: String) throws {
        let tmpDir = try makeTmpDir(label: "strategy")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let outsideFile = try makeOutsideFile(near: tmpDir)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        _ = makeStrategy(projectPath: tmpDir).removeFileArtifact(
            relativePath: prefix + outsideFile.lastPathComponent,
            output: CLIOutput(colorsEnabled: false)
        )

        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
