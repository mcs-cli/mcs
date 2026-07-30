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
        /// `diff` is `nil` when the pre-update snapshot could not be taken (e.g. the *previous*
        /// manifest no longer decodes) — distinct from an empty `PackDiff`, which means the
        /// update genuinely changed nothing the pack declares.
        case updated(PackRegistryFile.PackEntry, diff: PackDiff?)
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
        // Must happen before `fetcher.update` resets the working tree — see `PackSnapshot`.
        // Unconditional, because whether an update will happen is not known until after the
        // fetch, by which point the old tree is gone. Cost is one YAML decode plus a hash per
        // referenced file, discarded on the `.alreadyUpToDate` path.
        let beforeSnapshot = snapshot(packPath: packPath, registry: registry)

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
                    entry: entry, packPath: packPath, registry: registry, commitSHA: diskSHA,
                    beforeSnapshot: beforeSnapshot
                )
            }
            return .alreadyUpToDate
        }

        return validateAndTrust(
            entry: entry, packPath: packPath, registry: registry, commitSHA: result.commitSHA,
            beforeSnapshot: beforeSnapshot
        )
    }

    /// Snapshot the pack as it stands on disk, swallowing failure rather than propagating it.
    ///
    /// A pack whose *previous* manifest no longer decodes must still be updatable — refusing to
    /// update it would strand the user on the broken revision, with no way forward short of
    /// removing and re-adding the pack. Losing the diff is the correct price.
    ///
    /// Silent by design: this runs before the fetch, so the outcome may well be
    /// `.alreadyUpToDate` or `.fetchFailed`, where a note about a missing change summary is
    /// noise about output that was never going to be printed. `.updated` is the only case that
    /// wanted a diff, so that is where the absence is worth mentioning.
    private func snapshot(packPath: URL, registry: PackRegistryFile) -> PackSnapshot? {
        let loader = ExternalPackLoader(environment: environment, registry: registry)
        do {
            return try PackSnapshot.capture(packPath: packPath, loader: loader)
        } catch {
            return nil
        }
    }

    /// Validate the manifest, detect new scripts, prompt for trust, and build an updated entry.
    private func validateAndTrust(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile,
        commitSHA: String,
        beforeSnapshot: PackSnapshot?
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

        // The after-snapshot goes through `snapshot` rather than reusing the `manifest` loaded
        // above because a snapshot is manifest *plus* file hashes, and both sides must be
        // produced by the same code path for their hash maps to be comparable.
        let diff: PackDiff?
        if let beforeSnapshot, let after = snapshot(packPath: packPath, registry: registry) {
            diff = PackDiff.between(old: beforeSnapshot, new: after)
        } else {
            diff = nil
            output.dimmed("\(entry.displayName): no change summary available")
        }

        return .updated(updatedEntry, diff: diff)
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
