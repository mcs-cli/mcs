import Foundation

/// Codable model for ~/.claude/settings.json with deep-merge support.
///
/// Only `hooks` and `enabledPlugins` are typed stored properties (they need
/// structured access by configurators and doctor checks). All other top-level
/// keys flow through `extraJSON` — a `[String: Data]` bag of serialized JSON
/// fragments — so any key works without code changes.
struct Settings: Codable {
    var hooks: [String: [HookGroup]]?
    var enabledPlugins: [String: Bool]?

    /// Arbitrary top-level keys not modeled as typed properties, stored as
    /// serialized JSON fragments. `Data` is `Sendable`, keeping the struct
    /// concurrency-safe under Swift 6.
    var extraJSON: [String: Data] = [:]

    // MARK: - Nested Types

    struct HookGroup: Codable {
        var matcher: String?
        var hooks: [HookEntry]?
    }

    struct HookEntry: Codable {
        var type: String?
        var command: String?
    }

    // MARK: - Initializers

    init(
        hooks: [String: [HookGroup]]? = nil,
        enabledPlugins: [String: Bool]? = nil,
        extraJSON: [String: Data] = [:]
    ) {
        self.hooks = hooks
        self.enabledPlugins = enabledPlugins
        self.extraJSON = extraJSON
    }

    // MARK: - Codable

