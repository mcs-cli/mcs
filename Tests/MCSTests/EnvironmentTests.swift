import Foundation
@testable import mcs
import Testing

@Suite("Environment")
struct EnvironmentTests {
    /// Create a unique temp directory simulating a home directory.
    private func makeTmpHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-env-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Path construction

    @Test("Environment paths are relative to home directory")
    func pathsRelativeToHome() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        #expect(env.claudeDirectory.path == home.appendingPathComponent(".claude").path)
        #expect(env.claudeJSON.path == home.appendingPathComponent(".claude.json").path)
        #expect(env.claudeSettings.path ==
            home.appendingPathComponent(".claude/settings.json").path)
    }
}
