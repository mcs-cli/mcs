import CryptoKit
import Foundation
import IOKit
import TelemetryDeck

/// Lightweight telemetry wrapper around TelemetryDeck SDK.
/// Sends anonymous usage signals (command name + version) to understand
/// how many users are using the CLI. No PII is collected.
///
/// - Enabled by default (opt-out); disable with `mcs config set telemetry false`.
/// - User identity is derived from the hardware UUID (IOPlatformUUID), salted
///   and SHA-256 hashed — never stored on disk, cannot be tampered with.
/// - All methods silently no-op on failure; telemetry must never break a command.
enum MCSAnalytics {
    /// Type-safe command names for telemetry signals.
    enum Command: String {
        case sync
        case bootstrap
        case update
        case doctor
        case cleanup
        case packAdd = "pack.add"
        case packRemove = "pack.remove"
        case packList = "pack.list"
        case packUpdate = "pack.update"
        case packValidate = "pack.validate"
        case export
        case checkUpdates = "check-updates"
        case configList = "config.list"
        case configGet = "config.get"
        case configSet = "config.set"
    }

    /// Single-threaded CLI — no synchronization needed.
    private nonisolated(unsafe) static var enabled = false

    // MARK: - Public API

    /// Initialize telemetry. Call once at the start of a command.
    /// Loads config to check opt-out, derives anonymous ID, initializes TelemetryDeck SDK.
    /// Shows a one-time notice on first use.
    static func initialize(env: Environment, output: CLIOutput) {
        guard !enabled else { return }

        let config = MCSConfig.load(from: env.mcsConfigFile, output: output)
        guard config.isTelemetryEnabled else { return }

        showFirstRunNoticeIfNeeded(env: env, output: output)

        let tdConfig = TelemetryDeck.Config(appID: Constants.Telemetry.appID)
        tdConfig.defaultUser = anonymousUserID()
        tdConfig.sendNewSessionBeganSignal = false
        TelemetryDeck.initialize(config: tdConfig)

        enabled = true
    }

    /// Send a command execution signal, flush, and wait briefly for delivery.
    /// Call once at the end of a command — blocks for up to 200ms.
    static func trackCommand(_ command: Command) {
        guard enabled else { return }
        TelemetryDeck.signal(
            "cli.command",
            parameters: [
                "command": command.rawValue,
                "mcsVersion": MCSVersion.current,
            ]
        )
        TelemetryDeck.requestImmediateSync()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }

    // MARK: - Anonymous ID

    /// Derive a stable anonymous identifier from the hardware UUID.
    /// The result is `SHA256("mcs-telemetry-" + IOPlatformUUID)` as a hex string.
    private static func anonymousUserID() -> String {
        guard let uuid = hardwareUUID() else {
            // Fallback: random UUID for this session only (no persistence, no inflation risk)
            return UUID().uuidString
        }
        let salted = "mcs-telemetry-" + uuid
        let digest = SHA256.hash(data: Data(salted.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Read the IOPlatformUUID from IOKit (hardware UUID burned into firmware).
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(service) }
        guard service != IO_OBJECT_NULL else { return nil }
        guard let uuidRef = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return uuidRef.takeRetainedValue() as? String
    }

    // MARK: - First-Run Notice

    /// Show a one-time notice about telemetry on the very first run.
    private static func showFirstRunNoticeIfNeeded(env: Environment, output: CLIOutput) {
        let markerPath = env.mcsDirectory
            .appendingPathComponent(Constants.Telemetry.telemetryNoticedFile)
        guard !FileManager.default.fileExists(atPath: markerPath.path) else { return }

        output.info("mcs collects anonymous usage telemetry to improve the tool.")
        output.dimmed("Run 'mcs config set telemetry false' to disable.")

        // Create the marker file so the notice is only shown once.
        let dir = markerPath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            output.warn("Could not create telemetry marker directory: \(error.localizedDescription)")
            return
        }
        if !FileManager.default.createFile(atPath: markerPath.path, contents: nil) {
            output.warn("Could not write telemetry marker file — notice will repeat next run")
        }
    }
}
