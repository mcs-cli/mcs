import ArgumentParser

/// Single source of truth for the CLI version.
/// Used in markers, sidecar files, and `--version` output.
enum MCSVersion {
    static let current = "2026.3.2"
}

@main
struct MCS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcs",
        abstract: "Managed Claude Stack — Configure Claude Code with MCP servers, plugins, skills, and hooks",
        version: MCSVersion.current,
        subcommands: [
            SyncCommand.self,
            DoctorCommand.self,
            CleanupCommand.self,
            PackCommand.self,
            ExportCommand.self,
        ],
        defaultSubcommand: SyncCommand.self
    )
}
