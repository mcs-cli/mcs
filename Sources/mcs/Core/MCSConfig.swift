import Foundation
import Yams

/// User preferences stored at `~/.mcs/config.yaml`.
/// All fields are optional — `nil` means "never configured".
struct MCSConfig: Codable {
    var updateCheckPacks: Bool?
    var updateCheckCLI: Bool?
    var generateLockfile: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case updateCheckPacks = "update-check-packs"
        case updateCheckCLI = "update-check-cli"
        case generateLockfile = "generate-lockfile"
    }

    /// Whether any update check is enabled (at least one key is true).
    var isUpdateCheckEnabled: Bool {
        (updateCheckPacks ?? false) || (updateCheckCLI ?? false)
    }

    /// Whether neither key has been configured yet (first-run state).
    var isUnconfigured: Bool {
        updateCheckPacks == nil && updateCheckCLI == nil
    }

    /// Whether `mcs sync` should write `mcs.lock.yaml`. Opt-in — users must explicitly enable
    /// reproducibility since most projects don't commit the lockfile.
    var isLockfileGenerationEnabled: Bool {
        generateLockfile == true
    }

    /// Whether the user has never made a choice about lockfile generation (upgrade path).
    /// Distinct from `!isLockfileGenerationEnabled`, which also returns true for explicit opt-out.
    /// Used to decide whether to show the migration hint when a lockfile exists but is being ignored.
    var isLockfileGenerationUnset: Bool {
        generateLockfile == nil
    }

    // MARK: - Known Keys

    struct ConfigKey {
        let key: String
        let description: String
        let defaultValue: String
    }

    static let knownKeys: [ConfigKey] = [
        ConfigKey(
            key: CodingKeys.updateCheckPacks.rawValue,
            description: "Automatically check for tech pack updates on Claude Code session start",
            defaultValue: "false"
        ),
        ConfigKey(
            key: CodingKeys.updateCheckCLI.rawValue,
            description: "Automatically check for new mcs versions on Claude Code session start",
            defaultValue: "false"
        ),
        ConfigKey(
            key: CodingKeys.generateLockfile.rawValue,
            description: "Write mcs.lock.yaml after each sync (pin pack commits for reproducible setups)",
            defaultValue: "false"
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
        case CodingKeys.updateCheckPacks.rawValue: updateCheckPacks
        case CodingKeys.updateCheckCLI.rawValue: updateCheckCLI
        case CodingKeys.generateLockfile.rawValue: generateLockfile
        default: nil
        }
    }

    /// Set a config value by key name. Returns false if the key is unknown.
    mutating func setValue(_ value: Bool, forKey key: String) -> Bool {
        switch key {
        case CodingKeys.updateCheckPacks.rawValue:
            updateCheckPacks = value
            return true
        case CodingKeys.updateCheckCLI.rawValue:
            updateCheckCLI = value
            return true
        case CodingKeys.generateLockfile.rawValue:
            generateLockfile = value
            return true
        default:
            return false
        }
    }
}
