import Foundation

/// Heuristic checks for tech pack quality beyond structural validation.
enum PackHeuristics {
    enum Severity {
        case error
        case warning
    }

    struct Finding: Equatable {
        let severity: Severity
        let message: String
    }

    static func check(manifest: ExternalPackManifest, packPath: URL) -> [Finding] {
        var findings: [Finding] = []
        let components = manifest.components ?? []

        findings += checkEmptyPack(manifest: manifest)
        findings += checkRootSourceCopy(components: components)
        findings += checkSettingsFileSources(components: components, packPath: packPath)
        let unreferenced = checkUnreferencedFiles(manifest: manifest, packPath: packPath)
            + checkRootLevelContentFiles(manifest: manifest, packPath: packPath)
        findings += unreferenced
        findings += checkMCPDependencyGaps(components: components)
        findings += checkPythonModulePaths(components: components, packPath: packPath)
        findings += checkDoctorCheckScopeUsage(manifest: manifest, components: components)
        findings += checkDoctorCheckMatcherUsage(manifest: manifest, components: components)

        // Surface the `ignore:` hint only when an actual unreferenced-file warning was emitted
        // (not for the IO-failure warnings that share the same severity).
        if unreferenced.contains(where: { $0.severity == .warning && $0.message.contains(Self.unreferencedMarker) }) {
            findings.append(Finding(
                severity: .warning,
                message: "Add intentional non-material paths (docs/, examples/, assets) to the"
                    + " `ignore:` field in techpack.yaml to silence these warnings."
            ))
        }

        return findings
    }

    /// Sentinel substring shared between the `unreferenced file` warning emitters and the hint
    /// detector in `check(...)`. Keep the two emit sites and the detector aligned.
    static let unreferencedMarker = "is not referenced"

    // MARK: - Individual Checks

    private static func checkEmptyPack(manifest: ExternalPackManifest) -> [Finding] {
        if (manifest.components ?? []).isEmpty,
           (manifest.templates ?? []).isEmpty,
           manifest.configureProject == nil {
            return [Finding(severity: .error, message: "Pack has no components, templates, or configure script — nothing to install")]
        }
        return []
    }

    private static func checkRootSourceCopy(
        components: [ExternalComponentDefinition]
    ) -> [Finding] {
        var findings: [Finding] = []
        for component in components {
            if case let .copyPackFile(config) = component.installAction {
                var normalized = config.source.trimmingCharacters(in: .whitespaces)
                if normalized.hasPrefix("./") {
                    normalized = String(normalized.dropFirst(2))
                }
                if normalized.isEmpty || normalized == "." {
                    let msg = "Component '\(component.id)' uses source '.' which copies the entire pack root"
                        + " (including techpack.yaml, LICENSE, README)"
                    findings.append(Finding(severity: .error, message: msg))
                }
            }
        }
        return findings
    }

    private static func checkSettingsFileSources(
        components: [ExternalComponentDefinition],
        packPath: URL
    ) -> [Finding] {
        let fm = FileManager.default
        var findings: [Finding] = []
        for component in components {
            if case let .settingsFile(source) = component.installAction {
                let file = packPath.appendingPathComponent(source)
                if !fm.fileExists(atPath: file.path) {
                    findings.append(Finding(
                        severity: .error,
                        message: "Component '\(component.id)' references settings file '\(source)' which does not exist"
                    ))
                }
            }
        }
        return findings
    }

    /// Directories at the pack root that are infrastructure, not pack content.
    static let ignoredDirectories: Set<String> = [
        ".git", ".github", ".gitlab", ".vscode",
        "node_modules", "__pycache__", ".build",
    ]

    /// Paths the manifest relies on for its install surface.
    /// Used by `checkUnreferencedFiles`, by `ExternalPackManifest.validate()` to reject
    /// load-bearing entries in the `ignore:` list (issue #338), and by the runtime safety
    /// guard in `ExternalPackLoader` that strips forbidden `ignore:` entries defensively.
    static func referencedPaths(from manifest: ExternalPackManifest) -> Set<String> {
        var paths = Set<String>()
        for component in manifest.components ?? [] {
            switch component.installAction {
            case let .copyPackFile(config):
                paths.insert(normalizeReferencedPath(config.source))
            case let .settingsFile(source):
                paths.insert(normalizeReferencedPath(source))
            default:
                break
            }
        }
        for template in manifest.templates ?? [] {
            paths.insert(normalizeReferencedPath(template.contentFile))
        }
        if let script = manifest.configureProject?.script {
            paths.insert(normalizeReferencedPath(script))
        }
        return paths
    }

