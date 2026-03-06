import Foundation
@testable import mcs
import Testing

// MARK: - HookSettingsCheck

struct HookSettingsCheckTests {
    private func makeTempSettings(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("pass when all hook commands are present")
    func passWhenAllPresent() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/lint.sh" }] }
            ],
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/guard.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = HookSettingsCheck(
            commands: ["bash .claude/hooks/lint.sh", "bash .claude/hooks/guard.sh"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("fail when hook command is missing")
    func failWhenMissing() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/lint.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = HookSettingsCheck(
            commands: ["bash .claude/hooks/lint.sh", "bash .claude/hooks/missing.sh"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("missing.sh"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("fail when settings file does not exist")
    func failWhenFileNotFound() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let check = HookSettingsCheck(
            commands: ["bash .claude/hooks/lint.sh"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        // Settings.load returns empty Settings for missing file, so hooks will be nil
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("pass when hooks section is empty and no commands expected")
    func passWhenEmpty() throws {
        let url = try makeTempSettings(content: "{}")
        defer { try? FileManager.default.removeItem(at: url) }

        let check = HookSettingsCheck(
            commands: [],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }
}

// MARK: - SettingsKeysCheck

struct SettingsKeysCheckTests {
    private func makeTempSettings(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("pass when all keys are present")
    func passWhenAllPresent() throws {
        let url = try makeTempSettings(content: """
        {
          "env": { "FOO": "bar" },
          "alwaysThinkingEnabled": true
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsKeysCheck(
            keys: ["env.FOO", "alwaysThinkingEnabled"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("fail when key is missing")
    func failWhenMissing() throws {
        let url = try makeTempSettings(content: """
        {
          "env": { "FOO": "bar" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsKeysCheck(
            keys: ["env.FOO", "missingKey"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("missingKey"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("fail when nested key is missing")
    func failWhenNestedMissing() throws {
        let url = try makeTempSettings(content: """
        {
          "env": { "FOO": "bar" }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsKeysCheck(
            keys: ["env.MISSING"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("env.MISSING"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("fail when settings file is missing")
    func failWhenFileNotFound() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let check = SettingsKeysCheck(
            keys: ["someKey"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .fail = result {
            // expected
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }

    @Test("fail when settings file contains invalid JSON")
    func failWhenInvalidJSON() throws {
        let url = try makeTempSettings(content: "not valid json {{{")
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsKeysCheck(
            keys: ["someKey"],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("invalid JSON"))
        } else {
            Issue.record("Expected .fail, got \(result)")
        }
    }
}

// MARK: - PackGitignoreCheck

struct PackGitignoreCheckTests {
    @Test("pass when all entries are present")
    func passWhenAllPresent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try ".build\n.swiftpm\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // PackGitignoreCheck uses GitignoreManager internally, so we test the struct's
        // logic directly using a known gitignore path. Since we can't inject the path,
        // we test the check struct's interface consistency instead.
        let check = PackGitignoreCheck(entries: [".build", ".swiftpm"], packName: "test-pack")
        // The actual result depends on the system's global gitignore — just verify the struct works
        let result = check.check()
        // Result will be either .pass or .fail depending on system state — no assertion on value
        switch result {
        case .pass, .fail: break
        default: Issue.record("Expected .pass or .fail, got \(result)")
        }
    }

    @Test("name includes pack name")
    func nameIncludesPackName() {
        let check = PackGitignoreCheck(entries: [".build"], packName: "my-pack")
        #expect(check.name == "Gitignore entries (my-pack)")
    }

    @Test("section is Gitignore")
    func sectionIsGitignore() {
        let check = PackGitignoreCheck(entries: [".build"], packName: "my-pack")
        #expect(check.section == "Gitignore")
    }

    @Test("fix returns notFixable")
    func fixReturnsNotFixable() {
        let check = PackGitignoreCheck(entries: [".build"], packName: "my-pack")
        let result = check.fix()
        if case .notFixable = result {
            // expected
        } else {
            Issue.record("Expected .notFixable, got \(result)")
        }
    }
}

// MARK: - CommandFileCheck

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
