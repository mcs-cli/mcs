import ArgumentParser
import Foundation

struct SyncCommand: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync Claude Code configuration for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .shortAndLong, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

    @Flag(name: .shortAndLong, help: "Apply all registered packs without prompts")
    var all: Bool = false

    @Flag(name: .long, help: "Show what would change without making any modifications")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Install to global scope (MCP servers with user scope, files to ~/.claude/)")
    var global = false

    @Flag(name: .long, help: "Remove configured packs not named with --pack")
    var prune = false

    @Flag(name: .shortAndLong, help: "Skip the removal-confirmation prompt (only meaningful with --prune)")
    var yes = false

    /// Kept only to explain its removal instead of "Unknown option"; retire with #437 (b).
    @Flag(name: .long, help: .hidden)
    var customize = false

    var skipLock: Bool {
        dryRun
    }

    func validate() throws {
        if customize {
            throw ValidationError("""
            --customize has been removed: a pack now installs every component it declares.
            To install fewer components, fork the pack or write your own.
            See https://github.com/mcs-cli/mcs/blob/main/docs/troubleshooting.md#components-you-excluded-are-installed-after-upgrading
            """)
        }
        if prune, pack.isEmpty || all {
            throw ValidationError("--prune requires --pack and cannot be combined with --all.")
        }
        if yes, !prune {
            throw ValidationError("--yes is only meaningful with --prune.")
        }
    }

    func perform() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        guard ensureClaudeCLI(shell: shell, environment: env, output: output) else {
            throw ExitCode.failure
        }

        let effectiveGlobal = try guardClaudeHomeCwd(env: env, output: output)

        let config = MCSConfig.load(from: env.mcsConfigFile, output: output)

        let registry = TechPackRegistry.loadWithExternalPacks(
            environment: env,
            output: output
        )

        if effectiveGlobal {
            try performGlobal(env: env, output: output, shell: shell, registry: registry)
        } else {
            try performProject(env: env, output: output, shell: shell, registry: registry)
        }

        if !dryRun {
            // Persist the legacy-key migration only when we're actually mutating things —
            // dry-run must not touch the file.
            config.persistMigrationIfNeeded(to: env.mcsConfigFile, output: output)
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

        let globalState = try Self.loadGlobalState(env: env, output: output)
        if !prune, Self.scopeIsBlockedByUnloadablePack(
            configured: globalState.configuredPacks, registry: registry, output: output
        ) {
            return
        }

        if all || !pack.isEmpty {
            try syncRequestedPacks(
                configurator: configurator,
                registry: registry,
                previouslyConfigured: globalState.configuredPacks,
                globallyInstalled: nil,
                scopeLabel: "Global",
                targetPath: env.claudeDirectory.path,
                output: output
            )
        } else {
            try configurator.interactiveConfigure(
                dryRun: dryRun,
                globallyInstalledPacks: []
            )
        }
    }

    // MARK: - Project Scope

    private func performProject(
        env: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        registry: TechPackRegistry
    ) throws {
        let projectPath = effectiveTargetURL

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw MCSError.fileOperationFailed(
                path: projectPath.path,
                reason: "Directory does not exist"
            )
        }

        let configurator = Configurator(
            environment: env,
            output: output,
            shell: shell,
            registry: registry,
            strategy: ProjectSyncStrategy(projectPath: projectPath, environment: env)
        )

        let projectState: ProjectState
        do {
            projectState = try ProjectState(projectRoot: projectPath)
        } catch {
            output.error("Corrupt .mcs-project: \(error.localizedDescription)")
            output.error("Delete .claude/.mcs-project and re-run 'mcs sync'.")
            throw ExitCode.failure
        }
        let previouslyConfigured = projectState.configuredPacks

        let globallyInstalledPacks = try Self.loadGlobalState(env: env, output: output).configuredPacks

        if !prune, Self.scopeIsBlockedByUnloadablePack(
            configured: previouslyConfigured, registry: registry, output: output
        ) {
            return
        }

        if all || !pack.isEmpty {
            try syncRequestedPacks(
                configurator: configurator,
                registry: registry,
                previouslyConfigured: previouslyConfigured,
                globallyInstalled: globallyInstalledPacks,
                scopeLabel: "Project",
                targetPath: projectPath.path,
                output: output
            )
        } else {
            try configurator.interactiveConfigure(
                dryRun: dryRun,
                globallyInstalledPacks: globallyInstalledPacks
            )
        }
    }

    /// Whether this scope must skip convergence because a pack it has configured failed to load.
    /// Warns for each one — see `unloadableConfiguredPacks` for why the whole scope goes.
    /// `static` so tests can reach it: `perform()` builds its own `Environment()`.
    static func scopeIsBlockedByUnloadablePack(
        configured: Set<String>,
        registry: TechPackRegistry,
        output: CLIOutput
    ) -> Bool {
        let unloadable = registry.unloadableConfiguredPacks(configured: configured)
        guard !unloadable.isEmpty else { return false }

        output.plain("")
        for identifier in unloadable {
            output.warn("Pack '\(identifier)' is configured here but failed to load (see above).")
        }
        output.warn("Skipping sync for this scope so the pack's artifacts are left in place.")
        output.plain("  Run 'mcs pack update <pack>' to re-trust or repair it,")
        output.plain("  or 'mcs pack remove <pack>' to remove it and its artifacts.")
        return true
    }

    // MARK: - Global Pack Blocking

    /// Load global state, failing the command with an actionable message if the file is
    /// corrupt. A *missing* file is not an error — `ProjectState.load` returns early and
    /// yields an empty state, so machines that never ran `--global` are unaffected.
    ///
    /// Exposed as `static` so `BootstrapCommand` reuses the same load-and-fail message
    /// wording — the "Delete <path> and re-run" line has one home.
    static func loadGlobalState(env: Environment, output: CLIOutput) throws -> ProjectState {
        do {
            return try ProjectState(stateFile: env.globalStateFile)
        } catch {
            output.error("Corrupt global state: \(error.localizedDescription)")
            output.error("Delete \(env.globalStateFile.path) and re-run 'mcs sync --global'.")
            throw ExitCode.failure
        }
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

        let unknown = pack.filter { !resolvedIDs.contains($0) }
        for id in unknown {
            output.warn("Unknown tech pack: \(id)")
        }
        // Under --prune a mistyped name would drop the pack it meant from the exact set.
        if prune, !unknown.isEmpty {
            output.error("--prune needs every --pack name to resolve. Nothing was changed.")
            throw ExitCode.failure
        }

        guard !resolvedPacks.isEmpty else {
            output.error("No valid tech pack specified.")
            let available = registry.availablePacks.map(\.identifier).joined(separator: ", ")
            output.plain("  Available packs: \(available)")
            throw ExitCode.failure
        }

        return resolvedPacks
    }

    /// Non-interactive sync for `--all` / `--pack`.
    ///
    /// `--pack` is additive: packs already configured in the scope stay in the desired set, since
    /// `configure` unconfigures anything missing from it without asking on this path. `--prune`
    /// makes the named packs the exact set and confirms removals unless `--yes`. `--all` is
    /// already the whole registry, so it resolves as an exact set without confirmation.
    ///
    /// `globallyInstalled` is `nil` for the global scope, which has no global packs to block.
    /// Internal so integration tests can drive it: `perform()` builds its own `Environment()`.
    func syncRequestedPacks(
        configurator: Configurator,
        registry: TechPackRegistry,
        previouslyConfigured: Set<String>,
        globallyInstalled: Set<String>?,
        scopeLabel: String,
        targetPath: String,
        output: CLIOutput
    ) throws {
        let desired = try ConfiguratorSupport.additivePackSet(
            requested: resolvePacks(from: registry, output: output),
            previouslyConfigured: previouslyConfigured,
            prune: prune || all,
            pruneCommand: global ? "mcs sync --global --pack <pack> --prune" : "mcs sync --pack <pack> --prune",
            registry: registry,
            output: output
        )

        var packs = desired.packs
        if let globallyInstalled {
            packs = try ConfiguratorSupport.filterGloballyBlocked(
                desired.packs,
                globallyInstalled: globallyInstalled,
                previouslyConfigured: previouslyConfigured,
                output: output,
                allowEmpty: prune
            )
        }
        if prune, packs.isEmpty {
            output.warn("Every named pack is installed globally, so --prune leaves this scope with no packs.")
        }

        output.header("Sync \(scopeLabel)")
        output.plain("")
        output.info(label: scopeLabel, targetPath)
        output.info(label: "Packs", packs.map(\.displayName).joined(separator: ", "))

        if dryRun {
            try configurator.dryRun(packs: packs)
        } else {
            try configurator.configure(packs: packs, confirmRemovals: prune && !yes)
            output.header("Done")
            output.info("Run 'mcs doctor' to verify configuration")
        }

        ConfiguratorSupport.reportKeptExtras(
            desired.keptExtras,
            notIn: "named with --pack",
            remedy: "Run with --prune to remove them.",
            output: output
        )
    }
}
