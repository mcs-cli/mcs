import Foundation
@testable import mcs
import Testing

struct SettingsHasherTests {
    @Test("nil for empty keyPaths")
    func emptyKeyPaths() {
        let json: [String: Any] = ["foo": "bar"]
        let result = SettingsHasher.hash(keyPaths: [], in: json)
        #expect(result == nil)
    }

    @Test("deterministic hash for single top-level key")
    func singleTopLevelKey() {
        let json: [String: Any] = ["alwaysThinkingEnabled": true]
        let hash1 = SettingsHasher.hash(keyPaths: ["alwaysThinkingEnabled"], in: json)
        let hash2 = SettingsHasher.hash(keyPaths: ["alwaysThinkingEnabled"], in: json)
        #expect(hash1 != nil)
        #expect(hash1 == hash2)
    }

    @Test("dotted key path extracts nested value")
    func dottedKeyPath() {
        let json: [String: Any] = ["env": ["FOO": "bar"]]
        let hash = SettingsHasher.hash(keyPaths: ["env.FOO"], in: json)
        #expect(hash != nil)

        // Different value should produce different hash
        let json2: [String: Any] = ["env": ["FOO": "baz"]]
        let hash2 = SettingsHasher.hash(keyPaths: ["env.FOO"], in: json2)
        #expect(hash != hash2)
    }

    @Test("key ordering is stable regardless of input order")
    func keyOrderingStable() {
        let json: [String: Any] = ["a": 1, "b": 2, "c": 3]
        let hash1 = SettingsHasher.hash(keyPaths: ["c", "a", "b"], in: json)
        let hash2 = SettingsHasher.hash(keyPaths: ["a", "b", "c"], in: json)
        let hash3 = SettingsHasher.hash(keyPaths: ["b", "c", "a"], in: json)
        #expect(hash1 == hash2)
        #expect(hash2 == hash3)
    }

    @Test("missing key hashes to null representation")
    func missingKeyHashesToNull() {
        let json: [String: Any] = ["existing": "value"]
        let hash = SettingsHasher.hash(keyPaths: ["missing"], in: json)
        #expect(hash != nil)

        // Should differ from a key that exists with a real value
        let hashExisting = SettingsHasher.hash(keyPaths: ["existing"], in: json)
        #expect(hash != hashExisting)
    }

    @Test("nested dict value is deterministic with sortedKeys")
    func nestedDictDeterministic() {
        // JSON dictionaries are unordered, but sortedKeys ensures consistent output
        let json: [String: Any] = ["env": ["Z_KEY": "last", "A_KEY": "first", "M_KEY": "middle"]]
        let hash1 = SettingsHasher.hash(keyPaths: ["env"], in: json)
        let hash2 = SettingsHasher.hash(keyPaths: ["env"], in: json)
        #expect(hash1 != nil)
        #expect(hash1 == hash2)
    }

    @Test("different values produce different hashes")
    func differentValues() {
        let json1: [String: Any] = ["key": "value1"]
        let json2: [String: Any] = ["key": "value2"]
        let hash1 = SettingsHasher.hash(keyPaths: ["key"], in: json1)
        let hash2 = SettingsHasher.hash(keyPaths: ["key"], in: json2)
        #expect(hash1 != hash2)
    }

    @Test("extractValue returns nil when parent is not a dict")
    func extractValueNonDictParent() {
        let json: [String: Any] = ["env": 42]
        let result = SettingsHasher.extractValue("env.FOO", from: json)
        #expect(result == nil)
    }

    @Test("same values always produce same hash")
    func sameValues() {
        let json: [String: Any] = [
            "env": ["FOO": "bar"],
            "enabledPlugins": ["myPlugin": true],
            "alwaysThinkingEnabled": true,
        ]
        let keys = ["env.FOO", "enabledPlugins.myPlugin", "alwaysThinkingEnabled"]
        let hash1 = SettingsHasher.hash(keyPaths: keys, in: json)
        let hash2 = SettingsHasher.hash(keyPaths: keys, in: json)
        #expect(hash1 == hash2)
    }
}
