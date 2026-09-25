import Foundation

/// Context passed to project-scoped doctor checks.
struct ProjectDoctorContext {
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

/// Validates project state presence: passes if `.mcs-project` exists,
/// fails on legacy state (CLAUDE.local.md without `.mcs-project`), warns on corruption,
/// skips when neither file is present. Fix infers packs from section markers.
struct ProjectStateFileCheck: DoctorCheck {
    let projectRoot: URL

    var name: String {
        "Project state file"
    }

    var section: String {
        "Project"
    }

    var fixCommandPreview: String? {
        "rebuild .mcs-project from the CLAUDE.local.md section markers"
    }

    func check() -> CheckResult {
        do {
            let state = try ProjectState(projectRoot: projectRoot)
            if state.exists {
                return .pass(".mcs-project present")
            }
        } catch {
            // Rebuilding from section markers would drop every artifact record, orphaning what the
            // packs installed, so a corrupt file is the user's call rather than a `--fix` target.
            return .warn(
                "corrupt .mcs-project: \(error.localizedDescription) — back it up, delete .claude/.mcs-project and re-run 'mcs sync'"
            )
        }

        // No .mcs-project — legacy state needing migration?
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        if FileManager.default.fileExists(atPath: claudeLocal.path) {
            return .fail("CLAUDE.local.md exists but .mcs-project missing — run 'mcs doctor --fix'")
        }

        return .skip("no project state — run 'mcs sync'")
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

        let stateFile = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        guard !FileManager.default.fileExists(atPath: stateFile.path) else {
            return .notFixable("a .mcs-project already exists — back it up, delete it and re-run 'mcs sync'")
        }

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