    /// Only typed stored properties participate in Codable synthesis.
    /// Everything else goes through `extraJSON` via `load(from:)` / `save(to:)`.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hooks, enabledPlugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try container.decodeIfPresent([String: [HookGroup]].self, forKey: .hooks)
        enabledPlugins = try container.decodeIfPresent([String: Bool].self, forKey: .enabledPlugins)
        // extraJSON is populated by load(from:), not by the decoder
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(hooks, forKey: .hooks)
        try container.encodeIfPresent(enabledPlugins, forKey: .enabledPlugins)
        // extraJSON is written by save(to:) via JSONSerialization
    }

    // MARK: - Hook Helpers

    /// Add a hook entry for the given event, deduplicated by command.
    /// Returns `true` if the entry was added (not a duplicate).
    @discardableResult
    mutating func addHookEntry(event: String, command: String) -> Bool {
        let entry = HookEntry(type: "command", command: command)
        let group = HookGroup(matcher: nil, hooks: [entry])
        var existing = hooks ?? [:]
        var groups = existing[event] ?? []
        guard !groups.contains(where: { $0.hooks?.first?.command == command }) else {
            return false
        }
        groups.append(group)
        existing[event] = groups
        hooks = existing
        return true
    }

    // MARK: - Deep Merge

    /// Merge `other` into `self`, preserving existing user values.
    /// - Hook arrays: deduplicated by the first hook entry's `command` field.
    /// - Plugin dict: merged at key level (existing keys win).
    /// - Extra JSON: generic merge — JSON objects get key-level merge,
    ///   scalars/arrays use "existing wins" semantics.
    mutating func merge(with other: Settings) {
        // Hooks: deduplicate by command
        if let otherHooks = other.hooks {
            var merged = hooks ?? [:]
            for (event, otherGroups) in otherHooks {
                var existing = merged[event] ?? []
                let existingCommands = Set(
                    existing.compactMap { $0.hooks?.first?.command }
                )
                for group in otherGroups {
                    if let command = group.hooks?.first?.command,
                       !existingCommands.contains(command) {
                        existing.append(group)
                    }
                }
                merged[event] = existing
            }
            hooks = merged
        }

        // Plugins: merge without replacing (existing keys win)
        if let otherPlugins = other.enabledPlugins {
            var merged = enabledPlugins ?? [:]
            merged.merge(otherPlugins) { existing, _ in existing }
            enabledPlugins = merged
        }

        // Extra JSON: generic merge for all non-typed keys (env, permissions,
        // alwaysThinkingEnabled, attribution, and any future keys).
        for (key, valueData) in other.extraJSON {
            if let existingData = extraJSON[key] {
                // Both have the key — attempt dict-level merge if both are JSON objects
                if let selfDict = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
                   let otherDict = try? JSONSerialization.jsonObject(with: valueData) as? [String: Any] {
                    var merged = selfDict
                    for (k, v) in otherDict where merged[k] == nil {
                        merged[k] = v
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: merged) {
                        extraJSON[key] = data
                    }
                    // Re-serialization failure: keep existing value (no-op)
                }
                // Non-dict: existing wins (no action)
            } else {
                extraJSON[key] = valueData
            }
        }
    }

    // MARK: - Stale key removal

    /// Remove settings keys that mcs previously owned but are no longer in the template.
    /// Key paths use dot notation: `env.KEY`, `permissions.defaultMode`, `enabledPlugins.NAME`.
    /// Single-part paths remove from `extraJSON` or typed properties as appropriate.
    mutating func removeKeys(_ keyPaths: [String]) {
        for keyPath in keyPaths {
            let parts = keyPath.split(separator: ".", maxSplits: 1)
            if parts.count == 2 {
                let section = String(parts[0])
                let key = String(parts[1])
                switch section {
                case "hooks":
                    hooks?.removeValue(forKey: key)
                case "enabledPlugins":
                    enabledPlugins?.removeValue(forKey: key)
                default:
                    // Handle dotted paths for extraJSON keys (e.g. "env.FOO",
                    // "permissions.defaultMode")
                    removeExtraJSONSubKey(topLevel: section, subKey: key)
                }
            } else {
                // Single-part key — check typed properties first, then extraJSON
                switch keyPath {
                case "hooks":
                    hooks = nil
                case "enabledPlugins":
                    enabledPlugins = nil
                default:
                    extraJSON.removeValue(forKey: keyPath)
                }
            }
        }
    }

    // MARK: - File I/O

    /// Top-level JSON keys with typed stored properties. Keys outside this set
    /// are managed via `extraJSON` and preserved during round-trips.
    private static let knownTopLevelKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    /// Load settings from a JSON file. Returns empty settings if file doesn't exist.
    /// Unknown top-level keys are captured into `extraJSON` as serialized Data fragments.
    static func load(from url: URL) throws -> Settings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Settings()
        }
        return try decode(from: data)
    }

    /// Load settings from a JSON file, applying placeholder substitution before parsing.
    /// Reads the file as text, replaces `__KEY__` tokens using `TemplateEngine.substitute`,
    /// then parses the substituted text as JSON.
    static func load(from url: URL, substituting values: [String: String]) throws -> Settings {
        guard !values.isEmpty else { return try load(from: url) }
        let rawText: String
        do {
            rawText = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Settings()
        }
        // JSON-escape substitution values so embedded quotes, backslashes, or newlines
        // don't produce invalid JSON when placed inside string literals.
        let escaped = try jsonEscapeValues(values)
        let substituted = TemplateEngine.substitute(template: rawText, values: escaped, emitWarnings: false)
        return try decode(from: Data(substituted.utf8))
    }

    /// JSON-escape each value so it's safe to splice into a JSON string literal.
    /// Encodes each value as a JSON string, then strips the surrounding quotes.
    private static func jsonEscapeValues(_ values: [String: String]) throws -> [String: String] {
        let encoder = JSONEncoder()
        var escaped: [String: String] = [:]
        escaped.reserveCapacity(values.count)
        for (key, value) in values {
            let data = try encoder.encode(value)
            guard let jsonString = String(data: data, encoding: .utf8),
                  jsonString.count >= 2
            else {
                escaped[key] = value
                continue
            }
            // Strip surrounding quotes: "hello \"world\"" → hello \"world\"
            escaped[key] = String(jsonString.dropFirst().dropLast())
        }
        return escaped
    }

    /// Decode settings from JSON data, capturing unknown top-level keys into `extraJSON`.
    private static func decode(from data: Data) throws -> Settings {
        var settings = try JSONDecoder().decode(Settings.self, from: data)
        if let rawJSON = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in rawJSON where !knownTopLevelKeys.contains(key) {
                settings.extraJSON[key] = try JSONSerialization.data(
                    withJSONObject: value, options: .fragmentsAllowed
                )
            }
        }
        return settings
    }

    /// Save settings to a JSON file, creating parent directories as needed.
    ///
    /// Three-layer priority:
    /// 1. Typed fields (`hooks`, `enabledPlugins`) via JSONEncoder
    /// 2. `extraJSON` from the struct (does not overwrite Layer 1)
    /// 3. Destination file unknown keys — only if not already in output and not in `dropKeys`
    ///
    /// - Parameter dropKeys: Top-level keys to explicitly exclude from destination
    ///   file preservation (used during pack removal to prevent re-adding stale keys).
    func save(to url: URL, dropKeys: Set<String> = []) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Read existing JSON to preserve user-written unknown top-level keys
        var preserved: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: url),
           let existingJSON = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            for (key, value) in existingJSON where !Self.knownTopLevelKeys.contains(key) {
                preserved[key] = value
            }
        }

        // Layer 1: Encode typed fields
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let knownData = try encoder.encode(self)

        guard var json = try JSONSerialization.jsonObject(with: knownData) as? [String: Any] else {
            try knownData.write(to: url)
            return
        }

        // Layer 2: Merge extraJSON (does not overwrite typed fields)
        for (key, data) in extraJSON where !Self.knownTopLevelKeys.contains(key) {
            if json[key] == nil {
                json[key] = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            }
        }

        // Layer 3: Preserve destination file unknown keys, except dropped ones
        for (key, value) in preserved {
            if json[key] == nil, !dropKeys.contains(key) {
                json[key] = value
            }
        }

        let mergedData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try mergedData.write(to: url, options: .atomic)
    }

    // MARK: - Private Helpers

    /// Remove a sub-key from an extraJSON entry that holds a JSON object.
    private mutating func removeExtraJSONSubKey(topLevel: String, subKey: String) {
        guard let data = extraJSON[topLevel],
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        dict.removeValue(forKey: subKey)
        if dict.isEmpty {
            extraJSON.removeValue(forKey: topLevel)
        } else if let newData = try? JSONSerialization.data(withJSONObject: dict) {
            extraJSON[topLevel] = newData
        }
        // Re-serialization failure: keep existing value (no-op)
    }
}
