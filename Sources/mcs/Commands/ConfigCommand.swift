import ArgumentParser
import Foundation

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage mcs preferences",
        subcommands: [ListConfig.self, GetConfig.self, SetConfig.self]
    )
}

// MARK: - List

struct ListConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show all settings with current values"
    )

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let config = MCSConfig.load(from: env.mcsConfigFile, output: output)

        output.header("Configuration")
        output.plain("")

        for known in MCSConfig.knownKeys {
            let current = config.value(forKey: known.key)
            let displayValue = current.map { String($0) } ?? "(not set, default: \(known.defaultValue))"
            output.plain("  \(known.key): \(displayValue)")
            output.dimmed("    \(known.description)")
        }

        output.plain("")
        output.dimmed("Config file: \(env.mcsConfigFile.path)")
    }
}

// MARK: - Get

struct GetConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a configuration value"
    )

    @Argument(help: "The configuration key")
    var key: String

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let config = MCSConfig.load(from: env.mcsConfigFile, output: output)

        guard MCSConfig.knownKeys.contains(where: { $0.key == key }) else {
            output.error("Unknown config key '\(key)'")
            output.dimmed("Known keys: \(MCSConfig.knownKeys.map(\.key).joined(separator: ", "))")
            throw ExitCode.failure
        }

        if let value = config.value(forKey: key) {
            print(value)
        } else {
            output.dimmed("(not set)")
        }
    }
}

// MARK: - Set

struct SetConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @Argument(help: "The configuration key")
    var key: String

    @Argument(help: "The value to set (true/false)")
    var value: Bool

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        var config = MCSConfig.load(from: env.mcsConfigFile, output: output)

        guard MCSConfig.knownKeys.contains(where: { $0.key == key }) else {
            output.error("Unknown config key '\(key)'")
            output.dimmed("Known keys: \(MCSConfig.knownKeys.map(\.key).joined(separator: ", "))")
            throw ExitCode.failure
        }

        let changed = config.setValue(value, forKey: key)
        guard changed else { throw ExitCode.failure }

        try config.save(to: env.mcsConfigFile)
        output.success("Updated: \(key) = \(value)")

        // Immediately manage the SessionStart hook in ~/.claude/settings.json
        UpdateChecker.syncHook(config: config, env: env, output: output)
    }
}
