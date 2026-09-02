import Foundation

/// Discovers and loads external tech packs.
/// Git packs are loaded from `~/.mcs/packs/`; local packs from their registered absolute path.
/// Reads the pack registry to find registered packs, then loads each one
/// by parsing its `techpack.yaml` manifest and wrapping it in an `ExternalPackAdapter`.
struct ExternalPackLoader {
    let environment: Environment
    let registry: PackRegistryFile

    /// Errors specific to pack loading.
    enum LoadError: Error, Equatable, LocalizedError {
        case manifestNotFound(String)
        case invalidManifest(identifier: String, reason: String)
        case incompatibleVersion(pack: String, required: String, current: String)
        case localCheckoutMissing(identifier: String, path: String)
        case referencedFilesMissing(identifier: String, files: [String])

        var errorDescription: String? {
            switch self {
            case let .manifestNotFound(path):
                "techpack.yaml not found at '\(path)'"
            case let .invalidManifest(id, reason):
                "Invalid manifest for pack '\(id)': \(reason)"
            case let .incompatibleVersion(pack, required, current):
                "Pack '\(pack)' requires mcs >= \(required), current is \(current)"
            case let .localCheckoutMissing(id, path):
                "Pack '\(id)' checkout missing at '\(path)'"
            case let .referencedFilesMissing(id, files):
                "Pack '\(id)' references missing files: \(files.joined(separator: ", "))"
            }
        }
    }

