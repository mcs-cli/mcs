import Foundation

/// Installs pack components with dependency resolution.
/// Used by `SyncCommand` (mcs sync) to auto-install missing pack dependencies.
/// Delegates to `ComponentExecutor` for shared install logic, ensuring consistent
/// behavior across install paths.
struct PackInstaller {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    let registry: TechPackRegistry

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry = .shared
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.registry = registry
    }

    private var executor: ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    /// Install missing components for a pack. Returns true if all succeeded.
    @discardableResult
    func installPack(_ pack: any TechPack) -> Bool {
        let allComponents = registry.allPackComponents

        // Select all pack components
        let selectedIDs = Set(pack.components.map(\.id))

        // Resolve dependencies
        let plan: DependencyResolver.ResolvedPlan
        do {
            plan = try DependencyResolver.resolve(
                selectedIDs: selectedIDs,
                allComponents: allComponents
            )
        } catch {
            output.error("Failed to resolve pack dependencies: \(error.localizedDescription)")
            return false
        }

        // Filter to components that aren't already installed
        let missing = plan.orderedComponents.filter {
            !ComponentExecutor.isAlreadyInstalled($0)
        }

        if missing.isEmpty {
            output.dimmed("All \(pack.displayName) components already installed")
            return true
        }

        output.plain("")
        output.plain("  Installing \(pack.displayName) pack components...")
        let total = missing.count
        var allSucceeded = true

        for (index, component) in missing.enumerated() {
            output.step(index + 1, of: total, component.displayName)

            let success = installComponent(component)
            if success {
                output.success("\(component.displayName) installed")
            } else {
                output.warn("Failed to install \(component.displayName)")
                allSucceeded = false
            }
        }

        return allSucceeded
    }

    // MARK: - Component Installation

    private func installComponent(_ component: ComponentDefinition) -> Bool {
        let exec = executor

        switch component.installAction {
        case let .brewInstall(package):
            return exec.installBrewPackage(package)

        case let .shellCommand(command):
            let result = shell.shell(command)
            if !result.succeeded {
                output.warn(String(result.stderr.prefix(200)))
            }
            return result.succeeded

        case let .mcpServer(config):
            return exec.installMCPServer(config)

        case let .plugin(name):
            return exec.installPlugin(name)

        case let .gitignoreEntries(entries):
            return exec.addGitignoreEntries(entries)

        case let .copyPackFile(source, destination, fileType):
            return exec.installCopyPackFile(
                source: source,
                destination: destination,
                fileType: fileType
            )

        case .settingsMerge:
            // Settings merge is handled at the project level by Configurator.
            return true
        }
    }
}
