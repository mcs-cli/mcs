import Foundation

// MARK: - Deriving doctor checks from ComponentDefinition

extension ComponentDefinition {
    /// Auto-generates doctor check(s) from installAction.
    /// Returns nil for actions that have no mechanical verification
    /// (e.g. .shellCommand, .settingsMerge, .gitignoreEntries).
    func deriveDoctorCheck(projectRoot: URL? = nil) -> (any DoctorCheck)? {
        switch installAction {
        case let .mcpServer(config):
            return MCPServerCheck(name: displayName, serverName: config.name, projectRoot: projectRoot)

        case let .plugin(pluginName):
            return PluginCheck(pluginRef: PluginRef(pluginName))

        case let .brewInstall(package):
            return CommandCheck(
                name: displayName,
                section: type.doctorSection,
                command: package,
                isOptional: !isRequired
            )

        case let .copyPackFile(_, destination, fileType):
            let globalURL = fileType.destinationURL(in: Environment(), destination: destination)
            if let projectRoot {
                let projectURL = fileType.projectBaseDirectory(projectPath: projectRoot)
                    .appendingPathComponent(destination)
                return FileExistsCheck(
                    name: displayName, section: type.doctorSection,
                    path: projectURL, fallbackPath: globalURL
                )
            }
            return FileExistsCheck(
                name: displayName, section: type.doctorSection,
                path: globalURL
            )

        case .shellCommand, .settingsMerge, .gitignoreEntries:
            return nil
        }
    }

    /// All doctor checks for this component: auto-derived + supplementary.
    func allDoctorChecks(projectRoot: URL? = nil) -> [any DoctorCheck] {
        let derived: [any DoctorCheck] = deriveDoctorCheck(projectRoot: projectRoot).map { [$0] } ?? []
        return derived + supplementaryChecks
    }
}