    /// A message a pack author can act on.
    ///
    /// `DecodingError.localizedDescription` collapses to "The data couldn't be read because it
    /// isn't in the correct format", discarding the `debugDescription` that names the offending
    /// component and rule — which is where the manifest's own decode-time guards put their
    /// explanation (unknown `hookEvent`, hook metadata without `hookEvent`).
    static func describe(_ error: any Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case let .dataCorrupted(context),
             let .keyNotFound(_, context),
             let .typeMismatch(_, context),
             let .valueNotFound(_, context):
            let location = Self.describe(codingPath: context.codingPath)
            return context.debugDescription + location
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    /// Render a coding path as `components[0].hookEvent`, or "" when there is nothing useful.
    private static func describe(codingPath: [any CodingKey]) -> String {
        var rendered = ""
        for key in codingPath {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else if !key.stringValue.isEmpty {
                rendered += rendered.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return rendered.isEmpty ? "" : " (at \(rendered))"
    }

    // MARK: - Loading

    /// Load all registered external packs from disk.
    /// Returns adapters for packs that exist and are valid.
    /// Logs warnings for packs that are registered but missing or invalid.
    func loadAll(output: CLIOutput) -> [ExternalPackAdapter] {
        let registryData: PackRegistryFile.RegistryData
        do {
            registryData = try registry.load()
        } catch {
            let registryPath = registry.path.path
            let message = "Could not read pack registry at '\(registryPath)': \(error.localizedDescription)"
            output.error("\(message)\n  Fix: rm '\(registryPath)' and re-add packs")
            return []
        }

        var adapters: [ExternalPackAdapter] = []

        for entry in registryData.packs {
            do {
                let adapter = try loadEntry(entry)
                adapters.append(adapter)
            } catch let error as LoadError where isTrustFailure(error) {
                output.error("SECURITY: Pack '\(entry.identifier)' failed trust verification!")
                output.error("  \(error.localizedDescription)")
                output.error("  This pack will NOT be loaded. Run 'mcs pack update \(entry.identifier)' to re-verify.")
            } catch {
                output.warn("Skipping pack '\(entry.identifier)': \(error.localizedDescription)")
            }
        }

        return adapters
    }

    /// Load a single pack by identifier.
    func load(identifier: String, output _: CLIOutput) throws -> ExternalPackAdapter {
        let registryData = try registry.load()

        guard let entry = registry.pack(identifier: identifier, in: registryData) else {
            throw LoadError.localCheckoutMissing(
                identifier: identifier,
                path: environment.packsDirectory.appendingPathComponent(identifier).path
            )
        }

        return try loadEntry(entry)
    }

    /// Validate a pack directory contains a valid techpack.yaml.
    /// Returns the parsed and validated manifest.
    ///
    /// - Parameter sanitizeOutput: When non-nil, forbidden `ignore:` entries are stripped
    ///   (with a warn log via this output) before strict validation runs. Used by the
    ///   sync-time load path so a malformed manifest doesn't break the user's workflow;
    ///   publish-time callers (`mcs pack validate`, `mcs pack add`) leave this nil so
    ///   authors see hard errors.
    func validate(at path: URL, sanitizeOutput: CLIOutput? = nil) throws -> ExternalPackManifest {
        let manifestURL = path.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        let fm = FileManager.default

        guard fm.fileExists(atPath: manifestURL.path) else {
            throw LoadError.manifestNotFound(manifestURL.path)
        }

        var manifest: ExternalPackManifest
        let raw: ExternalPackManifest
        do {
            raw = try ExternalPackManifest.load(from: manifestURL)
        } catch {
            throw LoadError.invalidManifest(
                identifier: "unknown",
                reason: Self.describe(error)
            )
        }
        do {
            manifest = try raw.normalized()
        } catch {
            throw LoadError.invalidManifest(
                identifier: raw.identifier,
                reason: error.localizedDescription
            )
        }

        // Runtime safety guard: strip forbidden `ignore:` entries and unusable hook
        // interpreters before strict validation.
        if let sanitizeOutput {
            manifest = manifest.sanitizedIgnoreEntries(output: sanitizeOutput)
            manifest = manifest.sanitizedHookInterpreters(output: sanitizeOutput)
        }

        // Validate manifest structure
        do {
            try manifest.validate()
        } catch {
            throw LoadError.invalidManifest(
                identifier: manifest.identifier,
                reason: error.localizedDescription
            )
        }

        // Check minMCSVersion compatibility
        if let minVersion = manifest.minMCSVersion {
            let current = MCSVersion.current
            if !VersionCompare.isCompatible(current: current, required: minVersion) {
                throw LoadError.incompatibleVersion(
                    pack: manifest.identifier,
                    required: minVersion,
                    current: current
                )
            }
        }

        // Verify referenced files exist
        let missingFiles = findMissingReferencedFiles(in: manifest, packPath: path)
        if !missingFiles.isEmpty {
            throw LoadError.referencedFilesMissing(
                identifier: manifest.identifier,
                files: missingFiles
            )
        }

        return manifest
    }

    /// Check if a load error is a trust verification failure.
    private func isTrustFailure(_ error: LoadError) -> Bool {
        if case let .invalidManifest(_, reason) = error {
            return reason.contains("Trusted scripts modified")
        }
        return false
    }

    // MARK: - Internal

    /// Load a pack from a registry entry.
    private func loadEntry(_ entry: PackRegistryFile.PackEntry) throws -> ExternalPackAdapter {
        guard let packPath = entry.resolvedPath(packsDirectory: environment.packsDirectory) else {
            throw LoadError.localCheckoutMissing(
                identifier: entry.identifier,
                path: entry.localPath
            )
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: packPath.path) else {
            throw LoadError.localCheckoutMissing(
                identifier: entry.identifier,
                path: packPath.path
            )
        }

        // Sync-time load: sanitize forbidden `ignore:` entries with a warn log so a
        // malformed manifest (older toolchain, hand-edit) doesn't break the user's sync.
        // Publish-time callers (`mcs pack validate`, `mcs pack add`) leave sanitizeOutput nil
        // and surface the same cases as hard errors.
        let manifest = try validate(at: packPath, sanitizeOutput: CLIOutput())

        // Skip trust verification for local packs — scripts change during development
        if !entry.isLocalPack {
            let trustManager = PackTrustManager(output: CLIOutput())
            let modified = trustManager.verifyTrust(
                trustedHashes: entry.trustedScriptHashes,
                packPath: packPath
            )
            if !modified.isEmpty {
                throw LoadError.invalidManifest(
                    identifier: entry.identifier,
                    reason:
                    "Trusted scripts modified: \(modified.joined(separator: ", ")). Run 'mcs pack update \(entry.identifier)' to re-trust."
                )
            }
        }

        let shell = ShellRunner(environment: environment)
        let output = CLIOutput()
        return ExternalPackAdapter(
            manifest: manifest,
            packPath: packPath,
            shell: shell,
            output: output
        )
    }

    /// Find files referenced in the manifest that don't exist on disk.
    /// Note: Does not check doctor check script files (shellScript command, fixScript).
    /// Those are validated at runtime when the check executes.
    private func findMissingReferencedFiles(
        in manifest: ExternalPackManifest,
        packPath: URL
    ) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []

        // Template content files
        if let templates = manifest.templates {
            for template in templates {
                let file = packPath.appendingPathComponent(template.contentFile)
                if !fm.fileExists(atPath: file.path) {
                    missing.append(template.contentFile)
                }
            }
        }

        // Configure project script
        if let configure = manifest.configureProject {
            let file = packPath.appendingPathComponent(configure.script)
            if !fm.fileExists(atPath: file.path) {
                missing.append(configure.script)
            }
        }

        // Copy pack file sources
        if let components = manifest.components {
            for component in components {
                if case let .copyPackFile(config) = component.installAction {
                    let file = packPath.appendingPathComponent(config.source)
                    if !fm.fileExists(atPath: file.path) {
                        missing.append(config.source)
                    }
                }
            }
        }

        return missing
    }
}

// MARK: - Version Comparison

/// Minimal version comparison for `minMCSVersion` checks.
/// Works with any `X.Y.Z` numeric format (SemVer, CalVer, etc.).
enum VersionCompare {
    /// Check if `current` satisfies `>= required`.
    /// Both must be in `major.minor.patch` format.
    static func isCompatible(current: String, required: String) -> Bool {
        guard let currentParts = parse(current),
              let requiredParts = parse(required)
        else {
            return false // Unparseable versions are incompatible
        }

        if currentParts.major != requiredParts.major {
            return currentParts.major > requiredParts.major
        }
        if currentParts.minor != requiredParts.minor {
            return currentParts.minor > requiredParts.minor
        }
        return currentParts.patch >= requiredParts.patch
    }

    /// Check if `candidate` is strictly newer than `current`.
    static func isNewer(candidate: String, than current: String) -> Bool {
        guard let a = parse(candidate), let b = parse(current) else { return false }
        if a.major != b.major { return a.major > b.major }
        if a.minor != b.minor { return a.minor > b.minor }
        return a.patch > b.patch
    }

    /// Parse a version string into (major, minor, patch) components.
    /// Strips pre-release suffixes (e.g., "2.1.0-alpha" → 2.1.0).
    /// Returns nil if the string does not contain at least three numeric components.
    static func parse(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        // Strip pre-release suffix: "2.1.0-alpha" → "2.1.0"
        let base = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = base.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        return (major: parts[0], minor: parts[1], patch: parts[2])
    }
}
