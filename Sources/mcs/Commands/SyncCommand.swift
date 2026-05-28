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
        MCSAnalytics.initialize(env: env, output: output)
        defer { MCSAnalytics.trackCommand(.sync) }
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

        let effectiveGlobal = try guardClaudeHomeCwd(env: env, output: output)

        // First-run: prompt for update notification preference
        let config = promptForUpdateCheckIfNeeded(env: env, output: output)

        // Handle --update: fetch latest for all packs before loading
        if update {
            output.warn(
                "'mcs sync --update' is deprecated. Use 'mcs update' to fetch and re-apply across all configured scopes; "
                    + "combine with 'mcs config set generate-lockfile true' if you want a lockfile."
            )
            let lockOps = LockfileOperations(environment: env, output: output, shell: shell)
            // On a non-interactive hard failure this throws before the sync phase below, so
            // healthy packs are fetched (and their SHAs saved) but not re-applied this run —
            // unlike `mcs update`, which re-applies first and signals failure last. Accepted
            // for this deprecated path; `mcs update` is the supported fetch-and-apply command.
            try lockOps.updatePacks()
        }

        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        if effectiveGlobal {
            try performGlobal(env: env, output: output, shell: shell, registry: registry)
        } else {
            try performProject(env: env, output: output, shell: shell, registry: registry, config: config)
        }

        if !dryRun {
            // Ensure the update check hook lives in global settings.json (not project-scoped)
            UpdateChecker.syncHook(config: config, env: env, output: output)

            // Check for updates after sync (respects 24-hour cache)
            UpdateChecker.checkAndPrint(env: env, shell: shell, output: output)
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
        registry: TechPackRegistry,
        config: MCSConfig
    ) throws {
        let projectPath = effectiveTargetURL

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

        switch Self.lockfileAction(dryRun: dryRun, update: update, config: config) {
        case .write:
            try lockOps.writeLockfile(at: projectPath)
        case .reportDrift:
            try lockOps.reportDrift(at: projectPath)
        case .skip:
            break
        }
    }

    /// Lockfile action at the end of a project sync.
    /// Explicit opt-out (`generate-lockfile: false`) stays silent — the user has made a choice
    /// and drift warnings would half-respect it. Only the never-configured (`nil`) state gets a
    /// drift nudge, since those users likely have a stale lockfile from the auto-generation era.
    enum LockfileAction: Equatable {
        case write
        case reportDrift
        case skip
    }

    static func lockfileAction(dryRun: Bool, update: Bool, config: MCSConfig) -> LockfileAction {
        guard !dryRun else { return .skip }
        if update || config.isLockfileGenerationEnabled { return .write }
        if config.isLockfileGenerationUnset { return .reportDrift }
        return .skip
    }

    // MARK: - Shared Helpers

    private var effectiveTargetURL: URL {
        if let p = path {
            URL(fileURLWithPath: p)
        } else {
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
    }

    /// Detect when the target points at `~/.claude` or `$HOME` and redirect to
    /// `--global` instead of silently syncing project artifacts into the home dir.
    /// Returns the effective `global` flag.
    func guardClaudeHomeCwd(env: Environment, output: CLIOutput) throws -> Bool {
        let target = effectiveTargetURL
        guard env.isInsideClaudeHome(target) else { return global }

        if global {
            output.info("Switching cwd to \(env.homeDirectory.path) before global sync.")
        } else {
            let isInteractive = pack.isEmpty && !all && !dryRun && output.isInteractiveTerminal
            guard isInteractive else {
                output.error("Cannot run 'mcs sync' from \(target.path).")
                output.plain("  Add '--global' to run global sync, or run from a project directory.")
                throw ExitCode.failure
            }
            let useGlobal = output.askYesNo(
                "It looks like you want to sync global scope. Use 'mcs sync --global' instead?",
                default: true
            )
            guard useGlobal else {
                output.error("Aborting. Add '--global' to run global sync, or run from a project directory.")
                throw ExitCode.failure
            }
        }

        // Point cwd at $HOME so post-sync ProjectDetector walks don't see stale state.
        guard FileManager.default.changeCurrentDirectoryPath(env.homeDirectory.path) else {
            output.warn("Could not chdir to \(env.homeDirectory.path); project detection may be stale.")
            return true
        }
        return true
    }

    /// Prompt for update notification preference on first interactive sync.
    @discardableResult
    private func promptForUpdateCheckIfNeeded(env: Environment, output: CLIOutput) -> MCSConfig {
        var config = MCSConfig.load(from: env.mcsConfigFile, output: output)

        // Only prompt in interactive mode (no --pack, --all, or --dry-run) and if never configured
        let isInteractive = pack.isEmpty && !all && !dryRun
        guard isInteractive, config.isUnconfigured else { return config }

        let enabled = output.askYesNo("Enable update notifications on session start?")
        config.updateCheckPacks = enabled
        config.updateCheckCLI = enabled
        do {
            try config.save(to: env.mcsConfigFile)
        } catch {
            output.warn("Could not save config: \(error.localizedDescription)")
        }
        UpdateChecker.syncHook(config: config, env: env, output: output)
        return config
    }

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
