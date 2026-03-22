import Foundation

/// Checks for available updates to tech packs (via `git ls-remote`)
/// and the mcs CLI itself (via `git ls-remote --tags` on the mcs repo).
///
/// All network operations fail silently — offline or unreachable
/// remotes produce no output, matching the design goal of non-intrusive checks.
struct UpdateChecker {
    let environment: Environment
    let shell: ShellRunner

    /// Default cooldown interval: 7 days.
    static let cooldownInterval: TimeInterval = 604_800

    // MARK: - SessionStart Hook (single source of truth)

    static let hookCommand = "mcs check-updates --hook"
    static let hookTimeout: Int = 30
    static let hookStatusMessage = "Checking for updates..."

    @discardableResult
    static func addHook(to settings: inout Settings) -> Bool {
        settings.addHookEntry(
            event: Constants.HookEvent.sessionStart.rawValue,
            command: hookCommand,
            timeout: hookTimeout,
            statusMessage: hookStatusMessage
        )
    }

    @discardableResult
    static func removeHook(from settings: inout Settings) -> Bool {
        settings.removeHookEntry(event: Constants.HookEvent.sessionStart.rawValue, command: hookCommand)
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

    /// Run an update check and print results. Used by sync and doctor (user-invoked, no cooldown).
    static func checkAndPrint(env: Environment, shell: ShellRunner, output: CLIOutput) {
        let packRegistry = PackRegistryFile(path: env.packsRegistry)
        let allEntries = (try? packRegistry.load().packs) ?? []
        let relevantEntries = filterEntries(allEntries, environment: env)
        let checker = UpdateChecker(environment: env, shell: shell)
        let result = checker.performCheck(
            entries: relevantEntries,
            checkPacks: true,
            checkCLI: true
        )
        if !result.isEmpty {
            output.plain("")
            printHumanReadable(result, output: output)
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
    }

    // MARK: - Cache

    /// Load the cached check result. Returns nil if missing, corrupt, or CLI version changed.
    func loadCache() -> CachedResult? {
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
        return cached
    }

    /// Save check results to the cache file.
    func saveCache(_ result: CheckResult) {
        let cached = CachedResult(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            result: result
        )
        let dir = environment.updateCheckCacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cached) else { return }
        try? data.write(to: environment.updateCheckCacheFile, options: .atomic)
    }

    /// Delete the cache file (e.g., after `mcs pack update`).
    static func invalidateCache(environment: Environment) {
        try? FileManager.default.removeItem(at: environment.updateCheckCacheFile)
    }

    /// Returns `true` if the cache is stale or missing.
    func isCacheStale(cooldownInterval: TimeInterval = UpdateChecker.cooldownInterval) -> Bool {
        guard let cached = loadCache(),
              let lastCheck = ISO8601DateFormatter().date(from: cached.timestamp)
        else {
            return true
        }
        return Date().timeIntervalSince(lastCheck) >= cooldownInterval
    }

    // MARK: - Pack Checks

    /// Check each git pack for remote updates via `git ls-remote`.
    /// Local packs are skipped. Network failures are silently ignored per-pack.
    func checkPackUpdates(entries: [PackRegistryFile.PackEntry]) -> [PackUpdate] {
        var updates: [PackUpdate] = []

        for entry in entries {
            if entry.isLocalPack { continue }

            let ref = entry.ref ?? "HEAD"
            let result = shell.run(
                environment.gitPath,
                arguments: ["ls-remote", entry.sourceURL, ref]
            )

            guard result.succeeded,
                  let remoteSHA = Self.parseRemoteSHA(from: result.stdout)
            else {
                continue
            }

            if remoteSHA != entry.commitSHA {
                updates.append(PackUpdate(
                    identifier: entry.identifier,
                    displayName: entry.displayName,
                    localSHA: entry.commitSHA,
                    remoteSHA: remoteSHA
                ))
            }
        }

        return updates
    }

    // MARK: - CLI Version Check

    /// Check if a newer mcs version is available via `git ls-remote --tags`.
    /// Returns nil if the repo is unreachable or no newer version exists.
    func checkCLIVersion(currentVersion: String) -> CLIUpdate? {
        let result = shell.run(
            environment.gitPath,
            arguments: ["ls-remote", "--tags", "--refs", Constants.MCSRepo.url]
        )

        guard result.succeeded,
              let latestTag = Self.parseLatestTag(from: result.stdout)
        else {
            return nil
        }

        guard Self.isNewer(candidate: latestTag, than: currentVersion) else {
            return nil
        }

        return CLIUpdate(currentVersion: currentVersion, latestVersion: latestTag)
    }

    // MARK: - Combined Check

    /// Run all enabled checks.
    /// - `isHook: true` — SessionStart hook: returns cached results if fresh, otherwise checks + caches
    /// - `isHook: false` (default) — user-invoked: always does network checks + updates cache
    func performCheck(
        entries: [PackRegistryFile.PackEntry],
        isHook: Bool = false,
        checkPacks: Bool,
        checkCLI: Bool
    ) -> CheckResult {
        // Hook mode: return cached results if still fresh
        if isHook, !isCacheStale() {
            return loadCache()?.result ?? CheckResult(packUpdates: [], cliUpdate: nil)
        }

        let packUpdates = checkPacks ? checkPackUpdates(entries: entries) : []
        let cliUpdate = checkCLI ? checkCLIVersion(currentVersion: MCSVersion.current) : nil
        let result = CheckResult(packUpdates: packUpdates, cliUpdate: cliUpdate)

        // Always save to cache so the hook can serve fresh data between network checks
        saveCache(result)

        return result
    }

    // MARK: - Output Formatting

    /// Print update notices. Returns true if anything was printed.
    /// In hook mode, outputs structured JSON with `additionalContext` for Claude Code.
    /// In user mode, outputs colored terminal text.
    @discardableResult
    static func printHumanReadable(_ result: CheckResult, output: CLIOutput, isHook: Bool = false) -> Bool {
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
            if let data = try? JSONSerialization.data(withJSONObject: hookOutput, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
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
                let noun = result.packUpdates.count == 1 ? "pack has" : "packs have"
                output.info("\(result.packUpdates.count) \(noun) updates available. Run 'mcs pack update' to update.")
            }
        }

        return true
    }

