import Foundation
@testable import mcs
import Testing

struct MCSConfigTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Load

    @Test("Load returns empty config when file does not exist")
    func loadMissingFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == nil)
        #expect(config.updateCheckCLI == nil)
    }

    @Test("Load parses valid YAML")
    func loadValidYAML() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        let yaml = """
        update-check-packs: true
        update-check-cli: false
        """
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == true)
        #expect(config.updateCheckCLI == false)
    }

    @Test("Load returns empty config for corrupt YAML")
    func loadCorruptYAML() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        try ":::invalid:::yaml:::".write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == nil)
        #expect(config.updateCheckCLI == nil)
    }

    @Test("Load returns empty config for empty file")
    func loadEmptyFile() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        try "".write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == nil)
    }

    // MARK: - Save + Roundtrip

    @Test("Save and reload produces the same values")
    func saveRoundtrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        var config = MCSConfig()
        config.updateCheckPacks = true
        config.updateCheckCLI = false
        try config.save(to: path)

        let reloaded = MCSConfig.load(from: path)
        #expect(reloaded.updateCheckPacks == true)
        #expect(reloaded.updateCheckCLI == false)
    }

    @Test("Save creates parent directories")
    func saveCreatesDirectories() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("nested/dir/config.yaml")
        var config = MCSConfig()
        config.updateCheckPacks = true
        try config.save(to: path)

        let reloaded = MCSConfig.load(from: path)
        #expect(reloaded.updateCheckPacks == true)
    }

    // MARK: - Computed Properties

    @Test("isUpdateCheckEnabled returns false when both nil")
    func isUpdateCheckEnabledBothNil() {
        let config = MCSConfig()
        #expect(!config.isUpdateCheckEnabled)
    }

    @Test("isUpdateCheckEnabled returns true when packs enabled")
    func isUpdateCheckEnabledPacksOnly() {
        var config = MCSConfig()
        config.updateCheckPacks = true
        #expect(config.isUpdateCheckEnabled)
    }

    @Test("isUpdateCheckEnabled returns true when CLI enabled")
    func isUpdateCheckEnabledCLIOnly() {
        var config = MCSConfig()
        config.updateCheckCLI = true
        #expect(config.isUpdateCheckEnabled)
    }

    @Test("isUpdateCheckEnabled returns false when both explicitly false")
    func isUpdateCheckEnabledBothFalse() {
        var config = MCSConfig()
        config.updateCheckPacks = false
        config.updateCheckCLI = false
        #expect(!config.isUpdateCheckEnabled)
    }

    @Test("isUnconfigured returns true when both nil")
    func isUnconfiguredBothNil() {
        let config = MCSConfig()
        #expect(config.isUnconfigured)
    }

    @Test("isUnconfigured returns false when one is set")
    func isUnconfiguredOneSet() {
        var config = MCSConfig()
        config.updateCheckPacks = false
        #expect(!config.isUnconfigured)
    }

    @Test("isLockfileGenerationEnabled defaults to false when nil")
    func isLockfileGenerationEnabledNil() {
        let config = MCSConfig()
        #expect(!config.isLockfileGenerationEnabled)
    }

    @Test("isLockfileGenerationEnabled returns true when explicitly true")
    func isLockfileGenerationEnabledTrue() {
        var config = MCSConfig()
        config.generateLockfile = true
        #expect(config.isLockfileGenerationEnabled)
    }

    @Test("isLockfileGenerationEnabled returns false when explicitly false")
    func isLockfileGenerationEnabledFalse() {
        var config = MCSConfig()
        config.generateLockfile = false
        #expect(!config.isLockfileGenerationEnabled)
    }

    @Test("isLockfileGenerationUnset is true only when nil")
    func isLockfileGenerationUnsetTriState() {
        var config = MCSConfig()
        #expect(config.isLockfileGenerationUnset, "nil should be unset")

        config.generateLockfile = false
        #expect(!config.isLockfileGenerationUnset, "explicit false is a choice, not unset")

        config.generateLockfile = true
        #expect(!config.isLockfileGenerationUnset, "explicit true is a choice, not unset")
    }

    @Test("generate-lockfile key round-trips through save/load for all tri-state values")
    func lockfileKeyRoundtrip() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for value in [nil, true, false] as [Bool?] {
            let path = tmpDir.appendingPathComponent("config-\(String(describing: value)).yaml")
            var config = MCSConfig()
            config.generateLockfile = value
            try config.save(to: path)

            let reloaded = MCSConfig.load(from: path)
            #expect(reloaded.generateLockfile == value, "value \(String(describing: value)) must survive round-trip")
            #expect(reloaded.isLockfileGenerationUnset == (value == nil))
            #expect(reloaded.isLockfileGenerationEnabled == (value == true))
        }
    }

    // MARK: - Key Access

    @Test("value(forKey:) returns correct values")
    func valueForKey() {
        var config = MCSConfig()
        config.updateCheckPacks = true
        config.updateCheckCLI = false
        config.generateLockfile = true

        #expect(config.value(forKey: "update-check-packs") == true)
        #expect(config.value(forKey: "update-check-cli") == false)
        #expect(config.value(forKey: "generate-lockfile") == true)
        #expect(config.value(forKey: "unknown-key") == nil)
    }

    @Test("setValue(_:forKey:) sets correct values")
    func setValueForKey() {
        var config = MCSConfig()

        let packsSet = config.setValue(true, forKey: "update-check-packs")
        #expect(packsSet)
        #expect(config.updateCheckPacks == true)

        let cliSet = config.setValue(false, forKey: "update-check-cli")
        #expect(cliSet)
        #expect(config.updateCheckCLI == false)

        let lockfileSet = config.setValue(true, forKey: "generate-lockfile")
        #expect(lockfileSet)
        #expect(config.generateLockfile == true)

        let unknownSet = config.setValue(true, forKey: "unknown-key")
        #expect(!unknownSet)

        // Telemetry was removed; the key must be rejected like any other unknown key.
        let telemetrySet = config.setValue(false, forKey: "telemetry")
        #expect(!telemetrySet)
    }

    // MARK: - Known Keys

    @Test("knownKeys covers all CodingKeys")
    func knownKeysComplete() {
        let codingKeyValues = Set(MCSConfig.CodingKeys.allCases.map(\.rawValue))
        let knownKeyValues = Set(MCSConfig.knownKeys.map(\.key))
        #expect(codingKeyValues == knownKeyValues)
    }

    // MARK: - Telemetry Removal Compatibility

    @Test("A config file left over from a telemetry-enabled release still decodes")
    func loadTolerateStaleTelemetryKey() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        let yaml = """
        update-check-packs: true
        telemetry: false
        """
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == true, "a stale key must not discard the live ones")
    }

    @Test("The config list rendering ignores a stale telemetry key")
    func listIgnoresStaleTelemetryKey() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        try "telemetry: false\n".write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        // Mirrors ListConfig.run(): every known key is rendered from value(forKey:).
        let rendered = MCSConfig.knownKeys.map { known -> String in
            let current = config.value(forKey: known.key)
            return "\(known.key): \(current.map { String($0) } ?? "(not set)")"
        }
        #expect(!rendered.contains { $0.contains("telemetry") })
        #expect(rendered.count == MCSConfig.CodingKeys.allCases.count)
    }
}
