import ArgumentParser
import Foundation

/// Shared lockfile operations used by SyncCommand.
struct LockfileOperations {
    let environment: Environment
    let output: CLIOutput
    let shell: any ShellRunning

    /// Checkout exact pack commits from the lockfile.
    /// Aborts if any checkout fails, since `--lock` guarantees reproducibility for git packs.
    /// Local packs are skipped (their content is not commit-pinned).
    func checkoutLockedCommits(at projectPath: URL) throws {
        guard let lockfile = try Lockfile.load(projectRoot: projectPath) else {
            output.error("No mcs.lock.yaml found. Run 'mcs sync' first to create one.")
            throw ExitCode.failure
        }

        output.info("Checking out locked pack commits...")

        var failedPacks: [String] = []
        for locked in lockfile.packs {
            // Local packs have no git commit to pin — skip
            if locked.commitSHA == Constants.ExternalPacks.localCommitSentinel {
                output.dimmed("  \(locked.identifier): local pack (not pinned)")
                continue
            }

            // Validate commit SHA is a valid hex string (defense against flag injection)
            guard locked.commitSHA.range(of: #"^[0-9a-f]{7,64}$"#, options: .regularExpression) != nil else {
                output.warn("  \(locked.identifier): invalid commit SHA '\(locked.commitSHA)'")
                failedPacks.append(locked.identifier)
                continue
            }

            guard let packPath = PathContainment.safePath(
                relativePath: locked.identifier,
                within: environment.packsDirectory
            ) else {
                output.warn("  \(locked.identifier): identifier escapes packs directory — skipping")
                failedPacks.append(locked.identifier)
                continue
            }

            guard FileManager.default.fileExists(atPath: packPath.path) else {
                output.warn("  Pack '\(locked.identifier)' not found locally. Run 'mcs pack add \(locked.sourceURL)' first.")
                failedPacks.append(locked.identifier)
                continue
            }

            let result = shell.run(
                environment.gitPath,
                arguments: ["-C", packPath.path, "checkout", locked.commitSHA]
            )
            if result.succeeded {
                output.success("  \(locked.identifier): checked out \(String(locked.commitSHA.prefix(7)))")
            } else {
                // Shallow-fetch latest, then retry checkout
                _ = shell.run(
                    environment.gitPath,
                    arguments: ["-C", packPath.path, "fetch", "--depth", "1", "origin"]
                )
                let retry = shell.run(
                    environment.gitPath,
                    arguments: ["-C", packPath.path, "checkout", locked.commitSHA]
                )
                if retry.succeeded {
                    output.success("  \(locked.identifier): fetched and checked out \(String(locked.commitSHA.prefix(7)))")
                } else {
                    output.warn("  \(locked.identifier): failed to checkout \(String(locked.commitSHA.prefix(7)))")
                    failedPacks.append(locked.identifier)
                }
            }
        }

        if !failedPacks.isEmpty {
            output.error("Failed to checkout locked commits for: \(failedPacks.joined(separator: ", "))")
            output.error("Sync aborted to prevent inconsistent configuration.")
            throw ExitCode.failure
        }
    }

    /// Fetch latest commits for all registered git packs. Local packs are skipped.
    /// Re-validates trust when scripts change (mirrors `mcs pack update` behavior).
    func updatePacks() throws {
        let registryFile = PackRegistryFile(path: environment.packsRegistry)
        let registryData = try registryFile.load()

        if registryData.packs.isEmpty {
            output.info("No packs registered. Nothing to update.")
            return
        }

        output.info("Fetching latest pack commits...")
        let updater = PackUpdater(
            fetcher: PackFetcher(shell: shell, output: output, packsDirectory: environment.packsDirectory),
            trustManager: PackTrustManager(output: output),
            environment: environment,
            output: output
        )

        var updatedData = registryData
        for entry in registryData.packs {
            if entry.isLocalPack {
                output.dimmed("  \(entry.identifier): local pack (skipped)")
                continue
            }

            guard let packPath = entry.resolvedPath(packsDirectory: environment.packsDirectory) else {
                output.warn("  \(entry.identifier): invalid path — skipping")
                continue
            }

            let result = updater.updateGitPack(entry: entry, packPath: packPath, registry: registryFile)
            switch result {
            case .alreadyUpToDate:
                output.dimmed("  \(entry.identifier): already up to date")
            case let .updated(updatedEntry):
                registryFile.register(updatedEntry, in: &updatedData)
                output.success("  \(entry.identifier): updated (\(String(updatedEntry.commitSHA.prefix(7))))")
            case let .skipped(reason):
                output.warn("  \(entry.identifier): \(reason)")
            }
        }

        try registryFile.save(updatedData)
    }

    /// Write the lockfile after a successful sync.
    func writeLockfile(at projectPath: URL) throws {
        let registryFile = PackRegistryFile(path: environment.packsRegistry)
        let registryData = try registryFile.load()

        let projectState = try ProjectState(projectRoot: projectPath)
        let configuredIDs = projectState.configuredPacks

        guard !configuredIDs.isEmpty else { return }

        if let existing = try Lockfile.load(projectRoot: projectPath) {
            let mismatches = existing.detectMismatches(registryEntries: registryData.packs)
            for mismatch in mismatches {
                if let currentSHA = mismatch.currentSHA {
                    let current = String(currentSHA.prefix(7))
                    let expected = String(mismatch.lockedSHA.prefix(7))
                    output.warn("Pack '\(mismatch.identifier)' is at \(current) but lockfile expected \(expected).")
                }
            }
        }

        let lockfile = Lockfile.generate(
            registryEntries: registryData.packs,
            selectedPackIDs: configuredIDs
        )
        try lockfile.save(projectRoot: projectPath)
        output.success("Updated mcs.lock.yaml")
    }
}
