import ArgumentParser
import Foundation

/// Reusable pack-add pipeline shared by `mcs pack add` (interactive) and
/// `mcs bootstrap` (non-interactive). Both go through one code path so the
/// fetch → validate → collision → trust → register sequence stays consistent.
struct PackAdder {
    enum DuplicatePolicy {
        /// Ask the user (existing `mcs pack add` behaviour) when the identifier
        /// or an artifact name collides with an already-installed pack.
        case prompt
        /// Accept the duplicate / collision automatically after printing the
        /// same warning. Used by `mcs bootstrap`, whose declarative file
        /// already expresses the user's intent to install this pack.
        case autoAccept
    }

    struct Options {
        var duplicatePolicy: DuplicatePolicy = .prompt
        var preview: Bool = false
        var showNextSteps: Bool = true
    }

    enum Outcome {
        /// Newly registered (or replaced) — the freshly-registered entry.
        case installed(PackRegistryFile.PackEntry)
        /// User declined the trust prompt or the duplicate/collision prompt.
        case declined
        /// Preview mode — nothing was registered.
        case previewed(ExternalPackManifest)
    }

    let ctx: PackCommandContext

    // MARK: - Entry Point

    /// Add a pack from either a git source or a local path.
    func add(source: PackSource, ref: String?, options: Options) throws -> Outcome {
        switch source {
        case let .gitURL(url):
            return try addGit(gitURL: url, ref: ref, options: options)
        case let .localPath(path):
            if ref != nil {
                ctx.output.warn("--ref is ignored for local packs")
            }
            return try addLocal(path: path, options: options)
        }
    }

    // MARK: - Git

