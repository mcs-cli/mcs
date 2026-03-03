import Foundation
@testable import mcs
import Testing

@Suite("Settings deep-merge")
struct SettingsMergeTests {
    /// Create a unique temporary directory for test isolation.
    /// Caller is responsible for cleanup (typically via `defer`).
    private static func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Serialize a value to a JSON fragment for use as an `extraJSON` entry.
    private static func jsonFragment(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    }

    // MARK: - Merge into empty / default settings

    @Test("Merging into empty settings copies all fields")
    func mergeIntoEmpty() throws {
        var base = Settings()
        let other = try Settings(
            hooks: [
                "PreToolUse": [
                    Settings.HookGroup(
                        matcher: "Edit",
                        hooks: [Settings.HookEntry(type: "command", command: "echo hi")]
                    ),
                ],
            ],
            enabledPlugins: ["my-plugin": true],
            extraJSON: [
                "env": Self.jsonFragment(["KEY": "value"]),
                "permissions": Self.jsonFragment(["defaultMode": "allowEdits"]),
                "alwaysThinkingEnabled": Self.jsonFragment(true),
            ]
        )

        base.merge(with: other)

        let envData = try #require(base.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["KEY"] == "value")
        let permsData = try #require(base.extraJSON["permissions"])
        let perms = try #require(JSONSerialization.jsonObject(with: permsData) as? [String: Any])
        #expect(perms["defaultMode"] as? String == "allowEdits")
        #expect(base.hooks?["PreToolUse"]?.count == 1)
        #expect(base.enabledPlugins?["my-plugin"] == true)
        let thinkingData = try #require(base.extraJSON["alwaysThinkingEnabled"])
        let thinking = try #require(
            JSONSerialization.jsonObject(with: thinkingData, options: .fragmentsAllowed) as? Bool
        )
        #expect(thinking == true)
    }

    // MARK: - Preserve existing user settings

    @Test("Existing env vars are preserved during merge")
    func envPreserveExisting() throws {
        var base = try Settings(extraJSON: [
            "env": Self.jsonFragment(["EXISTING": "keep", "SHARED": "original"]),
        ])
        let other = try Settings(extraJSON: [
            "env": Self.jsonFragment(["SHARED": "overwrite-attempt", "NEW": "added"]),
        ])

        base.merge(with: other)

        let envData = try #require(base.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["EXISTING"] == "keep")
        #expect(env["SHARED"] == "original") // existing NOT overwritten
        #expect(env["NEW"] == "added")
    }

    @Test("Existing plugins are preserved during merge")
    func pluginPreserveExisting() {
        var base = Settings(enabledPlugins: ["user-plugin": true])
        let other = Settings(enabledPlugins: ["user-plugin": false, "new-plugin": true])

        base.merge(with: other)

        #expect(base.enabledPlugins?["user-plugin"] == true) // not overwritten
        #expect(base.enabledPlugins?["new-plugin"] == true) // added
    }

    // MARK: - Hook deduplication by command

    @Test("Hooks are deduplicated by command field")
    func hookDeduplication() {
        let existingHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo existing")]
        )
        let duplicateHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo existing")]
        )
        let newHook = Settings.HookGroup(
            matcher: "Edit",
            hooks: [Settings.HookEntry(type: "command", command: "echo new")]
        )

        var base = Settings(hooks: ["PreToolUse": [existingHook]])
        let other = Settings(hooks: ["PreToolUse": [duplicateHook, newHook]])

        base.merge(with: other)

        let groups = base.hooks?["PreToolUse"] ?? []
        #expect(groups.count == 2) // existing + new, duplicate skipped
        let commands = groups.compactMap { $0.hooks?.first?.command }
        #expect(commands.contains("echo existing"))
        #expect(commands.contains("echo new"))
    }

    @Test("Hooks merge across different events")
    func hooksMergeDifferentEvents() {
        var base = Settings(hooks: [
            "PreToolUse": [
                Settings.HookGroup(
                    matcher: "Edit",
                    hooks: [Settings.HookEntry(type: "command", command: "echo pre")]
                ),
            ],
        ])
        let other = Settings(hooks: [
            "PostToolUse": [
                Settings.HookGroup(
                    matcher: "Edit",
                    hooks: [Settings.HookEntry(type: "command", command: "echo post")]
                ),
            ],
        ])

        base.merge(with: other)

        #expect(base.hooks?["PreToolUse"]?.count == 1)
        #expect(base.hooks?["PostToolUse"]?.count == 1)
    }

    // MARK: - Plugin merge is additive

    @Test("Plugin merge adds new entries without overwriting")
    func pluginMergeAdditive() {
        var base = Settings(enabledPlugins: ["a": true, "b": false])
        let other = Settings(enabledPlugins: ["b": true, "c": true])

        base.merge(with: other)

        #expect(base.enabledPlugins?["a"] == true)
        #expect(base.enabledPlugins?["b"] == false) // original kept
        #expect(base.enabledPlugins?["c"] == true) // new added
    }

    // MARK: - alwaysThinkingEnabled merge

    @Test("Scalar extraJSON only set if base is nil")
    func scalarMergeExistingWins() throws {
        var base = try Settings(extraJSON: [
            "alwaysThinkingEnabled": Self.jsonFragment(false),
        ])
        let other = try Settings(extraJSON: [
            "alwaysThinkingEnabled": Self.jsonFragment(true),
        ])

        base.merge(with: other)

        let result = try #require(JSONSerialization.jsonObject(
            with: #require(base.extraJSON["alwaysThinkingEnabled"]), options: .fragmentsAllowed
        ) as? Bool)
        #expect(result == false) // existing preserved
    }

    @Test("Scalar extraJSON adopted from other when base is nil")
    func scalarMergeFromNil() throws {
        var base = Settings()
        let other = try Settings(extraJSON: [
            "alwaysThinkingEnabled": Self.jsonFragment(true),
        ])

        base.merge(with: other)

        let result = try #require(JSONSerialization.jsonObject(
            with: #require(base.extraJSON["alwaysThinkingEnabled"]), options: .fragmentsAllowed
        ) as? Bool)
        #expect(result == true)
    }

    // MARK: - File I/O round-trip

    @Test("Settings save and load round-trip")
    func saveAndLoad() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        let original = try Settings(
            enabledPlugins: ["p": true],
            extraJSON: [
                "env": Self.jsonFragment(["FOO": "bar"]),
                "permissions": Self.jsonFragment(["defaultMode": "allowEdits"]),
                "alwaysThinkingEnabled": Self.jsonFragment(true),
            ]
        )

        try original.save(to: file)
        let loaded = try Settings.load(from: file)

        let envData = try #require(loaded.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["FOO"] == "bar")
        let permsData = try #require(loaded.extraJSON["permissions"])
        let perms = try #require(JSONSerialization.jsonObject(with: permsData) as? [String: Any])
        #expect(perms["defaultMode"] as? String == "allowEdits")
        #expect(loaded.enabledPlugins?["p"] == true)
        let thinking = try #require(JSONSerialization.jsonObject(
            with: #require(loaded.extraJSON["alwaysThinkingEnabled"]), options: .fragmentsAllowed
        ) as? Bool)
        #expect(thinking == true)
    }

    @Test("Loading from nonexistent file returns empty settings")
    func loadMissing() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let settings = try Settings.load(from: missing)

        #expect(settings.extraJSON.isEmpty)
        #expect(settings.hooks == nil)
        #expect(settings.enabledPlugins == nil)
    }

    // MARK: - Unknown key preservation

    @Test("Save preserves unknown top-level JSON keys")
    func preserveUnknownKeys() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")

        // Write a file with an unknown top-level key
        let rawJSON: [String: Any] = [
            "env": ["MY_VAR": "value"],
            "unknownField": "important-data",
            "anotherUnknown": 42,
            "alwaysThinkingEnabled": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: rawJSON, options: .prettyPrinted)
        try data.write(to: file)

        // Load, modify env via extraJSON, and save
        var settings = try Settings.load(from: file)
        if let envData = settings.extraJSON["env"],
           var envDict = try JSONSerialization.jsonObject(with: envData) as? [String: String] {
            envDict["NEW_VAR"] = "new"
            settings.extraJSON["env"] = try JSONSerialization.data(withJSONObject: envDict)
        }
        try settings.save(to: file)

        // Read raw JSON to verify unknown keys survived
        let savedData = try Data(contentsOf: file)
        let savedJSON = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])

        #expect(savedJSON["unknownField"] as? String == "important-data")
        #expect(savedJSON["anotherUnknown"] as? Int == 42)
        #expect((savedJSON["env"] as? [String: String])?["MY_VAR"] == "value")
        #expect((savedJSON["env"] as? [String: String])?["NEW_VAR"] == "new")
    }

    @Test("Save to new file works without existing unknown keys")
    func saveNewFile() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        let settings = try Settings(extraJSON: [
            "env": Self.jsonFragment(["KEY": "val"]),
            "alwaysThinkingEnabled": Self.jsonFragment(true),
        ])
        try settings.save(to: file)

        let loaded = try Settings.load(from: file)
        let envData = try #require(loaded.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["KEY"] == "val")
        #expect(loaded.extraJSON["alwaysThinkingEnabled"] != nil)
    }

    // MARK: - extraJSON passthrough

    @Test("load captures unknown top-level keys into extraJSON")
    func loadCapturesExtraJSON() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        let rawJSON: [String: Any] = [
            "env": ["KEY": "value"],
            "hooks": ["SessionStart": [[
                "hooks": [["type": "command", "command": "echo hi"]],
            ]]],
            "attribution": ["commit": "", "pr": ""],
            "customFeature": ["nested": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: rawJSON, options: .prettyPrinted)
        try data.write(to: file)

        let settings = try Settings.load(from: file)

        // Typed fields decoded normally
        #expect(settings.hooks?["SessionStart"]?.count == 1)

        // All non-typed keys captured in extraJSON
        #expect(settings.extraJSON["env"] != nil)
        let envData = try #require(settings.extraJSON["env"])
        let env = try #require(JSONSerialization.jsonObject(with: envData) as? [String: String])
        #expect(env["KEY"] == "value")
        #expect(settings.extraJSON["attribution"] != nil)
        #expect(settings.extraJSON["customFeature"] != nil)

        // Known typed keys should NOT appear in extraJSON
        #expect(settings.extraJSON["hooks"] == nil)
        #expect(settings.extraJSON["enabledPlugins"] == nil)
    }

    @Test("merge carries extraJSON with existing-wins and dict-level merge")
    func mergeExtraJSON() throws {
        let attrA = try Self.jsonFragment(["commit": "tool-a", "pr": ""])
        let attrB = try Self.jsonFragment(["commit": "tool-b", "newField": "x"])
        let extra = try Self.jsonFragment(42)

        var base = Settings(extraJSON: ["attribution": attrA])
        let other = Settings(extraJSON: ["attribution": attrB, "newKey": extra])

        base.merge(with: other)

        // Dict-level merge: existing "commit" preserved, "newField" added
        let mergedData = try #require(base.extraJSON["attribution"])
        let merged = try #require(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        #expect(merged["commit"] as? String == "tool-a")
        #expect(merged["newField"] as? String == "x")

        // New scalar key adopted
        #expect(base.extraJSON["newKey"] != nil)
    }

    @Test("merge preserves existing scalar extraJSON over other")
    func mergeExtraJSONScalarPreserved() throws {
        let valA = try Self.jsonFragment(false)
        let valB = try Self.jsonFragment(true)

        var base = Settings(extraJSON: ["flag": valA])
        let other = Settings(extraJSON: ["flag": valB])

        base.merge(with: other)

        let resultData = try #require(base.extraJSON["flag"])
        let result = try #require(JSONSerialization.jsonObject(with: resultData, options: .fragmentsAllowed) as? Bool)
        #expect(result == false) // existing wins
    }

    @Test("Unknown keys survive load-merge-save pipeline")
    func unknownKeysPipeline() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Simulate a techpack settings file with an unknown key
        let sourceFile = tmpDir.appendingPathComponent("pack-settings.json")
        let sourceJSON: [String: Any] = [
            "env": ["PACK_VAR": "value"],
            "attribution": ["commit": "", "pr": ""],
        ]
        try JSONSerialization.data(withJSONObject: sourceJSON, options: .prettyPrinted)
            .write(to: sourceFile)

        // Load pack settings (source)
        let packSettings = try Settings.load(from: sourceFile)

        // Merge into empty settings (simulating project-scope Configurator)
        var settings = Settings()
        settings.merge(with: packSettings)

        // Save to destination
        let destFile = tmpDir.appendingPathComponent("settings.local.json")
        try settings.save(to: destFile)

        // Verify the unknown key survived the full pipeline
        let savedData = try Data(contentsOf: destFile)
        let savedJSON = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        #expect(savedJSON["attribution"] != nil)
        let attr = savedJSON["attribution"] as? [String: Any]
        #expect(attr?["commit"] as? String == "")
        #expect(attr?["pr"] as? String == "")
        #expect((savedJSON["env"] as? [String: String])?["PACK_VAR"] == "value")
    }

    @Test("removeKeys removes from extraJSON")
    func removeExtraKeys() throws {
        var settings = try Settings(extraJSON: ["attribution": Self.jsonFragment(["commit": "x"])])

        settings.removeKeys(["attribution"])

        #expect(settings.extraJSON["attribution"] == nil)
    }

    @Test("removeKeys handles dotted paths in extraJSON")
    func removeExtraSubKeys() throws {
        var settings = try Settings(extraJSON: ["env": Self.jsonFragment(["FOO": "bar", "BAZ": "qux"])])

        settings.removeKeys(["env.FOO"])

        // "FOO" removed, "BAZ" preserved
        let resultData = try #require(settings.extraJSON["env"])
        let result = try #require(JSONSerialization.jsonObject(with: resultData) as? [String: String])
        #expect(result["FOO"] == nil)
        #expect(result["BAZ"] == "qux")
    }

    @Test("removeKeys removes extraJSON entry when last sub-key removed")
    func removeExtraLastSubKey() throws {
        var settings = try Settings(extraJSON: ["env": Self.jsonFragment(["FOO": "bar"])])

        settings.removeKeys(["env.FOO"])

        // Entire entry removed when dict becomes empty
        #expect(settings.extraJSON["env"] == nil)
    }

    @Test("Destination file unknown keys preserved when not in struct")
    func destinationPreservedWhenNotInStruct() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        // Pre-existing file has a user-written key
        let existingJSON: [String: Any] = ["userSetting": "keep-me"]
        try JSONSerialization.data(withJSONObject: existingJSON, options: .prettyPrinted)
            .write(to: file)

        // Save settings that don't include userSetting
        let settings = try Settings(extraJSON: [
            "env": Self.jsonFragment(["KEY": "val"]),
        ])
        try settings.save(to: file)

        // User-written key preserved
        let savedData = try Data(contentsOf: file)
        let savedJSON = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        #expect(savedJSON["userSetting"] as? String == "keep-me")
    }

    @Test("dropKeys prevents Layer 3 from re-adding removed keys")
    func dropKeysPreventReAdd() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        // Destination file has a pack-contributed key
        let existingJSON: [String: Any] = [
            "attribution": ["commit": "old-pack"],
            "userSetting": "keep-me",
        ]
        try JSONSerialization.data(withJSONObject: existingJSON, options: .prettyPrinted)
            .write(to: file)

        // Save with dropKeys to simulate pack removal
        var settings = try Settings.load(from: file)
        settings.removeKeys(["attribution"])
        try settings.save(to: file, dropKeys: ["attribution"])

        let savedData = try Data(contentsOf: file)
        let savedJSON = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        #expect(savedJSON["attribution"] == nil) // dropped
        #expect(savedJSON["userSetting"] as? String == "keep-me") // preserved
    }

    @Test("Dict-level merge when both sides have a JSON object key")
    func dictKeyLevelMerge() throws {
        let basePerms = try Self.jsonFragment(["defaultMode": "plan"])
        let otherPerms = try Self.jsonFragment(["defaultMode": "ask", "newField": "x"])

        var base = Settings(extraJSON: ["permissions": basePerms])
        let other = Settings(extraJSON: ["permissions": otherPerms])

        base.merge(with: other)

        // Existing "defaultMode" preserved, "newField" added via dict-level merge
        let rawPermsData = try #require(base.extraJSON["permissions"])
        let rawPerms = try #require(JSONSerialization.jsonObject(with: rawPermsData) as? [String: Any])
        #expect(rawPerms["defaultMode"] as? String == "plan")
        #expect(rawPerms["newField"] as? String == "x")
    }

    // MARK: - removeKeys on typed properties

    @Test("removeKeys removes hook event by dotted path")
    func removeKeysHookEvent() {
        var settings = Settings(hooks: [
            "SessionStart": [
                Settings.HookGroup(matcher: nil, hooks: [Settings.HookEntry(type: "command", command: "echo hi")]),
            ],
            "PreToolUse": [
                Settings.HookGroup(matcher: "Edit", hooks: [Settings.HookEntry(type: "command", command: "echo pre")]),
            ],
        ])

        settings.removeKeys(["hooks.SessionStart"])

        #expect(settings.hooks?["SessionStart"] == nil)
        #expect(settings.hooks?["PreToolUse"]?.count == 1)
    }

    @Test("removeKeys removes enabledPlugins entry by dotted path")
    func removeKeysPluginEntry() {
        var settings = Settings(enabledPlugins: ["my-plugin": true, "other": false])

        settings.removeKeys(["enabledPlugins.my-plugin"])

        #expect(settings.enabledPlugins?["my-plugin"] == nil)
        #expect(settings.enabledPlugins?["other"] == false)
    }

    @Test("removeKeys with single-part key removes entire typed property")
    func removeKeysEntireTypedProperty() {
        var settings = Settings(
            hooks: ["SessionStart": [Settings.HookGroup(matcher: nil, hooks: [])]],
            enabledPlugins: ["p": true]
        )

        settings.removeKeys(["hooks", "enabledPlugins"])

        #expect(settings.hooks == nil)
        #expect(settings.enabledPlugins == nil)
    }

    @Test("dropKeys does not affect Layer 2 extraJSON")
    func dropKeysDoesNotAffectLayer2() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        // Destination file has an "attribution" key
        let existingJSON: [String: Any] = ["attribution": ["commit": "old"]]
        try JSONSerialization.data(withJSONObject: existingJSON, options: .prettyPrinted)
            .write(to: file)

        // Settings struct also carries "attribution" in extraJSON (from a pack merge)
        let settings = try Settings(extraJSON: [
            "attribution": Self.jsonFragment(["commit": "new-pack"]),
        ])

        // Save with dropKeys containing "attribution" — should still write the
        // struct's Layer 2 value, only Layer 3 (destination preservation) is blocked
        try settings.save(to: file, dropKeys: ["attribution"])

        let savedData = try Data(contentsOf: file)
        let savedJSON = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        let attr = savedJSON["attribution"] as? [String: Any]
        #expect(attr?["commit"] as? String == "new-pack") // Layer 2 wins
    }

    // MARK: - Edge cases

    @Test("extraJSON key matching a typed field name is ignored during save")
    func extraJSONTypedFieldCollision() throws {
        let tmpDir = try Self.makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("settings.json")
        // Settings with typed hooks AND a rogue "hooks" entry in extraJSON
        let settings = try Settings(
            hooks: ["SessionStart": [
                Settings.HookGroup(matcher: nil, hooks: [Settings.HookEntry(type: "command", command: "echo real")]),
            ]],
            extraJSON: [
                "hooks": Self.jsonFragment(["Rogue": [["hooks": [["type": "command", "command": "echo rogue"]]]]]),
            ]
        )

        try settings.save(to: file)
        let loaded = try Settings.load(from: file)

        // Typed hooks win — rogue extraJSON entry is discarded
        #expect(loaded.hooks?["SessionStart"]?.count == 1)
        #expect(loaded.hooks?["Rogue"] == nil)
    }

    @Test("removeKeys dotted path on scalar extraJSON is a no-op")
    func removeSubKeyFromScalar() throws {
        var settings = try Settings(extraJSON: [
            "alwaysThinkingEnabled": Self.jsonFragment(true),
        ])

        // Attempting to remove a sub-key from a non-dict value should be a no-op
        settings.removeKeys(["alwaysThinkingEnabled.subKey"])

        // Original scalar value preserved
        let val = try #require(JSONSerialization.jsonObject(
            with: #require(settings.extraJSON["alwaysThinkingEnabled"]), options: .fragmentsAllowed
        ) as? Bool)
        #expect(val == true)
    }

    @Test("Merge with mixed types (dict vs scalar) preserves existing")
    func mergeMixedTypes() throws {
        // Base has a dict, other has a scalar for the same key
        let baseDict = try Self.jsonFragment(["key": "val"])
        let otherScalar = try Self.jsonFragment(42)

        var base = Settings(extraJSON: ["config": baseDict])
        let other = Settings(extraJSON: ["config": otherScalar])

        base.merge(with: other)

        // Existing dict preserved (neither is overwritten)
        let resultData = try #require(base.extraJSON["config"])
        let result = try #require(JSONSerialization.jsonObject(with: resultData) as? [String: String])
        #expect(result["key"] == "val")
    }
}
