import Foundation
import Yams

/// User preferences stored at `~/.mcs/config.yaml`.
/// All fields are optional — `nil` means "never configured".
struct MCSConfig: Codable {
    /// SessionStart update-check preference. `nil` (default) enables the hook — update
    /// notifications are opt-out; explicit `false` removes it.
    var updateCheck: Bool?
    var telemetry: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case updateCheck = "update-check"
        case telemetry
    }

    /// Legacy keys read on load (v0 config files) and folded into `updateCheck`.
    /// Retained only for one-shot migration in `init(from:)` — never written back.
    private enum LegacyCodingKeys: String, CodingKey {
        case updateCheckPacks = "update-check-packs"
        case updateCheckCLI = "update-check-cli"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        telemetry = try container.decodeIfPresent(Bool.self, forKey: .telemetry)

        if let value = try container.decodeIfPresent(Bool.self, forKey: .updateCheck) {
            updateCheck = value
            return
        }

        // Migrate from the two-key era. `nil` on the new key preserves the opt-out default;
        // migration only fires when the user *explicitly* disabled both legacy keys.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyPacks = try legacy.decodeIfPresent(Bool.self, forKey: .updateCheckPacks)
        let legacyCLI = try legacy.decodeIfPresent(Bool.self, forKey: .updateCheckCLI)
        if legacyPacks == false, legacyCLI == false {
            updateCheck = false
        }
    }

    /// Whether telemetry is enabled. Defaults to `true` when unconfigured (`nil`).
    var isTelemetryEnabled: Bool {
        telemetry != false
    }

    /// Whether the SessionStart update-check hook should be installed.
    /// Default is `true` when unset — update notifications are opt-out.
    var isUpdateCheckEnabled: Bool {
        updateCheck ?? true
    }

    // MARK: - Known Keys

    struct ConfigKey {
        let key: String
        let description: String
        let defaultValue: String
    }

    static let knownKeys: [ConfigKey] = [
        ConfigKey(
            key: CodingKeys.updateCheck.rawValue,
            description: "Show tech-pack and mcs CLI update notifications on Claude Code session start",
            defaultValue: "true"
        ),
        ConfigKey(
            key: CodingKeys.telemetry.rawValue,
            description: "Enable anonymous usage telemetry",
            defaultValue: "true"
        ),
    ]

    // MARK: - Persistence

    /// Load config from disk. Returns empty config if file is missing.
    /// Warns via `output` if the file exists but is corrupt.
    static func load(from path: URL, output: CLIOutput? = nil) -> MCSConfig {
        do {
            return try YAMLFile.load(MCSConfig.self, from: path) ?? MCSConfig()
        } catch let error as DecodingError {
            output?.warn("Config file is corrupt (\(path.lastPathComponent)): \(error.localizedDescription)")
            return MCSConfig()
        } catch let error as YamlError {
            output?.warn("Config file is corrupt (\(path.lastPathComponent)): \(error.localizedDescription)")
            return MCSConfig()
        } catch {
            output?.warn("Could not read config file: \(error.localizedDescription)")
            return MCSConfig()
        }
    }

    /// Save config to disk, creating parent directories if needed.
    func save(to path: URL) throws {
        try YAMLFile.save(self, to: path)
    }

    // MARK: - Key Access

    /// Get a config value by key name. Returns nil if the key is unknown or unset.
    func value(forKey key: String) -> Bool? {
        switch key {
        case CodingKeys.updateCheck.rawValue: updateCheck
        case CodingKeys.telemetry.rawValue: telemetry
        default: nil
        }
    }

    /// Set a config value by key name. Returns false if the key is unknown.
    mutating func setValue(_ value: Bool, forKey key: String) -> Bool {
        switch key {
        case CodingKeys.updateCheck.rawValue:
            updateCheck = value
            return true
        case CodingKeys.telemetry.rawValue:
            telemetry = value
            return true
        default:
            return false
        }
    }
}
