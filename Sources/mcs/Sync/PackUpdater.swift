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
        /// SHA equality is the sole trigger. A caller that mutated the input
        /// `entry.ref` before calling must persist the entry itself; this case
        /// does not carry the ref change through the registry.
        case alreadyUpToDate
        /// `diff` is `nil` when the pre-update snapshot could not be taken (e.g. the *previous*
        /// manifest no longer decodes) — distinct from an empty `PackDiff`, which means the
        /// update genuinely changed nothing the pack declares.
        case updated(PackRegistryFile.PackEntry, diff: PackDiff?)
        case fetchFailed(underlying: Error) // git fetch/pull or HEAD read failed (network/transport/ref/broken checkout)
        case manifestInvalid(underlying: Error) // fetched revision's techpack.yaml is unusable
        case trustDeclined // user declined the trust prompt — expected, zero exit
        case internalError(underlying: Error) // script analysis / trust prompt crashed
        /// The update did not land and the checkout could not return to the trusted commit, so
        /// its pack-hosted plugins stay removed.
        case restoreFailed(underlying: Error)
    }

    /// Fetch, validate, and re-trust a single git pack entry.
    /// The caller is responsible for skipping local packs and resolving the pack path.
    func updateGitPack(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile
    ) -> UpdateResult {
        if PackRegistryFile.PackEntry.isCheckoutMissing(at: packPath) {
            return recloneMissingCheckout(entry: entry, packPath: packPath, registry: registry)
        }

        // Must happen before the working tree moves — see `PackSnapshot`. Unconditional, because
        // whether an update will happen is not known until after the fetch. Cost is one YAML decode
        // plus a hash per referenced file, discarded on the `.alreadyUpToDate` path.
        let beforeSnapshot = snapshot(packPath: packPath, registry: registry)

        // A failure to read HEAD is the same class of git-layer error as a failed fetch — one case.
        let head: String
        let target: String
        do {
            head = try fetcher.currentCommit(at: packPath)
            target = try fetcher.fetchTarget(packPath: packPath, ref: entry.ref)
        } catch {
            return .fetchFailed(underlying: error)
        }

        let linked: [String]
        do {
            linked = try PackMarketplace.linkedPlugins(packID: entry.identifier, environment: environment)
        } catch {
            return .internalError(underlying: error)
        }

        let result: UpdateResult
        if target != head || head != entry.commitSHA {
            // The checkout is about to hold content not yet trusted — or already does, when an
            // older mcs left it ahead of the registry after a declined prompt. Pack-hosted plugins
            // are copied again only from trusted content, so they are dropped until that happens.
            do {
                try unlink(linked, of: entry)
            } catch {
                return .internalError(underlying: error)
            }
            do {
                try fetcher.reset(packPath: packPath, to: target)
                result = validateAndTrust(
                    entry: entry, packPath: packPath, registry: registry, commitSHA: target,
                    beforeSnapshot: beforeSnapshot
                )
            } catch {
                result = .fetchFailed(underlying: error)
            }
        } else {
            // No new commit, so plugins stay linked. Recorded trust may still not describe what is
            // on disk — a registry SHA advanced without re-trust, a map naming files a past update
            // renamed, or local edits. Without this check the loader's "run 'mcs pack update' to
            // re-trust" advice is a dead end: refused at load, "already up to date" forever.
            guard trustNeedsRenewal(entry: entry, packPath: packPath, snapshot: beforeSnapshot) else {
                return .alreadyUpToDate
            }
            // Approving here trusts whatever is on disk, local edits included — the prompt showed them.
            result = validateAndTrust(
                entry: entry, packPath: packPath, registry: registry, commitSHA: entry.commitSHA,
                beforeSnapshot: beforeSnapshot
            )
        }
        return finish(result, entry: entry, packPath: packPath, registry: registry, linked: linked)
    }

    /// The one exit. Anything short of a trusted update returns the checkout to the trusted commit,
    /// even when HEAD already is that commit: that restores a tracked file deleted locally and
    /// discards local edits, which is fine only because mcs owns this checkout — don't skip it as
    /// a no-op.
    private func finish(
        _ result: UpdateResult, entry: PackRegistryFile.PackEntry, packPath: URL,
        registry: PackRegistryFile, linked: [String]
    ) -> UpdateResult {
        if !result.isUpdated {
            do {
                try fetcher.reset(packPath: packPath, to: entry.commitSHA)
            } catch {
                output.warn("  \(entry.displayName): could not return to the trusted commit: \(error.localizedDescription)")
                // Without a copied plugin nothing loads what is on disk: the pack itself refuses
                // untrusted content at load, so a warning is enough.
                guard linked.isEmpty else {
                    do {
                        try unlink(linked, of: entry)
                    } catch {
                        output.error("  Could not unlink \(entry.displayName)'s plugins: \(error.localizedDescription)")
                    }
                    return .restoreFailed(underlying: error)
                }
                return result
            }
        }
        if !linked.isEmpty {
            relinkHostedPlugins(entry: entry, packPath: packPath, registry: registry)
        }
        return result
    }

    private func unlink(_ plugins: [String], of entry: PackRegistryFile.PackEntry) throws {
        for name in plugins {
            try PackMarketplace.unlink(pluginName: name, packID: entry.identifier, environment: environment)
        }
    }

    /// Links the plugins the checkout's manifest hosts now, so one an update renamed or added is
    /// linked and one it dropped stays unlinked until sync uninstalls it.
    private func relinkHostedPlugins(entry: PackRegistryFile.PackEntry, packPath: URL, registry: PackRegistryFile) {
        do {
            let manifest = try ExternalPackLoader(environment: environment, registry: registry).validate(at: packPath)
            for plugin in try PackMarketplace.hostedPlugins(in: manifest, packPath: packPath) {
                _ = try PackMarketplace.link(
                    pluginName: plugin.name, to: plugin.source, packID: entry.identifier, environment: environment
                )
            }
        } catch {
            output.warn("  \(entry.displayName): its plugins stay removed until 'mcs sync': \(error.localizedDescription)")
        }
    }

    /// Without a re-clone every `git` call against the deleted checkout fails, and no command
    /// ever brings the pack back. Clones at the recorded ref and re-verify trust against the recorded hashes, so an intact
    /// copy of already-trusted content does not prompt again.
    private func recloneMissingCheckout(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        registry: PackRegistryFile
    ) -> UpdateResult {
        output.warn("\(entry.displayName): local checkout is missing — re-cloning from \(redactSourceForDisplay(entry.sourceURL))")
        let fetchResult: PackFetcher.FetchResult
        do {
            fetchResult = try fetcher.clone(url: entry.sourceURL, into: packPath, ref: entry.ref)
        } catch {
            return .fetchFailed(underlying: error)
        }
        let result = validateAndTrust(
            entry: entry, packPath: packPath, registry: registry, commitSHA: fetchResult.commitSHA,
            beforeSnapshot: nil
        )
        if case .updated = result { return result }
        // A copy left behind no longer reads as missing, so the next bootstrap would skip it as
        // already registered instead of retrying.
        fetcher.removeQuietly(packPath: packPath)
        return result
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

    /// Whether recorded trust still covers what is on disk at the current commit. Covers inline
    /// items too, so a stale `shell:` or MCP-command hash is caught, not just a changed file.
    ///
    /// Reuses the pre-fetch snapshot's manifest: this only runs when the fetch moved nothing, so
    /// the tree it described is the tree on disk. A `nil` snapshot means its `validate` threw, and
    /// `validateAndTrust` is left to report the real error rather than this claiming trust is fine.
    private func trustNeedsRenewal(
        entry: PackRegistryFile.PackEntry,
        packPath: URL,
        snapshot: PackSnapshot?
    ) -> Bool {
        guard let manifest = snapshot?.manifest else { return true }
        do {
            let items = try trustManager.analyzeScripts(manifest: manifest, packPath: packPath)
            return !trustManager.newOrChanged(
                in: items,
                against: entry.trustedScriptHashes,
                packPath: packPath
            ).isEmpty
        } catch {
            return true
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

        let allItems: [TrustableItem]
        do {
            allItems = try trustManager.analyzeScripts(manifest: manifest, packPath: packPath)
        } catch {
            return .internalError(underlying: error)
        }
        let newItems = trustManager.newOrChanged(
            in: allItems,
            against: entry.trustedScriptHashes,
            packPath: packPath
        )

        if !newItems.isEmpty {
            output.warn("\(entry.displayName) has new or modified scripts:")
            guard trustManager.promptForTrust(
                manifest: manifest,
                packPath: packPath,
                items: newItems
            ) else {
                return .trustDeclined
            }
        }

        // Rebuild the map from the analyzed items instead of merging into the old one: merging left
        // a key behind for every file an update renamed or deleted, and `verifyTrust` then refused
        // the pack over files it no longer shipped. Unconditional even when nothing prompted — a
        // commit that only *removes* a script produces no new items, and that is exactly the
        // orphan case.
        //
        // This can never silently trust changed content: any item whose hash differs is in
        // `newItems`, hence already prompted.
        let scriptHashes: [String: String]
        do {
            scriptHashes = try trustManager.computeScriptHashes(items: allItems, packPath: packPath)
        } catch {
            return .internalError(underlying: error)
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
        // Reporting a missing summary is the caller's job: it has to happen *after* the
        // "updated" line, which cannot be printed until this result is returned.
        var diff: PackDiff?
        if let beforeSnapshot, let after = snapshot(packPath: packPath, registry: registry) {
            diff = PackDiff.between(old: beforeSnapshot, new: after)
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
    var isUpdated: Bool {
        if case .updated = self { return true }
        return false
    }

    var isHardFailure: Bool {
        switch self {
        case .fetchFailed, .manifestInvalid, .internalError, .restoreFailed:
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
        case let .restoreFailed(error):
            "could not return to the trusted commit, its plugins stay removed — \(error.localizedDescription)"
        }
    }
}
