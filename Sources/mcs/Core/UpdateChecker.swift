import Foundation

/// Checks for available updates to tech packs (via `git ls-remote`)
/// and the mcs CLI itself (via `git ls-remote --tags` on the mcs repo).
///
/// All network operations fail silently — offline or unreachable
/// remotes produce no output, matching the design goal of non-intrusive checks.
struct UpdateChecker {
    let environment: Environment
    let shell: any ShellRunning

    /// Default cooldown interval: 24 hours.
    static let cooldownInterval: TimeInterval = 86400

    /// Environment variables to suppress credential prompts during read-only git checks.
    /// GIT_TERMINAL_PROMPT=0 prevents terminal-based prompts; GIT_ASKPASS="" disables GUI credential helpers.
    private static let gitNoPromptEnv: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "",
    ]

    // MARK: - SessionStart Hook (single source of truth)

    static let hookCommand = "mcs check-updates --hook"
    static let hookTimeout: Int = 30
    static let hookStatusMessage = "Checking for updates..."

    @discardableResult
    static func addHook(to settings: inout Settings) -> Bool {
        settings.addHookEntry(
            event: Constants.HookEvent.sessionStart,
            command: hookCommand,
            timeout: hookTimeout,
            statusMessage: hookStatusMessage
        )
    }

    @discardableResult
    static func removeHook(from settings: inout Settings) -> Bool {
        settings.removeHookEntry(event: Constants.HookEvent.sessionStart, command: hookCommand)
    }

    /// Ensure the SessionStart hook in `~/.claude/settings.json` matches the config.
    static func syncHook(config: MCSConfig, env: Environment, output: CLIOutput) {
        do {
            var settings = try Settings.load(from: env.claudeSettings)
            if config.isUpdateCheckEnabled {
                if addHook(to: &settings) {
                    try settings.save(to: env.claudeSettings)
                }
            } else {
                if removeHook(from: &settings) {
                    try settings.save(to: env.claudeSettings)
                }
            }
        } catch {
            output.warn("Could not update hook in settings: \(error.localizedDescription)")
        }
    }

    /// Run an update check and print results. Used by sync and doctor.
    /// Respects the 24-hour cache cooldown — only does network checks when cache is stale.
    static func checkAndPrint(env: Environment, shell: ShellRunner, output: CLIOutput) {
        let packRegistry = PackRegistryFile(path: env.packsRegistry)
        let allEntries: [PackRegistryFile.PackEntry]
        do {
            allEntries = try packRegistry.load().packs
        } catch {
            output.warn("Could not load pack registry: \(error.localizedDescription)")
            allEntries = []
        }
        let relevantEntries = filterEntries(allEntries, environment: env)
        let checker = UpdateChecker(environment: env, shell: shell)
        let result = checker.performCheck(
            entries: relevantEntries,
            checkPacks: true,
            checkCLI: true
        )
        if !result.isEmpty {
            output.plain("")
            printResult(result, output: output)
        }
    }

    // MARK: - Result Types

    struct PackUpdate: Codable {
        let identifier: String
        let displayName: String
        let localSHA: String
        let remoteSHA: String
    }

    struct CLIUpdate: Codable {
        let currentVersion: String
        let latestVersion: String
    }

    struct CheckResult: Codable {
        let packUpdates: [PackUpdate]
        let cliUpdate: CLIUpdate?

        var isEmpty: Bool {
            packUpdates.isEmpty && cliUpdate == nil
        }

        private enum CodingKeys: String, CodingKey {
            case packUpdates = "packs"
            case cliUpdate = "cli"
        }
    }

    /// On-disk cache: check results + timestamp in a single JSON file.
    struct CachedResult: Codable {
        let timestamp: String
        let result: CheckResult
        /// SHA-256 of each pack's sorted `ignore:` list. Optional so pre-ignore caches still
        /// decode. When present, `loadCache` invalidates if any pack's current hash differs —
        /// an author edit shouldn't leave stale suppression inside the 24h window.
        let perPackIgnoreHash: [String: String]?
    }

    // MARK: - Cache

    /// Load the cached check result. Returns nil if missing, corrupt, CLI version changed, or
    /// (when `currentIgnoreHashes` is provided) any pack's `ignore:` list changed since the cache
    /// was written.
    func loadCache(currentIgnoreHashes: [String: String]? = nil) -> CachedResult? {
        guard let data = try? Data(contentsOf: environment.updateCheckCacheFile),
              let cached = try? JSONDecoder().decode(CachedResult.self, from: data)
        else {
            return nil
        }
        // Invalidate if the CLI version changed (user upgraded mcs)
        if let cli = cached.result.cliUpdate,
           cli.currentVersion != MCSVersion.current {
            return nil
        }
        // Invalidate if any pack's `ignore:` list changed since the cache was written.
        // Dict equality covers both directions: value drift (entry edited) AND key drift
        // (pack added, removed, or its manifest just became unreadable so it dropped out
        // of the current set). Either way, stale suppression cannot survive into the next run.
        if let currentIgnoreHashes, (cached.perPackIgnoreHash ?? [:]) != currentIgnoreHashes {
            return nil
        }
        return cached
    }

    /// Save check results to the cache file.
    func saveCache(_ result: CheckResult, ignoreHashes: [String: String]? = nil) {
        let cached = CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: result,
            perPackIgnoreHash: ignoreHashes
        )
        do {
            let dir = environment.updateCheckCacheFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cached)
            try data.write(to: environment.updateCheckCacheFile, options: .atomic)
        } catch {
            // Cache write failure is non-fatal — next check will just redo network calls
        }
    }

    /// Delete the cache file (e.g., after `mcs pack update`).
    /// Returns true if deleted or already absent; false on permission error.
    /// Callers must decide how to react to `false` — silently discarding it re-introduces
    /// the "stale update banner" defect from issue #334.
    static func invalidateCache(environment: Environment) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: environment.updateCheckCacheFile.path) else { return true }
        do {
            try fm.removeItem(at: environment.updateCheckCacheFile)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Pack Checks

    /// Classification of an upstream commit-SHA change. Drives whether the noise filter
    /// suppresses the update notification.
    enum UpstreamChange: Equatable {
        case suppressed
        case material([String])
        case unknown(UnknownReason)

        /// Why a classification could not be made. Carries enough context for telemetry
        /// without requiring callers to inspect the orchestrator's call sites.
        enum UnknownReason: Equatable {
            case missingClone
            case fetchFailed
            case diffFailed
        }
    }

    /// Pure classifier for the changed-path list returned by `git diff --name-only`.
    /// No I/O — unit-testable in isolation. The orchestrator (`classifyUpstreamChange`)
    /// runs git and calls into this.
    ///
    /// Rules, applied in order:
    /// 1. If any path equals `techpack.yaml` → `.material` (supply-chain invariant —
    ///    manifest edits can swap hook scripts, MCP commands, install surface).
    /// 2. A path is "noise" if its leading segment matches `PackHeuristics.ignoredDirectories`
    ///    (e.g. `.github/workflows/ci.yml`) OR the path is a single segment that matches
    ///    `PackHeuristics.infrastructureFilesForUpdateCheck` (e.g. `README.md` at the pack
    ///    root, but not `hooks/README.md`).
    /// 3. When a manifest is provided, its `ignore:` entries also count as noise
    ///    Authors extend the built-in deny-list this way.
    /// 4. If all paths are noise → `.suppressed`. Any survivor → `.material(survivors)`.
    ///
    /// Empty input maps to `.suppressed`: `git diff --name-only` only produces empty output
    /// after a successful diff that found no changed paths, which is a "definitely no
    /// material change" signal — not an unknown one.
    static func classifyDiffPaths(
        _ paths: [String],
        manifest: ExternalPackManifest? = nil
    ) -> UpstreamChange {
        // `.whitespacesAndNewlines` (not `.whitespaces`) so a trailing `\r` from CRLF
        // output (git with `core.autocrlf=true`) gets stripped — otherwise `README.md\r`
        // would miss the deny-list and surface as material.
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return .suppressed }

        if cleaned.contains(Constants.ExternalPacks.manifestFilename) {
            return .material([Constants.ExternalPacks.manifestFilename])
        }

        var material: [String] = []
        for path in cleaned {
            if isNoisePath(path) { continue }
            if let manifest, PackHeuristics.isIgnoredByManifest(path, manifest: manifest) { continue }
            material.append(path)
        }
        return material.isEmpty ? .suppressed : .material(material)
    }

    private static func isNoisePath(_ path: String) -> Bool {
        let leadingSegment = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        if PackHeuristics.ignoredDirectories.contains(leadingSegment) {
            return true
        }
        // Basename match only when the path is a single segment — a file called `README.md`
        // inside `hooks/` (i.e. `hooks/README.md`) is not suppressed; only pack-root infra is.
        if !path.contains("/"), PackHeuristics.infrastructureFilesForUpdateCheck.contains(path) {
            return true
        }
        return false
    }

    /// Orchestrator — runs `git fetch` + `git diff --name-only` in the pack clone and feeds
    /// the diff into `classifyDiffPaths`.
    ///
    /// **Never-hide invariant (orchestrator scope):** within this function, every operational
    /// failure (missing clone, fetch failure, diff failure) returns `.unknown(reason)` so the
    /// caller can surface the notification unfiltered. `.suppressed` is reserved for diffs
    /// successfully classified as all-noise. The earlier `git ls-remote` and SHA-parsing path
    /// in `checkPackUpdates` is a separate guard — when we can't determine whether there is an
    /// upstream change at all, the closure exits without producing an outcome (consistent with
    /// the file-level "Network failures are silently ignored" design goal).
    ///
    /// Mirrors `PackFetcher.update` for the fetch shape: when `entry.ref == nil`, fetch without
    /// a ref arg and diff against `origin/HEAD` (more reliable across git servers than passing
    /// `HEAD` as a positional ref). When `entry.ref` is set, fetch that ref explicitly and diff
    /// against `FETCH_HEAD`.
    ///
    /// - Parameter manifest: when non-nil, the manifest's `ignore:` list extends the built-in
    ///   deny-list. Callers pre-load manifests once per pack so the parallel `concurrentPerform`
    ///   loop doesn't re-parse YAML per iteration.
    func classifyUpstreamChange(
        entry: PackRegistryFile.PackEntry,
        manifest: ExternalPackManifest? = nil
    ) -> UpstreamChange {
        // `resolvedPath` only validates the path shape; it doesn't stat the filesystem. If the
        // clone was deleted out from under us (e.g. user `rm -rf`'d `~/.mcs/packs/foo`), classify
        // as `.missingClone` instead of letting git fail with a bogus cwd — same outcome at the
        // call site (notification surfaces) but accurate telemetry and one fewer subprocess.
        guard let workDirURL = entry.resolvedPath(packsDirectory: environment.packsDirectory),
              FileManager.default.fileExists(atPath: workDirURL.path)
        else {
            return .unknown(.missingClone)
        }
        let workDir = workDirURL.path

        let fetchArgs: [String]
        let diffTarget: String
        if let ref = entry.ref {
            // Refs are read from `registry.yaml`; if user-edited or corrupted, a ref starting
            // with `-` would be interpreted as a git option (argument injection). Validate
            // before invoking git; treat invalid refs as a fetch failure so the never-hide
            // invariant still surfaces a notification.
            guard isValidGitRef(ref) else { return .unknown(.fetchFailed) }
            fetchArgs = ["fetch", "--depth", "1", "origin", ref]
            diffTarget = "FETCH_HEAD"
        } else {
            fetchArgs = ["fetch", "--depth", "1", "origin"]
            diffTarget = "origin/HEAD"
        }

        let fetchResult = shell.run(
            environment.gitPath,
            arguments: fetchArgs,
            workingDirectory: workDir,
            additionalEnvironment: Self.gitNoPromptEnv
        )
        guard fetchResult.succeeded else { return .unknown(.fetchFailed) }

        let diffResult = shell.run(
            environment.gitPath,
            arguments: ["diff", "--name-only", "HEAD", diffTarget],
            workingDirectory: workDir,
            additionalEnvironment: Self.gitNoPromptEnv
        )
        guard diffResult.succeeded else { return .unknown(.diffFailed) }

        let paths = diffResult.stdout.split(separator: "\n").map(String.init)
        return Self.classifyDiffPaths(paths, manifest: manifest)
    }

    /// Per-iteration result of `checkPackUpdates`. Sum type — exactly one of:
    /// surface a notification, OR advance the registry baseline. The unreachable
    /// "both" state in the prior optional-pair encoding would have produced a
    /// stuck-update bug (notify + silently advance), so the type rules it out.
    private enum PackCheckOutcome {
        case emit(PackUpdate)
        case advance(identifier: String, newSHA: String)
    }

    /// Check each git pack for remote updates via `git ls-remote`.
    /// Local packs are skipped. Checks run in parallel. Network failures are silently ignored per-pack.
    ///
    /// When a remote SHA differs, runs the noise filter (`classifyUpstreamChange`) which may
    /// suppress the notification for README/CI/infra-only commits and advance the registry
    /// baseline so the same commits don't re-trigger.
    func checkPackUpdates(
        entries: [PackRegistryFile.PackEntry],
        manifests: [String: ExternalPackManifest] = [:]
    ) -> [PackUpdate] {
        let gitEntries = entries.filter { !$0.isLocalPack }
        guard !gitEntries.isEmpty else { return [] }

        // Each index is written by exactly one iteration. We write through a raw buffer pointer
        // rather than the `Array` subscript so the parallel writes touch only distinct element
        // addresses — no Array COW header / refcount machinery in the hot path. The `nonisolated(unsafe)`
        // capture is still needed because `UnsafeMutableBufferPointer` is not Sendable.
        var results = [PackCheckOutcome?](repeating: nil, count: gitEntries.count)
        results.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let buf = buffer
            DispatchQueue.concurrentPerform(iterations: gitEntries.count) { index in
                let entry = gitEntries[index]
                // Refs are user-controllable via `mcs pack add --ref` and persisted in `registry.yaml`;
                // a corrupted ref starting with `-` would be interpreted as a git option (argument
                // injection). Skip the pack — registry corruption is permanent (unlike a transient
                // ls-remote failure), so emit to MCS_DEBUG so the silent skip is at least visible
                // during development. Production hooks stay quiet per the "non-intrusive" design.
                if let ref = entry.ref, !isValidGitRef(ref) {
                    if Environment.isDebugMode {
                        let message = "mcs: skipping update check for '\(entry.identifier)': invalid ref '\(ref)'\n"
                        FileHandle.standardError.write(Data(message.utf8))
                    }
                    return
                }
                let lsRemote = shell.run(
                    environment.gitPath,
                    arguments: ["ls-remote", entry.sourceURL, entry.ref ?? "HEAD"],
                    additionalEnvironment: Self.gitNoPromptEnv
                )

                guard lsRemote.succeeded,
                      let remoteSHA = Self.parseRemoteSHA(from: lsRemote.stdout),
                      remoteSHA != entry.commitSHA
                else {
                    return
                }

                let pendingUpdate = PackUpdate(
                    identifier: entry.identifier,
                    displayName: entry.displayName,
                    localSHA: entry.commitSHA,
                    remoteSHA: remoteSHA
                )

                switch classifyUpstreamChange(entry: entry, manifest: manifests[entry.identifier]) {
                case .suppressed:
                    buf[index] = .advance(identifier: entry.identifier, newSHA: remoteSHA)
                case .material, .unknown:
                    buf[index] = .emit(pendingUpdate)
                }
            }
        }

        var updates: [PackUpdate] = []
        var advances: [(identifier: String, newSHA: String)] = []
        for outcome in results {
            switch outcome {
            case nil: continue
            case let .emit(update): updates.append(update)
            case let .advance(identifier, newSHA): advances.append((identifier, newSHA))
            }
        }
        if !advances.isEmpty {
            applyRegistryAdvances(advances)
        }
        return updates
    }

    /// Best-effort manifest read for the noise filter's `ignore:` lookup. Falls back to nil
    /// (built-in deny-list only) if the manifest is unreadable. The semantic of "no manifest →
    /// no author ignore list" is correct — we never want a manifest read error to surface a
    /// notification that should be suppressed (the never-hide invariant covers fetch/diff
    /// errors, not manifest-read errors, which default to safe).
    ///
    /// Forbidden `ignore:` entries (matching `techpack.yaml` or any referenced path) are
    /// stripped silently here. The same stripping happens loudly at sync-time via
    /// `sanitizedIgnoreEntries(output:)`; this is the hook-path equivalent — we can't warn
    /// the user from a SessionStart hook, but we still must not let a malformed local
    /// manifest suppress notifications about load-bearing files.
    private func loadManifestForIgnoreCheck(
        entry: PackRegistryFile.PackEntry
    ) -> ExternalPackManifest? {
        guard let packPath = entry.resolvedPath(packsDirectory: environment.packsDirectory) else {
            return nil
        }
        let manifestURL = packPath.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        do {
            let raw = try ExternalPackManifest.load(from: manifestURL)
            let normalized = try raw.normalized()
            return normalized.silentlySanitizedIgnoreEntries()
        } catch {
            if Environment.isDebugMode {
                let message = "mcs: ignore-check manifest unreadable for '\(entry.identifier)': \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            return nil
        }
    }

    /// SHA-256 of a manifest's sorted, joined `ignore:` entries. Used as a cache invalidation
    /// key so an author edit to `ignore:` doesn't leave stale suppression in the 24h window.
    static func ignoreHash(manifest: ExternalPackManifest) -> String {
        let sorted = (manifest.ignore ?? []).sorted().joined(separator: "\n")
        return FileHasher.sha256(data: Data(sorted.utf8))
    }

    /// Pre-load manifests for the noise filter — once per `performCheck` call. Both the
    /// cache-invalidation hash and the per-pack classifier need the manifest, so loading
    /// here avoids a second YAML parse per pack.
    func loadManifestsForIgnoreCheck(
        entries: [PackRegistryFile.PackEntry]
    ) -> [String: ExternalPackManifest] {
        entries.reduce(into: [:]) { dict, entry in
            guard !entry.isLocalPack else { return }
            dict[entry.identifier] = loadManifestForIgnoreCheck(entry: entry)
        }
    }

    /// Map pre-loaded manifests to their `ignore:` hashes for cache invalidation.
    static func ignoreHashes(manifests: [String: ExternalPackManifest]) -> [String: String] {
        manifests.mapValues { ignoreHash(manifest: $0) }
    }

    /// Apply collected SHA advances to `registry.yaml` in one load→mutate→save round-trip.
    /// Serializes the writes that were collected from the parallel `concurrentPerform` loop.
    ///
    /// Acquires `~/.mcs/lock` non-blocking before the load→mutate→save. `CheckUpdatesCommand`
    /// runs as a SessionStart hook and is not itself a `LockedCommand`; without the lock, a
    /// concurrent `mcs pack add/update` (which is locked) could read the registry between our
    /// load and save and have its write clobbered. On lock contention we skip silently — the
    /// next check re-classifies and retries.
    ///
    /// All other failures are non-fatal too: the registry stays at the old commit SHA, so the
    /// next check re-runs the classifier and either suppresses again (re-attempting the write)
    /// or surfaces the notification. We avoid `output.warn` here because this runs inside the
    /// SessionStart hook path where the "non-intrusive checks" design goal precludes user-facing
    /// noise; failures emit to stderr only when `MCS_DEBUG` is set.
    private func applyRegistryAdvances(_ advances: [(identifier: String, newSHA: String)]) {
        do {
            try withFileLock(at: environment.lockFile) {
                let registry = PackRegistryFile(path: environment.packsRegistry)
                var data = try registry.load()
                for advance in advances {
                    guard let existing = registry.pack(identifier: advance.identifier, in: data) else { continue }
                    registry.register(existing.withCommitSHA(advance.newSHA), in: &data)
                }
                try registry.save(data)
            }
        } catch {
            if Environment.isDebugMode {
                let message = "mcs: registry advance write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    // MARK: - CLI Version Check

    /// Check if a newer mcs version is available via `git ls-remote --tags`.
    /// Returns nil if the repo is unreachable or no newer version exists.
    func checkCLIVersion(currentVersion: String) -> CLIUpdate? {
        let result = shell.run(
            environment.gitPath,
            arguments: ["ls-remote", "--tags", "--refs", Constants.MCSRepo.url],
            additionalEnvironment: Self.gitNoPromptEnv
        )

        guard result.succeeded,
              let latestTag = Self.parseLatestTag(from: result.stdout)
        else {
            return nil
        }

        guard VersionCompare.isNewer(candidate: latestTag, than: currentVersion) else {
            return nil
        }

        return CLIUpdate(currentVersion: currentVersion, latestVersion: latestTag)
    }

    // MARK: - Combined Check

    /// Run all enabled checks.
    /// - `forceRefresh: false` (default) — returns cached results if fresh (within 24h), otherwise network + cache
    /// - `forceRefresh: true` — always does network checks + updates cache (for explicit `mcs check-updates`)
    func performCheck(
        entries: [PackRegistryFile.PackEntry],
        forceRefresh: Bool = false,
        checkPacks: Bool,
        checkCLI: Bool
    ) -> CheckResult {
        // Load manifests once per call. Both the cache-invalidation hash (`ignoreHashes`) and
        // the parallel classifier in `checkPackUpdates` need them; loading here avoids a second
        // YAML parse per pack on the SessionStart-hook hot path.
        let manifests = checkPacks ? loadManifestsForIgnoreCheck(entries: entries) : [:]
        let ignoreHashes = checkPacks ? Self.ignoreHashes(manifests: manifests) : [:]

        // Only feed the hash set into cache invalidation when we're actually checking packs.
        // With `checkPacks == false`, an empty `ignoreHashes` would force a miss against any
        // prior cache that recorded hashes — defeating the cooldown for the CLI-only check.
        let cacheInvalidationHashes: [String: String]? = checkPacks ? ignoreHashes : nil

        // Serve cached results if still fresh (single disk read), unless explicitly forced
        if !forceRefresh,
           let cached = loadCache(currentIgnoreHashes: cacheInvalidationHashes),
           let lastCheck = ISO8601DateFormatter().date(from: cached.timestamp),
           Date().timeIntervalSince(lastCheck) < Self.cooldownInterval {
            return cached.result
        }

        let packUpdates = checkPacks ? checkPackUpdates(entries: entries, manifests: manifests) : []
        let cliUpdate = checkCLI ? checkCLIVersion(currentVersion: MCSVersion.current) : nil
        let result = CheckResult(packUpdates: packUpdates, cliUpdate: cliUpdate)

        // Always save to cache so the hook can serve fresh data between network checks
        saveCache(result, ignoreHashes: ignoreHashes.isEmpty ? nil : ignoreHashes)

        return result
    }

    // MARK: - Output Formatting

    /// Print update notices. Returns true if anything was printed.
    /// In hook mode, outputs structured JSON with `additionalContext` for Claude Code.
    /// In user mode, outputs colored terminal text.
    @discardableResult
    static func printResult(_ result: CheckResult, output: CLIOutput, isHook: Bool = false) -> Bool {
        guard !result.isEmpty else { return false }

        if isHook {
            // Structured JSON for Claude Code SessionStart hook
            let context = buildContextString(result)
            let hookOutput: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": Constants.HookEvent.sessionStart.rawValue,
                    "additionalContext": context,
                ] as [String: String],
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: hookOutput, options: [.sortedKeys])
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } catch {
                // Fallback to plain text if JSON serialization fails
                print(context)
            }
        } else {
            // User-invoked: colored output for terminal readability
            if let cli = result.cliUpdate {
                output.warn(
                    "mcs \(cli.latestVersion) available (current: \(cli.currentVersion)). "
                        + "Run 'brew upgrade \(Constants.MCSRepo.brewFormula)' to update."
                )
            }
            if !result.packUpdates.isEmpty {
                let noun = result.packUpdates.count == 1 ? "pack update" : "pack updates"
                output.info("\(result.packUpdates.count) \(noun) available:")
                for pack in result.packUpdates {
                    let local = String(pack.localSHA.prefix(7))
                    let remote = String(pack.remoteSHA.prefix(7))
                    output.plain("         \u{2022} \(pack.displayName) (\(local) \u{2192} \(remote))")
                }
                output.plain(
                    "       Run 'mcs update --all-projects' to update and re-apply across every"
                        + " configured project plus the global scope."
                )
            }
        }

        return true
    }

    /// Build a context string for Claude from check results.
    /// Uses strong directive language to ensure Claude relays the notification visibly.
    private static func buildContextString(_ result: CheckResult) -> String {
        var lines: [String] = []
        lines.append(
            "STOP. Before doing ANY work, you MUST relay the following update notifications to the user."
                + " This is non-negotiable even if the user's message is a task request."
        )
        lines.append("")
        if let cli = result.cliUpdate {
            lines.append(
                "- New mcs version \(cli.latestVersion) is available (installed: \(cli.currentVersion))."
                    + " The user should run: brew upgrade \(Constants.MCSRepo.brewFormula)"
            )
        }
        if !result.packUpdates.isEmpty {
            let names = result.packUpdates.map(\.displayName).joined(separator: ", ")
            let noun = result.packUpdates.count == 1 ? "tech pack has" : "tech packs have"
            lines.append(
                "- \(result.packUpdates.count) \(noun) updates available: \(names)."
                    + " The user should run: mcs update --all-projects"
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pack Filtering

    /// Resolve which pack IDs are relevant for update checks in the current context.
    /// Always includes globally-configured packs. If a project root is detected,
    /// also includes packs configured for that project.
    static func relevantPackIDs(environment: Environment) -> Set<String> {
        var ids = Set<String>()

        // Global packs — only load if the state file exists
        let fm = FileManager.default
        if fm.fileExists(atPath: environment.globalStateFile.path) {
            do {
                let globalState = try ProjectState(stateFile: environment.globalStateFile)
                ids.formUnion(globalState.configuredPacks)
            } catch {
                // Corrupt state — fall through to check all packs (safe fallback)
            }
        }

        // Project packs (detect from CWD)
        if let projectRoot = ProjectDetector.findProjectRoot() {
            let statePath = projectRoot
                .appendingPathComponent(Constants.FileNames.claudeDirectory)
                .appendingPathComponent(Constants.FileNames.mcsProject)
            if fm.fileExists(atPath: statePath.path) {
                do {
                    let projectState = try ProjectState(projectRoot: projectRoot)
                    ids.formUnion(projectState.configuredPacks)
                } catch {
                    // Corrupt state — fall through to check all packs (safe fallback)
                }
            }
        }

        return ids
    }

    /// Filter registry entries to only those relevant in the current context.
    static func filterEntries(
        _ entries: [PackRegistryFile.PackEntry],
        environment: Environment
    ) -> [PackRegistryFile.PackEntry] {
        let ids = relevantPackIDs(environment: environment)
        guard !ids.isEmpty else { return entries } // No state files → check all (first run)
        return entries.filter { ids.contains($0.identifier) }
    }

    // MARK: - Parsing Helpers

    /// Extract the commit SHA from `git ls-remote` output. Format: `<sha>\t<ref>\n`.
    ///
    /// For annotated tags, ls-remote returns the tag-object SHA on the first line and the
    /// peeled commit SHA on a second line whose ref ends with `^{}`. Prefer the peeled line
    /// when present so the returned SHA matches what the working tree's `rev-parse HEAD`
    /// would resolve to — writing a tag-object SHA into `registry.yaml` desyncs the registry
    /// from the checkout and trips PackUpdater's "disk ahead of registry" recovery path.
    static func parseRemoteSHA(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var firstSHA: String?
        for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sha = String(parts[0])
            let ref = parts[1]
            guard !sha.isEmpty else { continue }
            if ref.hasSuffix("^{}") {
                return sha
            }
            if firstSHA == nil {
                firstSHA = sha
            }
        }

        // Fallback for malformed single-line output that has no tab — preserve historical behavior.
        if firstSHA == nil {
            let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
            let sha = firstLine.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            return sha.isEmpty ? nil : sha
        }
        return firstSHA
    }

    /// Find the latest CalVer tag from `git ls-remote --tags --refs` output.
    /// Each line: `<sha>\trefs/tags/<tag>\n`
    static func parseLatestTag(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var bestTag: String?

        for line in trimmed.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let refPath = String(parts[1])

            let prefix = "refs/tags/"
            guard refPath.hasPrefix(prefix) else { continue }
            let tag = String(refPath.dropFirst(prefix.count))

            guard VersionCompare.parse(tag) != nil else { continue }

            if let current = bestTag {
                if VersionCompare.isNewer(candidate: tag, than: current) {
                    bestTag = tag
                }
            } else {
                bestTag = tag
            }
        }

        return bestTag
    }
}
