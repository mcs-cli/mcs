import ArgumentParser
import Foundation

struct PackCommandContext {
    let env: Environment
    let output: CLIOutput
    let shell: ShellRunner
    let registry: PackRegistryFile

    init() {
        env = Environment()
        output = CLIOutput()
        shell = ShellRunner(environment: env)
        registry = PackRegistryFile(path: env.packsRegistry)
    }

    /// Injectable initializer used by tests to point the context at a sandbox home.
    init(env: Environment, output: CLIOutput, shell: ShellRunner, registry: PackRegistryFile) {
        self.env = env
        self.output = output
        self.shell = shell
        self.registry = registry
    }

    func loadRegistry() throws -> PackRegistryFile.RegistryData {
        do {
            return try registry.load()
        } catch {
            output.error("Failed to read pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

struct PackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pack",
        abstract: "Manage external tech packs",
        subcommands: [AddPack.self, RemovePack.self, UpdatePack.self, ListPacks.self, ValidatePack.self]
    )
}

// MARK: - Add

struct AddPack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a tech pack from a Git repository or local path"
    )

    @Argument(help: "Git URL, GitHub shorthand (user/repo), or local path")
    var source: String

    @Option(name: .shortAndLong, help: "Git tag or branch (git packs only; commit SHAs are not supported)")
    var ref: String?

    @Flag(name: .shortAndLong, help: "Preview pack contents without installing")
    var preview: Bool = false

    var skipLock: Bool {
        preview
    }

    func perform() throws {
        let ctx = PackCommandContext()

        let resolver = PackSourceResolver()
        let packSource: PackSource
        do {
            packSource = try resolver.resolve(source)
        } catch let error as PackSourceError {
            ctx.output.error(error.localizedDescription)
            throw ExitCode.failure
        }

        if case let .gitURL(expanded) = packSource,
           source.range(of: PackSourceResolver.shorthandPattern, options: .regularExpression) != nil {
            ctx.output.info("Interpreting '\(source)' as GitHub shorthand: \(expanded)")
        }

        var options = PackAdder.Options()
        options.preview = preview
        _ = try PackAdder(ctx: ctx).add(source: packSource, ref: ref, options: options)
    }
}

// MARK: - Remove