    /// Build a plain-text context string for Claude from check results.
    private static func buildContextString(_ result: CheckResult) -> String {
        var lines: [String] = []
        lines.append("[mcs] IMPORTANT: Updates are available. Notify the user about these updates before proceeding with their request:")
        if let cli = result.cliUpdate {
            lines.append(
                "- mcs \(cli.latestVersion) available (current: \(cli.currentVersion)). "
                    + "Run 'brew upgrade \(Constants.MCSRepo.brewFormula)' to update."
            )
        }
        if !result.packUpdates.isEmpty {
            let noun = result.packUpdates.count == 1 ? "pack has" : "packs have"
            lines.append("- \(result.packUpdates.count) \(noun) updates available. Run 'mcs pack update' to update.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pack Filtering

    /// Resolve which pack IDs are relevant for update checks in the current context.
    /// Always includes globally-configured packs. If a project root is detected,
    /// also includes packs configured for that project.
    static func relevantPackIDs(environment: Environment) -> Set<String> {
        var ids = Set<String>()

        // Global packs
        if let globalState = try? ProjectState(stateFile: environment.globalStateFile) {
            ids.formUnion(globalState.configuredPacks)
        }

        // Project packs (detect from CWD)
        if let projectRoot = ProjectDetector.findProjectRoot(),
           let projectState = try? ProjectState(projectRoot: projectRoot) {
            ids.formUnion(projectState.configuredPacks)
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

    /// Extract the SHA from the first line of `git ls-remote` output.
    /// Format: `<sha>\t<ref>\n`
    static func parseRemoteSHA(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let sha = firstLine.split(separator: "\t", maxSplits: 1).first.map(String.init)
        guard let sha, !sha.isEmpty else { return nil }
        return sha
    }

    /// Find the latest CalVer tag from `git ls-remote --tags --refs` output.
    /// Each line: `<sha>\trefs/tags/<tag>\n`
    static func parseLatestTag(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var best: (major: Int, minor: Int, patch: Int)?
        var bestTag: String?

        for line in trimmed.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let refPath = String(parts[1])

            let prefix = "refs/tags/"
            guard refPath.hasPrefix(prefix) else { continue }
            let tag = String(refPath.dropFirst(prefix.count))

            guard let parsed = VersionCompare.parse(tag) else { continue }

            if let current = best {
                if parsed.major > current.major
                    || (parsed.major == current.major && parsed.minor > current.minor)
                    || (parsed.major == current.major && parsed.minor == current.minor && parsed.patch > current.patch) {
                    best = parsed
                    bestTag = tag
                }
            } else {
                best = parsed
                bestTag = tag
            }
        }

        return bestTag
    }

    /// Check if `candidate` version is strictly newer than `current`.
    static func isNewer(candidate: String, than current: String) -> Bool {
        guard let candidateParts = VersionCompare.parse(candidate),
              let currentParts = VersionCompare.parse(current)
        else {
            return false
        }

        if candidateParts.major != currentParts.major {
            return candidateParts.major > currentParts.major
        }
        if candidateParts.minor != currentParts.minor {
            return candidateParts.minor > currentParts.minor
        }
        return candidateParts.patch > currentParts.patch
    }
}
