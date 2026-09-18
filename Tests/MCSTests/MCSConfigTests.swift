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
        #expect(config.telemetry == nil)
    }

    @Test("Load parses valid YAML")
    func loadValidYAML() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("config.yaml")
        let yaml = """
        update-check-packs: true
        update-check-cli: false
        telemetry: false
        """
        try yaml.write(to: path, atomically: true, encoding: .utf8)

        let config = MCSConfig.load(from: path)
        #expect(config.updateCheckPacks == true)
        #expect(config.updateCheckCLI == false)
        #expect(config.telemetry == false)
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
        config.telemetry = false
        try config.save(to: path)

        let reloaded = MCSConfig.load(from: path)
        #expect(reloaded.updateCheckPacks == true)
        #expect(reloaded.updateCheckCLI == false)
        #expect(reloaded.telemetry == false)
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

    @Test("isTelemetryEnabled defaults to true when nil")
    func isTelemetryEnabledNil() {
        let config = MCSConfig()
        #expect(config.isTelemetryEnabled)
    }

    @Test("isTelemetryEnabled returns true when explicitly true")
    func isTelemetryEnabledTrue() {
        var config = MCSConfig()
        config.telemetry = true
        #expect(config.isTelemetryEnabled)
    }

    @Test("isTelemetryEnabled returns false when explicitly false")
    func isTelemetryEnabledFalse() {
        var config = MCSConfig()
        config.telemetry = false
        #expect(!config.isTelemetryEnabled)
    }

    // MARK: - Key Access

    @Test("value(forKey:) returns correct values")
    func valueForKey() {
        var config = MCSConfig()
        config.updateCheckPacks = true
        config.updateCheckCLI = false
        config.telemetry = true

        #expect(config.value(forKey: "update-check-packs") == true)
        #expect(config.value(forKey: "update-check-cli") == false)
        #expect(config.value(forKey: "telemetry") == true)
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

        let telemetrySet = config.setValue(false, forKey: "telemetry")
        #expect(telemetrySet)
        #expect(config.telemetry == false)

        let unknownSet = config.setValue(true, forKey: "unknown-key")
        #expect(!unknownSet)
    }

    // MARK: - Known Keys

    @Test("knownKeys covers all CodingKeys")
    func knownKeysComplete() {
        let codingKeyValues = Set(MCSConfig.CodingKeys.allCases.map(\.rawValue))
        let knownKeyValues = Set(MCSConfig.knownKeys.map(\.key))
        #expect(codingKeyValues == knownKeyValues)
    }
}
