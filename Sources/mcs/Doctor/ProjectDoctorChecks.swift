import Foundation

/// Context passed to project-scoped doctor checks.
struct ProjectDoctorContext: Sendable {
    let projectRoot: URL
    let registry: TechPackRegistry
}

/// Doctor checks that only run when inside a detected project root.
enum ProjectDoctorChecks {
    static func checks(context: ProjectDoctorContext) -> [any DoctorCheck] {
        let claudeLocalURL = context.projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let projectRoot = context.projectRoot
        let registry = context.registry
        return [
            CLAUDEMDFreshnessCheck(
                fileURL: claudeLocalURL,
                stateLoader: { try ProjectState(projectRoot: projectRoot) },
                registry: registry,
                displayName: "CLAUDE.local.md freshness",
                syncHint: "mcs sync"
            ),
            ProjectStateFileCheck(projectRoot: context.projectRoot),
        ]
    }
}

// MARK: - Project state file check

/// Warns if CLAUDE.local.md exists but .mcs-project doesn't.
/// Fix: infers packs from section markers and creates the file.
struct ProjectStateFileCheck: DoctorCheck, Sendable {
    let projectRoot: URL

    var name: String {
        "Project state file"
    }

    var section: String {
        "Project"
    }

    func check() -> CheckResult {
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)

        guard FileManager.default.fileExists(atPath: claudeLocal.path) else {
            return .skip("no CLAUDE.local.md — run 'mcs sync'")
        }

        do {
            let state = try ProjectState(projectRoot: projectRoot)
            if state.exists {
                return .pass(".mcs-project present")
            }
        } catch {
            return .warn("corrupt .mcs-project: \(error.localizedDescription) — run 'mcs doctor --fix'")
        }
        return .warn("CLAUDE.local.md exists but .mcs-project missing — run 'mcs doctor --fix'")
    }

    func fix() -> FixResult {
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let content: String
        do {
            content = try String(contentsOf: claudeLocal, encoding: .utf8)
        } catch {
            return .failed("could not read CLAUDE.local.md: \(error.localizedDescription)")
        }

        // Infer packs from section markers
        let sections = TemplateComposer.parseSections(from: content)
        let packIdentifiers = sections.map(\.identifier)

        // Delete corrupt state file if present so we can rebuild cleanly
        let stateFile = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        if FileManager.default.fileExists(atPath: stateFile.path) {
            do {
                try FileManager.default.removeItem(at: stateFile)
            } catch {
                return .failed("could not delete corrupt .mcs-project: \(error.localizedDescription) — remove it manually and re-run")
            }
        }

        // After deletion, init cannot throw (file no longer exists), so build and save in one block
        do {
            var state = try ProjectState(projectRoot: projectRoot)
            for pack in packIdentifiers {
                state.recordPack(pack)
            }
            try state.save()
            return .fixed("created .mcs-project with packs: \(packIdentifiers.joined(separator: ", "))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