struct RemovePack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a tech pack"
    )

    @Argument(help: "Pack identifier to remove")
    var identifier: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt")
    var force: Bool = false

    func perform() throws {
        let ctx = PackCommandContext()
        let fetcher = PackFetcher(
            shell: ctx.shell,
            output: ctx.output,
            packsDirectory: ctx.env.packsDirectory
        )

        // 1. Look up pack in registry
        let registryData = try ctx.loadRegistry()

        guard let entry = ctx.registry.pack(identifier: identifier, in: registryData) else {
            ctx.output.error("Pack '\(identifier)' is not installed.")
            throw ExitCode.failure
        }

        guard let packPath = entry.resolvedPath(packsDirectory: ctx.env.packsDirectory) else {
            if entry.isLocalPack {
                ctx.output.error("Pack '\(entry.identifier)' has an invalid local path: '\(entry.localPath)'")
            } else {
                ctx.output.error("Pack localPath escapes packs directory — refusing to proceed")
            }
            throw ExitCode.failure
        }

        // 2. Show pack info
        ctx.output.info("Pack: \(entry.displayName)")
        if let author = entry.author {
            ctx.output.plain("  Author: \(author)")
        }
        if entry.isLocalPack {
            ctx.output.plain("  Source: \(entry.sourceURL) (local)")
        } else {
            ctx.output.plain("  Source: \(entry.sourceURL)")
            ctx.output.plain("  Local:  ~/.mcs/packs/\(entry.localPath)")
        }

        // 3. Discover affected scopes
        let techPackRegistry = TechPackRegistry.loadWithExternalPacks(environment: ctx.env, output: ctx.output)

        let indexFile = ProjectIndex(path: ctx.env.projectsIndexFile)
        let indexData: ProjectIndex.IndexData
        do {
            indexData = try indexFile.load()
        } catch {
            ctx.output.warn("Could not read project index — per-project cleanup may be incomplete.")
            indexData = ProjectIndex.IndexData()
        }
        let affectedEntries = indexFile.projects(withPack: identifier, in: indexData)

        let isGloballyConfigured: Bool
        do {
            let globalState = try ProjectState(stateFile: ctx.env.globalStateFile)
            isGloballyConfigured = globalState.configuredPacks.contains(identifier)
        } catch {
            ctx.output.warn("Could not read global state — global cleanup may be incomplete.")
            isGloballyConfigured = false
        }

        var liveProjectPaths: [String] = []
        var staleProjectPaths: [String] = []
        for projectEntry in affectedEntries {
            guard projectEntry.path != ProjectIndex.globalSentinel else { continue }
            if FileManager.default.fileExists(atPath: projectEntry.path) {
                liveProjectPaths.append(projectEntry.path)
            } else {
                staleProjectPaths.append(projectEntry.path)
            }
        }

        if isGloballyConfigured || !liveProjectPaths.isEmpty {
            ctx.output.plain("")
            ctx.output.plain("  Affected scopes:")
            if isGloballyConfigured {
                ctx.output.plain("    Global (~/.claude/)")
            }
            for path in liveProjectPaths {
                ctx.output.plain("    \(path)")
            }
        }
        if !staleProjectPaths.isEmpty {
            ctx.output.plain("  Stale references (will be pruned):")
            for path in staleProjectPaths {
                ctx.output.dimmed("    \(path)")
            }
        }
        ctx.output.plain("")

        // 4. Confirm
        if !force {
            guard ctx.output.askYesNo("Remove pack '\(entry.displayName)'?", default: false) else {
                ctx.output.info("Pack not removed.")
                return
            }
        }

        // 5. Federated unconfigure — remove artifacts from all affected scopes
        if isGloballyConfigured {
            do {
                var globalState = try ProjectState(stateFile: ctx.env.globalStateFile)
                let configurator = Configurator(
                    environment: ctx.env,
                    output: ctx.output,
                    shell: ctx.shell,
                    registry: techPackRegistry,
                    strategy: GlobalSyncStrategy(environment: ctx.env)
                )
                configurator.unconfigurePack(
                    identifier,
                    state: &globalState,
                    refCountScope: ProjectIndex.packRemoveSentinel
                )
                try globalState.save()
            } catch {
                ctx.output.warn("Global cleanup failed: \(error.localizedDescription)")
            }
        }

        for projectPath in liveProjectPaths {
            do {
                let projectURL = URL(fileURLWithPath: projectPath)
                var projectState = try ProjectState(projectRoot: projectURL)
                let configurator = Configurator(
                    environment: ctx.env,
                    output: ctx.output,
                    shell: ctx.shell,
                    registry: techPackRegistry,
                    strategy: ProjectSyncStrategy(projectPath: projectURL, environment: ctx.env)
                )
                configurator.unconfigurePack(
                    identifier,
                    state: &projectState,
                    refCountScope: ProjectIndex.packRemoveSentinel
                )
                try projectState.save()
            } catch {
                ctx.output.warn("Cleanup for \(projectPath) failed: \(error.localizedDescription)")
            }
        }

        // 6. Update project index
        do {
            var updatedIndex = try indexFile.load()
            indexFile.removePack(identifier, from: &updatedIndex)
            for stalePath in staleProjectPaths {
                indexFile.remove(projectPath: stalePath, from: &updatedIndex)
            }
            try indexFile.save(updatedIndex)
        } catch {
            ctx.output.error("Could not update project index: \(error.localizedDescription)")
            ctx.output.error("Run 'mcs sync' to reconcile, or manually edit ~/.mcs/projects.yaml")
        }

        // 7. Remove from registry
        do {
            var data = registryData
            ctx.registry.remove(identifier: identifier, from: &data)
            try ctx.registry.save(data)
        } catch {
            ctx.output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // 8. Delete local checkout (skip for local packs — don't delete user's source directory)
        if !entry.isLocalPack {
            fetcher.removeQuietly(packPath: packPath)
        }

        ctx.output.success("Pack '\(entry.displayName)' removed.")
    }
}

// MARK: - Update

