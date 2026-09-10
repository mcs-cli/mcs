import ArgumentParser
import Foundation

struct CleanupCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Find and delete backup files"
    )

    @Flag(name: .shortAndLong, help: "Delete backups without confirmation")
    var force: Bool = false

    @Flag(
        name: [.short, .customLong("all-projects")],
        help: "Also scan every project tracked in the index (machine-wide)"
    )
    var allProjects: Bool = false

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        MCSAnalytics.initialize(env: env, output: output)
        defer { MCSAnalytics.trackCommand(.cleanup) }

        output.header("Backup Cleanup")

        let scanner = BackupScanner(
            environment: env,
            currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let groups = scanner.scan(includeTrackedProjects: allProjects, output: output)
        let backups = groups.flatMap(\.backups)

        guard !backups.isEmpty else {
            output.success("No backup files found.")
            return
        }

        output.info("Found \(backups.count) backup file(s):")
        for group in groups {
            output.plain("")
            output.plain("  \(label(for: group))")
            for backup in group.backups {
                let name = PathContainment.relativePath(of: backup.path, within: group.root.path)
                output.plain("    \(name) (\(formattedSize(of: backup, output: output)))")
            }
        }

        output.plain("")

        guard force || output.askYesNo("Delete all \(backups.count) backup file(s)?", default: false) else {
            output.info("No backups deleted.")
            return
        }

        let failures = Backup.deleteBackups(backups)
        let deleted = backups.count - failures.count
        if failures.isEmpty {
            output.success("Deleted \(deleted) backup file(s).")
        } else {
            output.warn("Deleted \(deleted) backup(s), \(failures.count) could not be deleted:")
            for failure in failures {
                output.warn("  \(failure.url.path): \(failure.error.localizedDescription)")
            }
        }
    }

    private func label(for group: BackupScanner.Group) -> String {
        let kind = switch group.kind {
        case .global: "Global"
        case .currentDirectory: "Current directory"
        case .project: "Project"
        }
        return "\(kind) (\(group.root.path))"
    }

    /// A file listed by the scan but unreadable now is one the delete pass will also fail on,
    /// so the reason is worth saying out loud rather than rendering as a plausible zero.
    private func formattedSize(of file: URL, output: CLIOutput) -> String {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let size = attrs[.size] as? Int else { return "size unknown" }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } catch {
            output.warn("Could not read \(file.path): \(error.localizedDescription)")
            return "size unknown"
        }
    }
}
