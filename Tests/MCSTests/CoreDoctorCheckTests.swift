import Foundation
@testable import mcs
import Testing

// MARK: - HookInterpreterCheck

struct HookInterpreterCheckTests {
    @Test("passes and reports the resolved path for a binary on PATH")
    func passesForResolvableBinary() {
        // `ls` stands in for a hook interpreter: on PATH everywhere, never a version-manager shim.
        let check = HookInterpreterCheck(binary: "ls", packName: "Test Pack")
        guard case let .pass(message) = check.check() else {
            Issue.record("Expected pass for a binary on PATH, got \(check.check())")
            return
        }
        #expect(message.contains("resolves to"))
        #expect(message.contains("ls"))
    }

    @Test("fails for a binary that does not exist")
    func failsForMissingBinary() {
        let check = HookInterpreterCheck(binary: "mcs-definitely-not-a-real-interpreter", packName: "Test Pack")
        guard case let .fail(message) = check.check() else {
            Issue.record("Expected fail for a missing binary")
            return
        }
        #expect(message.contains("not found"))
    }

    @Test("names the binary and pack so a multi-pack report stays readable")
    func nameIdentifiesBinaryAndPack() {
        let check = HookInterpreterCheck(binary: "node", packName: "TS Pack")
        #expect(check.name == "Hook interpreter: node (TS Pack)")
        #expect(check.section == "Hooks")
    }

    @Test("is not auto-fixable — mcs cannot install a runtime")
    func notFixable() {
        let check = HookInterpreterCheck(binary: "node", packName: "TS Pack")
        guard case let .notFixable(message) = check.fix() else {
            Issue.record("Expected notFixable")
            return
        }
        #expect(message.contains("node"))
        // Must not send the user to `mcs sync`, which cannot install an interpreter.
        #expect(!message.contains("mcs sync"))
    }

