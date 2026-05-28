import Foundation

/// Handles the fetch → validate → trust cycle for updating a single git pack.
/// Used by both `UpdatePack` (interactive) and `UpdateCommand` (multi-scope refresh).
struct PackUpdater {
    let fetcher: PackFetcher
    let trustManager: PackTrustManager
    let environment: Environment
    let output: CLIOutput

    /// Result of attempting to update a single git pack.
    ///
    /// Cases split by *which operation failed*, not by parsing git stderr — a transport
    /// outage and a trust-decline must be distinguishable so callers can choose an exit code
    /// (a systemic failure should be non-zero; a user trust-decline is a zero-exit outcome).
    enum UpdateResult {
        case alreadyUpToDate
        case updated(PackRegistryFile.PackEntry)
        case fetchFailed(underlying: Error) // git fetch/pull or HEAD read failed (network/transport/ref/broken checkout)
        case manifestInvalid(underlying: Error) // fetched revision's techpack.yaml is unusable
        case trustDeclined // user declined the trust prompt — expected, zero exit
        case internalError(underlying: Error) // script analysis / trust prompt crashed
    }

    /// Fetch, validate, and re-trust a single git pack entry.
    /// The caller is responsible for skipping local packs and resolving the pack path.
    func updateGitPack(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile
    ) -> UpdateResult {
        let fetchResult: PackFetcher.FetchResult?
        do {
            fetchResult = try fetcher.update(packPath: packPath, ref: entry.ref)
        } catch {
            return .fetchFailed(underlying: error)
        }

        guard let result = fetchResult else {
            // Disk may be ahead of registry if trust was denied on a previous update.
            // A failure to read HEAD here is the same class of git-layer error as a failed
            // fetch (and `fetcher.update` itself reads HEAD before fetching, so a broken
            // checkout already surfaces as `.fetchFailed`) — keep them one case.
            let diskSHA: String
            do {
                diskSHA = try fetcher.currentCommit(at: packPath)
            } catch {
                return .fetchFailed(underlying: error)
            }
            if diskSHA != entry.commitSHA {
                return validateAndTrust(
                    entry: entry, packPath: packPath, registry: registry, commitSHA: diskSHA
                )
            }
            return .alreadyUpToDate
        }

        return validateAndTrust(
            entry: entry, packPath: packPath, registry: registry, commitSHA: result.commitSHA
        )
    }

    /// Validate the manifest, detect new scripts, prompt for trust, and build an updated entry.
    private func validateAndTrust(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile,
        commitSHA: String
    ) -> UpdateResult {
        let loader = ExternalPackLoader(environment: environment, registry: registry)
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: packPath)
        } catch {
            return .manifestInvalid(underlying: error)
        }

        var scriptHashes = entry.trustedScriptHashes
        let newItems: [TrustableItem]
        do {
            newItems = try trustManager.detectNewScripts(
                currentHashes: entry.trustedScriptHashes,
                updatedPackPath: packPath,
                manifest: manifest
            )
        } catch {
            return .internalError(underlying: error)
        }

        if !newItems.isEmpty {
            output.warn("\(entry.displayName) has new or modified scripts:")
            let decision: PackTrustManager.TrustDecision
            do {
                decision = try trustManager.promptForTrust(
                    manifest: manifest,
                    packPath: packPath,
                    items: newItems
                )
            } catch {
                return .internalError(underlying: error)
            }
            guard decision.approved else {
                return .trustDeclined
            }
            for (path, hash) in decision.scriptHashes {
                scriptHashes[path] = hash
            }
        }

        let updatedEntry = PackRegistryFile.PackEntry(
            identifier: entry.identifier,
            displayName: manifest.displayName,
            author: manifest.author,
            sourceURL: entry.sourceURL,
            ref: entry.ref,
            commitSHA: commitSHA,
            localPath: entry.localPath,
            addedAt: entry.addedAt,
            trustedScriptHashes: scriptHashes,
            isLocal: entry.isLocal
        )

        // Covers both `.updated` paths: fresh fetch and stale-registry recovery.
        if !UpdateChecker.invalidateCache(environment: environment) {
            output.warn(
                "Could not clear update check cache at \(environment.updateCheckCacheFile.path) — "
                    + "next session may show stale update info. "
                    + "Remove the file manually or check permissions on ~/.mcs/."
            )
        }

        return .updated(updatedEntry)
    }
}

extension PackUpdater {
    /// Exit-code policy shared by every multi-pack update caller (`mcs pack update`,
    /// `mcs update`): a hard failure exits non-zero when running non-interactively (CI), or
    /// when every attempted pack failed. A lone trust-decline is not a failure. Centralized so
    /// the callers can't drift out of contract.
    static func shouldExitNonZero(failedCount: Int, attemptedCount: Int, isInteractive: Bool) -> Bool {
        failedCount > 0 && (!isInteractive || failedCount == attemptedCount)
    }
}

extension PackUpdater.UpdateResult {
    /// Outcomes that should contribute to a non-zero exit in non-interactive use. A user
    /// trust-decline (`.trustDeclined`) is intentionally *not* a hard failure — declining is
    /// an expected choice, re-prompted on the next update.
    var isHardFailure: Bool {
        switch self {
        case .fetchFailed, .manifestInvalid, .internalError:
            true
        case .alreadyUpToDate, .updated, .trustDeclined:
            false
        }
    }

    /// Human-readable line for non-success outcomes; `nil` when there is nothing to print
    /// (the success cases render their own pack-specific messages at the call site).
    var reason: String? {
        switch self {
        case .alreadyUpToDate, .updated:
            nil
        case let .fetchFailed(error):
            "fetch failed — \(error.localizedDescription)"
        case let .manifestInvalid(error):
            "updated but manifest is invalid — \(error.localizedDescription)"
        case .trustDeclined:
            "update skipped (trust not granted)"
        case let .internalError(error):
            "could not verify pack scripts — \(error.localizedDescription)"
        }
    }
}