struct UpdatePack: LockedCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update tech packs to the latest version"
    )

    @Argument(help: "Pack identifier to update (omit for all)")
    var identifier: String?

    func perform() throws {
        let ctx = PackCommandContext()

        let updater = PackUpdater(
            fetcher: PackFetcher(shell: ctx.shell, output: ctx.output, packsDirectory: ctx.env.packsDirectory),
            trustManager: PackTrustManager(output: ctx.output),
            environment: ctx.env,
            output: ctx.output
        )

        let registryData = try ctx.loadRegistry()

        let packsToUpdate: [PackRegistryFile.PackEntry]
        if let identifier {
            guard let entry = ctx.registry.pack(identifier: identifier, in: registryData) else {
                ctx.output.error("Pack '\(identifier)' is not installed.")
                throw ExitCode.failure
            }
            packsToUpdate = [entry]
        } else {
            packsToUpdate = registryData.packs
        }

        if packsToUpdate.isEmpty {
            ctx.output.info("No external packs installed.")
            return
        }

        var updatedData = registryData
        var updatedCount = 0
        var attemptedCount = 0
        var failedPacks: [String] = []

        for entry in packsToUpdate {
            if entry.isLocalPack {
                if identifier != nil {
                    ctx.output.info("\(entry.displayName) is a local pack — changes are picked up automatically on next sync.")
                } else {
                    ctx.output.dimmed("\(entry.displayName): local pack (always up to date)")
                }
                continue
            }

            attemptedCount += 1
            ctx.output.info("Checking \(entry.displayName)...")

            guard let packPath = entry.resolvedPath(packsDirectory: ctx.env.packsDirectory) else {
                ctx.output.error("Pack '\(entry.identifier)' has an invalid path — skipping")
                failedPacks.append(entry.identifier)
                continue
            }

            let result = updater.updateGitPack(entry: entry, packPath: packPath, registry: ctx.registry)
            switch result {
            case .alreadyUpToDate:
                ctx.output.success("\(entry.displayName): already up to date")
            case let .updated(updatedEntry, diff):
                ctx.registry.register(updatedEntry, in: &updatedData)
                updatedCount += 1
                ctx.output.success("\(entry.displayName): updated (\(updatedEntry.shortSHA))")
                ctx.output.packChangeSummary(diff)
            case .trustDeclined:
                ctx.output.info("\(entry.identifier): \(result.reason ?? "trust not granted") (will re-prompt next run)")
            case .fetchFailed, .manifestInvalid, .internalError:
                ctx.output.warn("\(entry.identifier): \(result.reason ?? "update failed")")
                failedPacks.append(entry.identifier)
            }
        }

        // Save all updates
        if updatedCount > 0 {
            do {
                try ctx.registry.save(updatedData)
            } catch {
                ctx.output.error("Failed to save registry: \(error.localizedDescription)")
                throw ExitCode.failure
            }
            ctx.output.plain("")
            ctx.output.info("Run 'mcs update --all-projects' to apply updates across every configured project plus the global scope.")
        }

        if PackUpdater.shouldExitNonZero(
            failedCount: failedPacks.count,
            attemptedCount: attemptedCount,
            isInteractive: ctx.output.hasInteractiveStdin
        ) {
            throw ExitCode.failure
        }
    }
}

// MARK: - List

struct ListPacks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed tech packs"
    )

    func run() throws {
        let ctx = PackCommandContext()

        ctx.output.header("Tech Packs")

        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try ctx.registry.load()
        } catch {
            ctx.output.warn("Could not read pack registry: \(error.localizedDescription)")
            return
        }

        if registryData.packs.isEmpty {
            ctx.output.plain("")
            ctx.output.dimmed("No packs installed.")
            ctx.output.dimmed("Add one with: mcs pack add <source>")
        } else {
            ctx.output.plain("")
            for entry in registryData.packs {
                let status = packStatus(entry: entry, env: ctx.env)
                let authorLabel = entry.author.map { "  by \($0)" } ?? ""
                ctx.output.plain("  \(entry.identifier)\(authorLabel)  \(status)")
            }
        }

        ctx.output.plain("")
    }

    func packStatus(entry: PackRegistryFile.PackEntry, env: Environment) -> String {
        let fm = FileManager.default

        guard let packPath = entry.resolvedPath(packsDirectory: env.packsDirectory) else {
            if entry.isLocalPack {
                return "(invalid local path: \(entry.localPath))"
            }
            return "(invalid path — escapes packs directory)"
        }

        guard fm.fileExists(atPath: packPath.path) else {
            if entry.isLocalPack {
                return "(local — missing at \(entry.localPath))"
            }
            return "(missing checkout)"
        }

        if entry.isLocalPack {
            return "\(entry.sourceURL) (local)"
        }

        let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        guard fm.fileExists(atPath: manifestURL.path) else {
            return "(invalid — no \(Constants.ExternalPacks.manifestFilename))"
        }

        return entry.sourceURL
    }
}