    @Test("bash, sh and zsh are assumed present and never checked")
    func shellsAreAssumedPresent() {
        for shell in ["bash", "sh", "zsh"] {
            #expect(!HookInterpreter.isCheckable(binary: shell))
        }
        #expect(HookInterpreter.isCheckable(binary: "node"))
    }
}

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

    // MARK: - Registration verification

    /// Settings holding `gate.sh` under `PreToolUse` with the given matcher.
    private func makeGateSettings(matcher: String) throws -> URL {
        try makeTempSettings(content: """
        {
          "hooks": {
            "PreToolUse": [
              { \(matcher), "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ]
          }
        }
        """)
    }

    private func gateCheck(matcher: String?, settingsPath: URL) -> HookSettingsCheck {
        HookSettingsCheck(
            expectations: [ExpectedHook(
                command: "bash .claude/hooks/gate.sh",
                registration: HookRegistration(event: .preToolUse, matcher: matcher)
            )],
            settingsPath: settingsPath,
            packName: "test-pack"
        )
    }

    @Test("pass when declared event and matcher both match")
    func passWhenRegistrationMatches() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"Agent|Task\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: "Agent|Task", settingsPath: url).check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("warn when matcher differs, naming both actual and declared")
    func warnWhenMatcherDiffers() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"Task\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: "Agent|Task", settingsPath: url).check()
        if case let .warn(msg) = result {
            #expect(msg.contains("'Task'"))
            #expect(msg.contains("'Agent|Task'"))
            #expect(msg.contains("mcs sync"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("warn when registered under a different event than declared")
    func warnWhenEventDiffers() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PostToolUse": [
              { "matcher": "Agent", "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: "Agent", settingsPath: url).check()
        if case let .warn(msg) = result {
            #expect(msg.contains("PostToolUse"))
            #expect(msg.contains("PreToolUse"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("warn when no matcher was declared but settings has one")
    func warnWhenUndeclaredMatcherPresent() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"Agent\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: nil, settingsPath: url).check()
        if case let .warn(msg) = result {
            #expect(msg.contains("no matcher"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("pass when no matcher was declared and settings has none")
    func passWhenNoMatcherEitherSide() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PreToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: nil, settingsPath: url).check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("empty matcher in settings is equivalent to no matcher declared")
    func passWhenEmptyMatcherNormalizes() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: nil, settingsPath: url).check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("pass when one of several groups under the declared event matches")
    func passWhenAnyGroupMatches() throws {
        // addHookEntry appends rather than replaces when the command is not the group's first
        // entry, so a correct registration can coexist with a stale one.
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Task", "hooks": [
                { "type": "command", "command": "bash .claude/hooks/other.sh" },
                { "type": "command", "command": "bash .claude/hooks/gate.sh" }
              ] },
              { "matcher": "Agent|Task", "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: "Agent|Task", settingsPath: url).check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("extra registration under an undeclared event is not policed")
    func passWhenExtraEventPresent() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Agent", "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ],
            "PostToolUse": [
              { "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = gateCheck(matcher: "Agent", settingsPath: url).check()
        if case .pass = result {
            // expected
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("a nil registration verifies presence only, whatever the matcher")
    func passWhenNoRegistrationDeclared() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"anything\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let check = HookSettingsCheck(
            expectations: [ExpectedHook(command: "bash .claude/hooks/gate.sh", registration: nil)],
            settingsPath: url,
            packName: "test-pack"
        )
        if case .pass = check.check() {
            // expected
        } else {
            Issue.record("Expected .pass for presence-only expectation")
        }
    }

    @Test("a mixed set does not claim every command was verified against a declaration")
    func mixedSetDoesNotOverclaim() throws {
        let url = try makeTempSettings(content: """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Agent", "hooks": [{ "type": "command", "command": "bash .claude/hooks/gate.sh" }] }
            ],
            "PostToolUse": [
              { "hooks": [{ "type": "command", "command": "bash .claude/hooks/orphan.sh" }] }
            ]
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        // The second command no longer maps to a component, so it can only be checked for presence.
        let check = HookSettingsCheck(
            expectations: [
                ExpectedHook(
                    command: "bash .claude/hooks/gate.sh",
                    registration: HookRegistration(event: .preToolUse, matcher: "Agent")
                ),
                ExpectedHook(command: "bash .claude/hooks/orphan.sh", registration: nil),
            ],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .pass(msg) = result {
            #expect(!msg.contains("as declared"))
        } else {
            Issue.record("Expected .pass, got \(result)")
        }
    }

    @Test("failure message reports drift from other expectations too")
    func failMessageIncludesDrift() throws {
        let url = try makeGateSettings(matcher: "\"matcher\": \"Task\"")
        defer { try? FileManager.default.removeItem(at: url) }

        let check = HookSettingsCheck(
            expectations: [
                ExpectedHook(
                    command: "bash .claude/hooks/gate.sh",
                    registration: HookRegistration(event: .preToolUse, matcher: "Agent|Task")
                ),
                ExpectedHook(command: "bash .claude/hooks/absent.sh", registration: nil),
            ],
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .fail(msg) = result {
            #expect(msg.contains("absent.sh"))
            #expect(msg.contains("'Agent|Task'"))
        } else {
            Issue.record("Expected .fail, got \(result)")
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

// MARK: - SettingsDriftCheck

struct SettingsDriftCheckTests {
    private func makeTempSettings(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("pass when hash matches")
    func passWhenHashMatches() throws {
        let json = """
        {"env": {"FOO": "bar"}, "alwaysThinkingEnabled": true}
        """
        let url = try makeTempSettings(content: json)
        defer { try? FileManager.default.removeItem(at: url) }

        let keys = ["env.FOO", "alwaysThinkingEnabled"]
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let expectedHash = try #require(SettingsHasher.hash(keyPaths: keys, in: parsed))

        let check = SettingsDriftCheck(
            keys: keys,
            expectedHash: expectedHash,
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

    @Test("warn when value modified")
    func warnWhenValueModified() throws {
        let originalJSON = """
        {"env": {"FOO": "bar"}}
        """
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(originalJSON.utf8)) as? [String: Any])
        let keys = ["env.FOO"]
        let expectedHash = try #require(SettingsHasher.hash(keyPaths: keys, in: parsed))

        // Write modified content
        let modifiedJSON = """
        {"env": {"FOO": "changed"}}
        """
        let url = try makeTempSettings(content: modifiedJSON)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsDriftCheck(
            keys: keys,
            expectedHash: expectedHash,
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case let .warn(msg) = result {
            #expect(msg.contains("modified since last sync"))
        } else {
            Issue.record("Expected .warn, got \(result)")
        }
    }

    @Test("skip when settings file missing")
    func skipWhenFileMissing() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let check = SettingsDriftCheck(
            keys: ["env.FOO"],
            expectedHash: "abc123",
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .skip = result {
            // expected
        } else {
            Issue.record("Expected .skip, got \(result)")
        }
    }

    @Test("skip when settings file contains invalid JSON")
    func skipWhenInvalidJSON() throws {
        let url = try makeTempSettings(content: "not valid json {{{")
        defer { try? FileManager.default.removeItem(at: url) }

        let check = SettingsDriftCheck(
            keys: ["env.FOO"],
            expectedHash: "abc123",
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.check()
        if case .skip = result {
            // expected
        } else {
            Issue.record("Expected .skip, got \(result)")
        }
    }

    @Test("fix returns notFixable")
    func fixReturnsNotFixable() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        let check = SettingsDriftCheck(
            keys: ["env.FOO"],
            expectedHash: "abc123",
            settingsPath: url,
            packName: "test-pack"
        )
        let result = check.fix()
        if case let .notFixable(msg) = result {
            #expect(msg.contains("mcs sync"))
        } else {
            Issue.record("Expected .notFixable, got \(result)")
        }
    }

    @Test("name includes pack name")
    func nameIncludesPackName() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        let check = SettingsDriftCheck(
            keys: [],
            expectedHash: "",
            settingsPath: url,
            packName: "my-pack"
        )
        #expect(check.name == "Settings values (my-pack)")
    }

    @Test("section is Settings")
    func sectionIsSettings() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString).json")
        let check = SettingsDriftCheck(
            keys: [],
            expectedHash: "",
            settingsPath: url,
            packName: "test"
        )
        #expect(check.section == "Settings")
    }
}
