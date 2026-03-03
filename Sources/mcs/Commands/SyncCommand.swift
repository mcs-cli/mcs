import ArgumentParser
import Foundation

struct SyncCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync Claude Code configuration for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .long, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

    @Flag(name: .long, help: "Apply all registered packs without prompts")
    var all: Bool = false

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .long, help: "Checkout locked pack versions from mcs.lock.yaml before syncing")
    var lock = false

    @Flag(name: .long, help: "Fetch latest pack versions and update mcs.lock.yaml")
    var update = false

    @Flag(name: .long, help: "Customize which components to include per pack")
    var customize = false

    @Flag(name: .long, help: "Install to global scope (MCP servers with user scope, files to ~/.claude/)")
    var global = false

    var skipLock: Bool {
        dryRun
    }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

        // Handle --update: fetch latest for all packs before loading
        if update {
            let lockOps = LockfileOperations(environment: env, output: output, shell: shell)
            try lockOps.updatePacks()
        }

        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        if global {
            try performGlobal(env: env, output: output, shell: shell, registry: registry)
        } else {
            try performProject(env: env, output: output, shell: shell, registry: registry)
        }
    }

    // MARK: - Global Scope

    private func performGlobal(
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry
    ) throws {
        let configurator = Configurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry,
            strategy: GlobalSyncStrategy(environment: env)
        )

        let persistedExclusions: [String: Set<String>]
        do {
            persistedExclusions = try ProjectState(stateFile: env.globalStateFile).allExcludedComponents
        } catch {
            output.error("Corrupt global state: \(error.localizedDescription)")
            output.error("Delete \(env.globalStateFile.path) and re-run 'mcs sync --global'.")
            throw ExitCode.failure
        }

        if all || !pack.isEmpty {
            let packs = try resolvePacks(from: registry, output: output)
            try runSync(
                configurator: configurator,
                packs: packs,
                scopeLabel: "Global",
                targetLabel: "Target",
                targetPath: env.claudeDirectory.path,
                excludedComponents: persistedExclusions,
                output: output
            )
        } else {
            try configurator.interactiveConfigure(dryRun: dryRun, customize: customize)
        }
    }

    // MARK: - Project Scope

    private func performProject(
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry
    ) throws {
        let projectPath = if let p = path {
            URL(fileURLWithPath: p)
        } else {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw MCSError.fileOperationFailed(
                path: projectPath.path,
                reason: "Directory does not exist"
            )
        }

        let lockOps = LockfileOperations(environment: env, output: output, shell: shell)

        // Handle --lock: checkout locked commits before loading packs
        if lock {
            try lockOps.checkoutLockedCommits(at: projectPath)
        }

        let configurator = Configurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
        )

        let persistedExclusions: [String: Set<String>]
        do {
            persistedExclusions = try ProjectState(projectRoot: projectPath).allExcludedComponents
        } catch {
            output.error("Corrupt .mcs-project: \(error.localizedDescription)")
            output.error("Delete .claude/.mcs-project and re-run 'mcs sync'.")
            throw ExitCode.failure
        }

        if all || !pack.isEmpty {
            let packs = try resolvePacks(from: registry, output: output)
            try runSync(
                configurator: configurator,
                packs: packs,
                scopeLabel: "Project",
                targetLabel: "Project",
                targetPath: projectPath.path,
                excludedComponents: persistedExclusions,
                output: output
            )
        } else {
            try configurator.interactiveConfigure(dryRun: dryRun, customize: customize)
        }

        // Write lockfile after successful sync (unless dry-run)
        if !dryRun {
            try lockOps.writeLockfile(at: projectPath)
        }
    }

    // MARK: - Shared Helpers

    private func resolvePacks(
        from registry: TechPackRegistry,
        output: CLIOutput
    ) throws -> [any TechPack] {
        if all {
            let allPacks = registry.availablePacks
            guard !allPacks.isEmpty else {
                output.error("No packs registered. Run 'mcs pack add <url>' first.")
                throw ExitCode.failure
            }
            return allPacks
        }

        let resolvedPacks: [any TechPack] = pack.compactMap { registry.pack(for: $0) }
        let resolvedIDs = Set(resolvedPacks.map(\.identifier))

        for id in pack where !resolvedIDs.contains(id) {
            output.warn("Unknown tech pack: \(id)")
        }

        guard !resolvedPacks.isEmpty else {
            output.error("No valid tech pack specified.")
            let available = registry.availablePacks.map(\.identifier).joined(separator: ", ")
            output.plain("  Available packs: \(available)")
            throw ExitCode.failure
        }

        return resolvedPacks
    }

    private func runSync(
        configurator: Configurator,
        packs: [any TechPack],
        scopeLabel: String,
        targetLabel: String,
        targetPath: String,
        excludedComponents: [String: Set<String>],
        output: CLIOutput
    ) throws {
        output.header("Sync \(scopeLabel)")
        output.plain("")
        output.info("\(targetLabel): \(targetPath)")
        output.info("Packs: \(packs.map(\.displayName).joined(separator: ", "))")

        if dryRun {
            try configurator.dryRun(packs: packs)
        } else {
            try configurator.configure(packs: packs, confirmRemovals: false, excludedComponents: excludedComponents)
            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }
    }
}
