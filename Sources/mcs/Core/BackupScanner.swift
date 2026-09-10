import Foundation

/// Discovers backup files across the scopes `mcs cleanup` can reach, grouped by the
/// scope that owns them.
struct BackupScanner {
    let environment: Environment
    let currentDirectory: URL

    /// Backups found under one scope, with the root their paths are displayed against.
    struct Group {
        enum Kind {
            case global
            case currentDirectory
            case project
        }

        let kind: Kind
        let root: URL
        let backups: [URL]
    }

    func scan(includeTrackedProjects: Bool, output: CLIOutput) -> [Group] {
        var targets: [(kind: Group.Kind, root: URL)] = [(.global, environment.claudeDirectory)]

        if currentDirectory.standardizedFileURL.path != environment.homeDirectory.standardizedFileURL.path {
            targets.append((.currentDirectory, currentDirectory))
        }

        if includeTrackedProjects {
            // A project the user is already standing in is covered by the scope above;
            // scanning it again would walk the same tree for results `seen` then discards.
            let covered = Set(targets.map(\.root.standardizedFileURL.path))
            targets += trackedProjects(output: output)
                .filter { !covered.contains($0.path) }
                .map { (.project, $0) }
        }

        var seen: Set<String> = []
        return targets.compactMap { target in
            var found: [URL] = []
            for url in backups(in: target.root, kind: target.kind) {
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                found.append(url)
            }
            guard !found.isEmpty else { return nil }
            return Group(kind: target.kind, root: target.root, backups: found.sorted { $0.path < $1.path })
        }
    }

    /// A tracked project is swept at its root and under `.claude/` only — the two places sync
    /// writes a backup. Every project on the machine walked in full would put unrelated
    /// `*.backup.*` user files on the deletion list; a scope the user named themselves is
    /// narrow enough to sweep whole.
    private func backups(in root: URL, kind: Group.Kind) -> [URL] {
        switch kind {
        case .global, .currentDirectory:
            Backup.findBackups(in: root)
        case .project:
            Backup.findBackups(in: root, recursive: false)
                + Backup.findBackups(in: root.appendingPathComponent(Constants.FileNames.claudeDirectory))
        }
    }

    /// Projects recorded in `~/.mcs/projects.yaml` that still exist on disk.
    private func trackedProjects(output: CLIOutput) -> [URL] {
        let index = ProjectIndex(path: environment.projectsIndexFile)
        do {
            return try index.existingProjectURLs(in: index.load())
        } catch {
            output.warn("Could not read the project index — scanning local scopes only: \(error.localizedDescription)")
            return []
        }
    }
}