    /// Normalize a referenced path so equivalent expressions collapse to the same key.
    /// Trims whitespace and strips a leading `./` so `ignore:` validation doesn't miss
    /// the same file expressed as `hooks/foo.sh` vs `./hooks/foo.sh` vs ` hooks/foo.sh`.
    private static func normalizeReferencedPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
        return normalized
    }

    private static func checkUnreferencedFiles(
        manifest: ExternalPackManifest,
        packPath: URL
    ) -> [Finding] {
        let fm = FileManager.default
        let referencedPaths = referencedPaths(from: manifest)

        let rootContents: [URL]
        do {
            rootContents = try fm.contentsOfDirectory(
                at: packPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return [Finding(
                severity: .warning,
                message: "Could not list pack directory contents: \(error.localizedDescription) — unreferenced file check skipped"
            )]
        }

        let subdirs = rootContents.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue,
                  !ignoredDirectories.contains(url.lastPathComponent)
            else { return false }
            // Skip subdirectories entirely when the author has ignored them via techpack.yaml.
            return !isIgnoredByManifest(url.lastPathComponent, manifest: manifest)
        }

        var findings: [Finding] = []

        for dirURL in subdirs {
            let dirName = dirURL.lastPathComponent

            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                findings.append(Finding(
                    severity: .warning,
                    message: "Could not list contents of \(dirName)/: \(error.localizedDescription)"
                ))
                continue
            }

            for itemURL in contents {
                let relativePath = "\(dirName)/\(itemURL.lastPathComponent)"
                if referencedPaths.contains(relativePath) { continue }
                if isIgnoredByManifest(relativePath, manifest: manifest) { continue }
                findings.append(Finding(
                    severity: .warning,
                    message: "\(relativePath) \(Self.unreferencedMarker) by any component or template"
                ))
            }
        }

        return findings
    }

    /// True when the path (or the directory tree it lives in) matches any `ignore:` entry
    /// in the manifest. Uses POSIX glob semantics via `GlobMatcher`.
    static func isIgnoredByManifest(_ path: String, manifest: ExternalPackManifest) -> Bool {
        guard let ignore = manifest.ignore, !ignore.isEmpty else { return false }
        for pattern in ignore where GlobMatcher.matches(pattern, path: path) {
            return true
        }
        return false
    }

    /// Files at the pack root that are expected infrastructure, not content.
    /// Used by `checkRootLevelContentFiles` to avoid warning about these files.
    /// Intentionally includes `techpack.yaml` — see `infrastructureFilesForUpdateCheck`
    /// below for the (deliberately different) set the update-check filter uses.
    private static let infrastructureFiles: Set<String> = [
        Constants.ExternalPacks.manifestFilename, "README.md", "README", "LICENSE", "LICENSE.md",
        "CHANGELOG.md", "CONTRIBUTING.md", ".gitignore", ".editorconfig",
        "package.json", "package-lock.json", "requirements.txt",
        "Makefile", "Dockerfile", ".dockerignore",
    ]

    /// Used by `UpdateChecker`'s noise filter. Excludes `techpack.yaml` because
    /// manifest edits can swap the install surface (hooks, MCP commands) — silently
    /// suppressing them would be a supply-chain attack vector. Do not deduplicate
    /// these sets.
    static let infrastructureFilesForUpdateCheck: Set<String> =
        infrastructureFiles.subtracting([Constants.ExternalPacks.manifestFilename])

    private static func checkRootLevelContentFiles(
        manifest: ExternalPackManifest,
        packPath: URL
    ) -> [Finding] {
        let fm = FileManager.default
        let referencedRootFiles = referencedPaths(from: manifest).filter { !$0.contains("/") }

        let rootContents: [URL]
        do {
            rootContents = try fm.contentsOfDirectory(
                at: packPath,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return [Finding(
                severity: .warning,
                message: "Could not list pack root contents: \(error.localizedDescription) — root-level file check skipped"
            )]
        }

        var findings: [Finding] = []
        for itemURL in rootContents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir), !isDir.boolValue else { continue }

            let name = itemURL.lastPathComponent
            if !infrastructureFiles.contains(name),
               !referencedRootFiles.contains(name),
               !isIgnoredByManifest(name, manifest: manifest) {
                findings.append(Finding(
                    severity: .warning,
                    message: "\(name) \(Self.unreferencedMarker) by any component"
                ))
            }
        }

        return findings
    }

    private static func checkMCPDependencyGaps(
        components: [ExternalComponentDefinition]
    ) -> [Finding] {
        var brewPackages = Set<String>()
        for component in components {
            if case let .brewInstall(package) = component.installAction {
                brewPackages.insert(package)
            }
        }

        var findings: [Finding] = []
        for component in components {
            if case let .mcpServer(config) = component.installAction,
               let command = config.command {
                let base = URL(fileURLWithPath: command).lastPathComponent
                if ["python", "python3"].contains(base),
                   !brewPackages.contains(where: { $0 == "python" || $0.hasPrefix("python@") }) {
                    findings.append(Finding(
                        severity: .warning,
                        message: "MCP server '\(config.name)' uses python but no brew component installs python"
                    ))
                }
                if ["node", "npx"].contains(base),
                   !brewPackages.contains("node") {
                    findings.append(Finding(
                        severity: .warning,
                        message: "MCP server '\(config.name)' uses node but no brew component installs node"
                    ))
                }
            }
        }

        return findings
    }

    private static func checkPythonModulePaths(
        components: [ExternalComponentDefinition],
        packPath: URL
    ) -> [Finding] {
        let fm = FileManager.default
        var findings: [Finding] = []

        for component in components {
            if case let .mcpServer(config) = component.installAction,
               let command = config.command,
               let args = config.args {
                let base = URL(fileURLWithPath: command).lastPathComponent
                guard ["python", "python3"].contains(base),
                      let mIndex = args.firstIndex(of: "-m"),
                      mIndex + 1 < args.count
                else { continue }

                let moduleName = args[mIndex + 1]
                let moduleDir = packPath.appendingPathComponent(moduleName)
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: moduleDir.path, isDirectory: &isDir) || !isDir.boolValue {
                    let msg = "MCP server '\(config.name)' references module '\(moduleName)'"
                        + " but \(moduleName)/ directory not found in pack"
                    findings.append(Finding(severity: .warning, message: msg))
                }
            }
        }

        return findings
    }

    /// Warns when a doctor check declares `scope` on a type that ignores it.
    ///
    /// A silently-ignored field reads as configuration but has no effect, which is how
    /// `hookEventExists` and `settingsKeyEquals` came to look scope-aware while always reading
    /// the global settings file.
    private static func checkDoctorCheckScopeUsage(
        manifest: ExternalPackManifest,
        components: [ExternalComponentDefinition]
    ) -> [Finding] {
        let allChecks = (manifest.supplementaryDoctorChecks ?? [])
            + components.flatMap { $0.doctorChecks ?? [] }

        return allChecks
            .filter { $0.scope != nil && !$0.type.honorsScope }
            .map { check in
                let detail = switch check.type {
                case .hookEventExists, .settingsKeyEquals:
                    "settings are resolved from the project root automatically"
                        + " (project settings.local.json, then global settings.json)"
                default:
                    "`scope` only applies to checks with a `path`"
                }
                return Finding(
                    severity: .warning,
                    message: "Doctor check '\(check.name)' declares `scope` but type"
                        + " `\(check.type.rawValue)` ignores it — \(detail)"
                )
            }
    }

    /// Warns when a doctor check declares `matcher` on a type that ignores it.
    ///
    /// Same failure mode as `checkDoctorCheckScopeUsage`: a field that reads as an assertion but
    /// is never consulted. There is no equivalent check for `command` — every type that accepts it
    /// consumes it, only with a different meaning per type.
    private static func checkDoctorCheckMatcherUsage(
        manifest: ExternalPackManifest,
        components: [ExternalComponentDefinition]
    ) -> [Finding] {
        let allChecks = (manifest.supplementaryDoctorChecks ?? [])
            + components.flatMap { $0.doctorChecks ?? [] }

        return allChecks
            .filter { $0.matcher != nil && $0.type != .hookEventExists }
            .map { check in
                Finding(
                    severity: .warning,
                    message: "Doctor check '\(check.name)' declares `matcher` but type"
                        + " `\(check.type.rawValue)` ignores it — `matcher` applies only to `hookEventExists`"
                )
            }
    }
}
