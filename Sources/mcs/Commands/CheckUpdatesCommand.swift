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
        guard let result = check(env: env, output: output) else { return }

        if json {
            printJSON(result)
        } else if !UpdateChecker.printResult(result, output: output, isHook: hook), !hook {
            output.success("Everything is up to date.")
        }
    }

    func check(env: Environment, output: CLIOutput) -> UpdateChecker.CheckResult? {
        // A hand-edited config can disable checks while the hook entry is still registered;
        // bail before `performCheck`, which would otherwise serve a <24h cache written by sync or doctor.
        if hook, !MCSConfig.load(from: env.mcsConfigFile).isUpdateCheckEnabled {
            return nil
        }

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

        let relevantEntries = UpdateChecker.filterEntries(registryData.packs, environment: env)
        let checker = UpdateChecker(environment: env, shell: ShellRunner(environment: env))
        return checker.performCheck(entries: relevantEntries, forceRefresh: !hook)
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
