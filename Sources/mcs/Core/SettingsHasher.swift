import CryptoKit
import Foundation

/// Deterministic SHA-256 hashing of pack-contributed settings values.
enum SettingsHasher {
    /// Hash the values at the given dot-notation key paths in a JSON dictionary.
    ///
    /// Canonical form: sorted key paths, each serialized as `key=<json_value>\n`
    /// with `.sortedKeys` on values. Returns `nil` if `keyPaths` is empty.
    static func hash(keyPaths: [String], in json: [String: Any]) -> String? {
        guard !keyPaths.isEmpty else { return nil }

        let canonical = keyPaths.sorted().map { canonicalLine($0, value: extractValue($0, from: json)) }.joined()
        return sha256(canonical)
    }

    /// One hash per key path whose value is set and is not an array.
    ///
    /// Arrays are skipped: one a pack owns whole (such as `permissions.allow`) also collects
    /// entries Claude Code appends, so comparing it would report an edit on nearly every sync.
    static func valueHashes(keyPaths: [String], in json: [String: Any]) -> [String: String] {
        var hashes: [String: String] = [:]
        for keyPath in keyPaths where !(extractValue(keyPath, from: json) is [Any]) {
            hashes[keyPath] = valueHash(keyPath, in: json)
        }
        return hashes
    }

    /// Hash of the value at `keyPath` in the same form `valueHashes` records, or `nil` when unset.
    static func valueHash(_ keyPath: String, in json: [String: Any]) -> String? {
        extractValue(keyPath, from: json).map { sha256(canonicalLine(keyPath, value: $0)) }
    }

    private static func canonicalLine(_ keyPath: String, value: Any?) -> String {
        let jsonString: String
        if let value {
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]
                )
                jsonString = String(data: data, encoding: .utf8) ?? "null"
            } catch {
                // Value came from JSONSerialization.jsonObject — round-trip should not fail.
                // Use deterministic fallback to avoid phantom drift warnings.
                jsonString = "null"
            }
        } else {
            jsonString = "null"
        }
        return "\(keyPath)=\(jsonString)\n"
    }

    private static func sha256(_ canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Extract a value from a JSON dictionary using dot-notation key path (one level of nesting).
    static func extractValue(_ keyPath: String, from json: [String: Any]) -> Any? {
        let parts = keyPath.split(separator: ".", maxSplits: 1)
        let topLevel = String(parts[0])
        if parts.count == 2 {
            let subKey = String(parts[1])
            guard let nested = json[topLevel] as? [String: Any] else { return nil }
            return nested[subKey]
        }
        return json[topLevel]
    }
}
