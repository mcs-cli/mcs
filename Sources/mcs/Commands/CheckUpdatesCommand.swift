import ArgumentParser
import Foundation

struct CheckUpdatesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-updates",
        abstract: "Check for tech pack and CLI updates"
    )

    @Flag(name: .long, help: "Run as a Claude Code SessionStart hook (respects 24-hour cooldown and config)")
    var hook: Bool = false

    @Flag(name: .shortAndLong, help: "Output results as JSON")
    var json: Bool = false

    func run() throws {
        let env = Environment()
        let output = CLIOutput()
        if !hook {
            MCSAnalytics.initialize(env: env, output: output)
        }
        defer { MCSAnalytics.trackCommand(.checkUpdates) }
        let shell = ShellRunner(environment: env)

        let registry = PackRegistryFile(path: env.packsRegistry)
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            if !hook {
                output.warn("Could not read pack registry: \(error.localizedDescription)")
            }
            registryData = PackRegistryFile.RegistryData()
        }

        let checkPacks: Bool
        let checkCLI: Bool
        if hook {
            // Hook mode: respect config keys
            let config = MCSConfig.load(from: env.mcsConfigFile)
            checkPacks = config.updateCheckPacks ?? false
            checkCLI = config.updateCheckCLI ?? false
        } else {
            // User-invoked: always check both
            checkPacks = true
            checkCLI = true
        }

        let relevantEntries = UpdateChecker.filterEntries(registryData.packs, environment: env)

        let checker = UpdateChecker(environment: env, shell: shell)
        let result = checker.performCheck(
            entries: relevantEntries,
            forceRefresh: !hook,
            checkPacks: checkPacks,
            checkCLI: checkCLI
        )

        if json {
            printJSON(result)
        } else if !UpdateChecker.printResult(result, output: output, isHook: hook), !hook {
            output.success("Everything is up to date.")
        }
    }

    /// Codable DTO for the `--json` output format.
    private struct JSONOutput: Codable {
        let cli: CLIStatus
        let packs: [UpdateChecker.PackUpdate]

        struct CLIStatus: Codable {
            let current: String
            let updateAvailable: Bool
            let latest: String?
        }

        init(result: UpdateChecker.CheckResult) {
            cli = CLIStatus(
                current: MCSVersion.current,
                updateAvailable: result.cliUpdate != nil,
                latest: result.cliUpdate?.latestVersion
            )
            packs = result.packUpdates
        }
    }

    private func printJSON(_ result: UpdateChecker.CheckResult) {
        let jsonOutput = JSONOutput(result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(jsonOutput)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } catch {
            CLIOutput().error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}
