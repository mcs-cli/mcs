import Foundation
@testable import mcs
import Testing

// MARK: - CommandFileCheck

@Suite("CommandFileCheck")
struct CommandFileCheckTests {
    private func makeTempFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("pass when file has managed marker")
    func passWithManagedMarker() throws {
        let url = try makeTempFile(content: """
        # My Command
        Some content here.
        <!-- mcs:managed -->
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = CommandFileCheck(name: "test", path: url)
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("warn when file lacks managed marker")
    func warnWithoutManagedMarker() throws {
        let url = try makeTempFile(content: """
        # My Command
        Some content with no marker.
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = CommandFileCheck(name: "test", path: url)
        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("missing managed marker"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("warn when file has unreplaced placeholder")
    func warnWithUnreplacedPlaceholder() throws {
        let url = try makeTempFile(content: """
        # My Command
        Branch pattern: __BRANCH_PREFIX__/{ticket}-*
        <!-- mcs:managed -->
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = CommandFileCheck(name: "test", path: url)
        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("__BRANCH_PREFIX__"))
        } else {
            Issue.record("Expected .warn for unreplaced placeholder, got \(result)")
        }
    }

    @Test("fail when file is missing")
    func failWhenMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).md")
        let check = CommandFileCheck(name: "test", path: url)
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("managed marker constant matches template marker")
    func managedMarkerConstant() {
        #expect(CommandFileCheck.managedMarker == "<!-- mcs:managed -->")
    }
}