    private func addGit(gitURL: String, ref: String?, options: Options) throws -> Outcome {
        if let ref, ref.hasPrefix("-") {
            ctx.output.error("Invalid ref: must not start with '-'")
            throw ExitCode.failure
        }

        let fetcher = PackFetcher(
            shell: ctx.shell,
            output: ctx.output,
            packsDirectory: ctx.env.packsDirectory
        )
        let loader = ExternalPackLoader(environment: ctx.env, registry: ctx.registry)

        ctx.output.info("Fetching pack from \(gitURL)...")
        let tempID = "tmp-\(UUID().uuidString.prefix(8))"
        let fetchResult: PackFetcher.FetchResult
        do {
            fetchResult = try fetcher.fetch(url: gitURL, identifier: tempID, ref: ref)
        } catch {
            ctx.output.error("Failed to fetch pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: fetchResult.localPath)
        } catch {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.error("Invalid pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        ctx.output.success("Found pack: \(manifest.displayName)")

        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try ctx.loadRegistry()
        } catch {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            throw error
        }

        guard resolveDuplicate(
            manifest: manifest,
            sourceURL: gitURL,
            registryData: registryData,
            policy: options.duplicatePolicy
        ) else {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.info("Pack not added.")
            return .declined
        }

        let collisions = detectCollisions(manifest: manifest, registryData: registryData)
        if !collisions.isEmpty, !acceptCollisions(policy: options.duplicatePolicy) {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.info("Pack not added.")
            return .declined
        }

        displayPackSummary(manifest: manifest, output: ctx.output)

        if options.preview {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.info("Preview complete. No changes made.")
            return .previewed(manifest)
        }

        let trustedHashes: [String: String]?
        do {
            trustedHashes = try verifyTrust(manifest: manifest, packPath: fetchResult.localPath)
        } catch {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.error("Trust verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard let approvedHashes = trustedHashes else {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.info("Pack not trusted. No changes made.")
            return .declined
        }

        guard let finalPath = PathContainment.safePath(
            relativePath: manifest.identifier,
            within: ctx.env.packsDirectory
        ) else {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.error("Pack identifier escapes packs directory — refusing to install")
            throw ExitCode.failure
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: finalPath.path) {
                try fm.removeItem(at: finalPath)
            }
            try fm.moveItem(at: fetchResult.localPath, to: finalPath)
        } catch {
            fetcher.removeQuietly(packPath: fetchResult.localPath)
            ctx.output.error("Failed to move pack to final location: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let entry = PackRegistryFile.PackEntry(
            identifier: manifest.identifier,
            displayName: manifest.displayName,
            author: manifest.author,
            sourceURL: gitURL,
            ref: ref,
            commitSHA: fetchResult.commitSHA,
            localPath: manifest.identifier,
            addedAt: ISO8601DateFormatter().string(from: Date()),
            trustedScriptHashes: approvedHashes,
            isLocal: nil
        )

        try persistRegistry(entry: entry, registryData: registryData)

        ctx.output.success("Pack '\(manifest.displayName)' added successfully.")
        if options.showNextSteps {
            ctx.output.plain("")
            ctx.output.info("Next step: run 'mcs sync' to apply the pack to your project.")
        }
        return .installed(entry)
    }

    // MARK: - Local

    private func addLocal(path: URL, options: Options) throws -> Outcome {
        let loader = ExternalPackLoader(environment: ctx.env, registry: ctx.registry)

        ctx.output.info("Reading pack from \(path.path)...")
        let manifest: ExternalPackManifest
        do {
            manifest = try loader.validate(at: path)
        } catch {
            ctx.output.error("Invalid pack: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        ctx.output.success("Found pack: \(manifest.displayName)")

        let registryData = try ctx.loadRegistry()

        guard resolveDuplicate(
            manifest: manifest,
            sourceURL: path.path,
            registryData: registryData,
            policy: options.duplicatePolicy
        ) else {
            ctx.output.info("Pack not added.")
            return .declined
        }

        let collisions = detectCollisions(manifest: manifest, registryData: registryData)
        if !collisions.isEmpty, !acceptCollisions(policy: options.duplicatePolicy) {
            ctx.output.info("Pack not added.")
            return .declined
        }

        displayPackSummary(manifest: manifest, output: ctx.output)

        if options.preview {
            ctx.output.info("Preview complete. No changes made.")
            return .previewed(manifest)
        }

        let trustedHashes: [String: String]?
        do {
            trustedHashes = try verifyTrust(manifest: manifest, packPath: path)
        } catch {
            ctx.output.error("Trust verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        guard let approvedHashes = trustedHashes else {
            ctx.output.info("Pack not trusted. No changes made.")
            return .declined
        }

        let entry = PackRegistryFile.PackEntry(
            identifier: manifest.identifier,
            displayName: manifest.displayName,
            author: manifest.author,
            sourceURL: path.path,
            ref: nil,
            commitSHA: Constants.ExternalPacks.localCommitSentinel,
            localPath: path.path,
            addedAt: ISO8601DateFormatter().string(from: Date()),
            trustedScriptHashes: approvedHashes,
            isLocal: true
        )

        try persistRegistry(entry: entry, registryData: registryData)

        ctx.output.success("Pack '\(manifest.displayName)' added as local pack.")
        if options.showNextSteps {
            ctx.output.plain("")
            ctx.output.info("Next step: run 'mcs sync' to apply the pack to your project.")
        }
        return .installed(entry)
    }

    // MARK: - Shared Helpers

    private func detectCollisions(
        manifest: ExternalPackManifest,
        registryData: PackRegistryFile.RegistryData
    ) -> [PackCollision] {
        let existing: [PackRegistryFile.CollisionInput] = registryData.packs.map { entry in
            guard let packPath = entry.resolvedPath(packsDirectory: ctx.env.packsDirectory) else {
                ctx.output.warn("Pack '\(entry.identifier)' has an unsafe localPath — skipping collision check")
                return .empty(identifier: entry.identifier)
            }
            let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
            let existingManifest: ExternalPackManifest
            do {
                existingManifest = try ExternalPackManifest.load(from: manifestURL)
            } catch {
                let reason = error.localizedDescription
                ctx.output.warn("Could not load manifest for '\(entry.identifier)': \(reason) — collision detection may be incomplete")
                return .empty(identifier: entry.identifier)
            }
            return PackRegistryFile.CollisionInput(from: existingManifest)
        }

        let newInput = PackRegistryFile.CollisionInput(from: manifest)
        let collisions = ctx.registry.detectCollisions(newPack: newInput, existingPacks: existing)
        if !collisions.isEmpty {
            ctx.output.warn("Collisions detected with existing packs:")
            for collision in collisions {
                let conflict = "'\(collision.artifactName)' conflicts with pack '\(collision.existingPackIdentifier)'"
                ctx.output.plain("  \(collision.type): \(conflict)")
            }
        }
        return collisions
    }

    /// Returns `true` when the caller should proceed, `false` to abort.
    /// `autoAccept` short-circuits the `askYesNo` prompt so bootstrap stays non-interactive.
    private func resolveDuplicate(
        manifest: ExternalPackManifest,
        sourceURL: String,
        registryData: PackRegistryFile.RegistryData,
        policy: DuplicatePolicy
    ) -> Bool {
        guard let existing = registryData.packs.first(where: { $0.identifier == manifest.identifier }) else {
            return true
        }

        if existing.sourceURL == sourceURL {
            ctx.output.warn("Pack '\(manifest.identifier)' is already installed.")
        } else {
            ctx.output.warn("Pack identifier '\(manifest.identifier)' is already registered from a different source:")
            ctx.output.plain("  Current: \(existing.sourceURL)")
            ctx.output.plain("  New:     \(sourceURL)")
        }

        switch policy {
        case .prompt:
            return ctx.output.askYesNo("Replace existing pack?", default: false)
        case .autoAccept:
            ctx.output.plain("  Replacing (declared by mcs.yaml).")
            return true
        }
    }

    /// Prompt on collision when policy requires it. `autoAccept` returns `true`
    /// after the warning is already printed by `detectCollisions`.
    private func acceptCollisions(policy: DuplicatePolicy) -> Bool {
        switch policy {
        case .prompt:
            ctx.output.askYesNo("Continue anyway?", default: false)
        case .autoAccept:
            true
        }
    }

    private func verifyTrust(
        manifest: ExternalPackManifest,
        packPath: URL
    ) throws -> [String: String]? {
        let trustManager = PackTrustManager(output: ctx.output)
        let items = try trustManager.analyzeScripts(manifest: manifest, packPath: packPath)
        guard trustManager.promptForTrust(
            manifest: manifest,
            packPath: packPath,
            items: items
        ) else { return nil }
        return try trustManager.computeScriptHashes(items: items, packPath: packPath)
    }

    private func persistRegistry(
        entry: PackRegistryFile.PackEntry,
        registryData: PackRegistryFile.RegistryData
    ) throws {
        var data = registryData
        ctx.registry.register(entry, in: &data)
        do {
            try ctx.registry.save(data)
        } catch {
            ctx.output.error("Failed to update pack registry: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func displayPackSummary(manifest: ExternalPackManifest, output: CLIOutput) {
        output.plain("")
        output.sectionHeader("Pack Summary")
        output.plain("  Identifier: \(manifest.identifier)")
        if let author = manifest.author {
            output.plain("  Author:     \(author)")
        }
        output.plain("  \(manifest.description)")

        if let components = manifest.components, !components.isEmpty {
            output.plain("")
            output.plain("  Components (\(components.count)):")
            for component in components {
                output.plain("    - \(component.displayName) (\(component.type.rawValue))")
            }
        }

        if let templates = manifest.templates, !templates.isEmpty {
            output.plain("  Templates (\(templates.count)):")
            for template in templates {
                output.plain("    - \(template.sectionIdentifier)")
            }
        }

        output.plain("")
    }
}
