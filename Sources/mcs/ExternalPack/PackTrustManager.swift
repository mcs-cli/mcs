import Foundation

/// Manages the trust lifecycle for external packs — analyzing executable content,
/// prompting for user approval, and verifying script integrity before execution.
struct PackTrustManager {
    let output: CLIOutput

    // MARK: - Analyze

    /// Collect all executable content from a pack that needs trust approval.
    /// Returns items representing shell commands, scripts, and MCP server commands
    /// that will run with user privileges.
    func analyzeScripts(manifest: ExternalPackManifest, packPath: URL) throws -> [TrustableItem] {
        var items: [TrustableItem] = []

        // Component install actions
        if let components = manifest.components {
            for component in components {
                switch component.installAction {
                case let .shellCommand(command, _):
                    items.append(TrustableItem(
                        type: .shellCommand,
                        relativePath: nil,
                        content: command,
                        description: "\(component.displayName) — runs during install"
                    ))

                case let .mcpServer(config):
                    let serverDesc: String
                    if config.transport == .http, let url = config.url {
                        serverDesc = "\(config.name): \(url) (HTTP)"
                    } else {
                        let cmd = ([config.command ?? ""] + (config.args ?? [])).joined(separator: " ")
                        serverDesc = "\(config.name): \(cmd)"
                    }
                    items.append(TrustableItem(
                        type: .mcpServerCommand,
                        relativePath: nil,
                        content: serverDesc,
                        description: "MCP server — runs on every Claude Code session"
                    ))

                case let .copyPackFile(config):
                    // Hook and command files are executed by Claude Code — require trust review
                    let fileType = config.fileType ?? .generic
                    if fileType == .hook || fileType == .command {
                        let scriptFile = packPath.appendingPathComponent(config.source)
                        let content = try readFileContent(at: scriptFile, fallback: config.source)
                        items.append(TrustableItem(
                            type: fileType == .hook ? .hookFragment : .commandFile,
                            relativePath: config.source,
                            content: content,
                            description: "\(component.displayName) — \(fileType.rawValue) file installed during configure"
                        ))
                    }
                    // The interpreter decides what actually executes, and it lives in the manifest
                    // rather than in the script — so trusting the file's hash alone would let a
                    // pack update swap `node` for `sh -c` without any renewed review. Tracked as an
                    // inline item so its content, not the script's, drives change detection.
                    //
                    // Emitted for every registered hook, including plain bash ones, so that
                    // *losing* an interpreter is detectable too: an item that simply disappears
                    // would leave the old hash in place and let a script trusted as JS start
                    // running as shell unreviewed. First-time trust of a default invocation is
                    // waived in `detectNewScripts`, which is what keeps legacy packs quiet.
                    if let invocation = component.hookInvocation {
                        items.append(TrustableItem(
                            type: .hookInterpreter,
                            relativePath: nil,
                            content: "\(invocation.interpreter) \(invocation.destination)",
                            // Keyed indirectly by description, so it must be unique per component:
                            // two hooks sharing a display name would otherwise overwrite each
                            // other's hash and compare against the wrong hook.
                            description: "\(component.id) — command its hook is invoked with",
                            representsDefaultBehavior: HookInterpreter.isDefault(invocation.interpreter)
                        ))
                    }

                default:
                    break
                }

                // Doctor check scripts within components
                if let checks = component.doctorChecks {
                    for check in checks {
                        items += try trustableItems(from: check, packPath: packPath)
                    }
                }
            }
        }

        // Configure project script
        if let configure = manifest.configureProject {
            let scriptFile = packPath.appendingPathComponent(configure.script)
            let content = try readFileContent(at: scriptFile, fallback: configure.script)
            items.append(TrustableItem(
                type: .configureScript,
                relativePath: configure.script,
                content: content,
                description: "Runs during project configuration"
            ))
        }

        // Supplementary doctor checks at the pack level
        if let checks = manifest.supplementaryDoctorChecks {
            for check in checks {
                items += try trustableItems(from: check, packPath: packPath)
            }
        }

        // Prompt script commands
        if let prompts = manifest.prompts {
            for prompt in prompts where prompt.type == .script {
                if let scriptCommand = prompt.scriptCommand {
                    items.append(TrustableItem(
                        type: .shellCommand,
                        relativePath: nil,
                        content: scriptCommand,
                        description: "Prompt script for '\(prompt.key)' — runs during configure"
                    ))
                }
            }
        }

        return items
    }

    // MARK: - Prompt

    /// Display all trustable items and prompt the user for approval.
    /// A pack with no executable content is trusted implicitly.
    ///
    /// Callers that need the approved hashes compute them from the same items via
    /// `computeScriptHashes` — returning them here produced a map the update path discarded.
    func promptForTrust(
        manifest: ExternalPackManifest,
        packPath _: URL,
        items: [TrustableItem]
    ) -> Bool {
        if items.isEmpty {
            return true
        }

        output.plain("")
        output.header("Pack '\(manifest.displayName)' requests these permissions:")

        // Group items by type for display
        let shellCommands = items.filter { $0.type == .shellCommand && $0.relativePath == nil }
        let mcpServers = items.filter { $0.type == .mcpServerCommand }
        let hookFragments = items.filter { $0.type == .hookFragment }
        let doctorCommands = items.filter { $0.type == .doctorCommand || $0.type == .fixScript }
        let scripts = items.filter { $0.relativePath != nil && $0.type != .hookFragment && $0.type != .commandFile }

        if !shellCommands.isEmpty {
            output.plain("")
            output.sectionHeader("Shell Commands (run during install)")
            for item in shellCommands {
                output.plain("    \(item.content)")
            }
        }

        if !mcpServers.isEmpty {
            output.plain("")
            output.sectionHeader("MCP Servers (run on every Claude Code session)")
            for item in mcpServers {
                output.plain("    \(item.content)")
            }
        }

        if !hookFragments.isEmpty {
            output.plain("")
            output.sectionHeader("Hook Files (run on every session)")
            for item in hookFragments {
                let lineCount = item.content.components(separatedBy: "\n").count
                let path = item.relativePath ?? "inline"
                output.plain("    \(path) (\(lineCount) lines) — \(item.description)")
            }
        }

        let hookInterpreters = items.filter { $0.type == .hookInterpreter }
        if !hookInterpreters.isEmpty {
            output.plain("")
            output.sectionHeader("Hook Interpreters (run on every session)")
            for item in hookInterpreters {
                output.plain("    \(item.content)")
            }
        }

        if !doctorCommands.isEmpty {
            output.plain("")
            output.sectionHeader("Doctor Check/Fix Commands (run during 'mcs doctor')")
            for item in doctorCommands {
                output.plain("    \(item.content)")
            }
        }

        let commandFiles = items.filter { $0.type == .commandFile }
        if !commandFiles.isEmpty {
            output.plain("")
            output.sectionHeader("Command Files (invoked by Claude)")
            for item in commandFiles {
                let lineCount = item.content.components(separatedBy: "\n").count
                let path = item.relativePath ?? "inline"
                output.plain("    \(path) (\(lineCount) lines) — \(item.description)")
            }
        }

        if !scripts.isEmpty {
            output.plain("")
            output.sectionHeader("Scripts")
            for item in scripts {
                let lineCount = item.content.components(separatedBy: "\n").count
                let path = item.relativePath ?? "inline"
                output.plain("    \(path) (\(lineCount) lines) — \(item.description)")
            }
        }

        output.plain("")
        return output.askYesNo("Trust this pack?", default: false)
    }

    // MARK: - Verify

    /// Why a trustable item fails to match the approved set, or `nil` when it verifies.
    enum TrustMismatch: Equatable {
        case neverTrusted // No stored hash for this item
        case mismatched // Content disagrees with the stored hash, or the file is gone
        case unreadable(String) // Present, but could not be hashed
    }

    /// Scripts the pack will execute that the user has not approved, keyed by pack-relative path.
    ///
    /// Walks forward from the manifest's analyzed items, never over the stored hash keys: a key
    /// left behind for a file the pack no longer references says nothing about what will execute,
    /// and a referenced script with *no* stored hash must not go unchecked.
    ///
    /// Inline items are exempt as a **bounded migration**, not because they are safe: a trust map
    /// written before inline hashing has no synthetic keys, so enforcing them would refuse every
    /// such pack at load. The first `mcs pack update` writes a complete map, after which they
    /// could be enforced. Until then an inline `shell:` edited in the local checkout is not caught
    /// here.
    func verifyTrust(
        trustedHashes: [String: String],
        packPath: URL,
        manifest: ExternalPackManifest
    ) throws -> [String: TrustMismatch] {
        var offenders: [String: TrustMismatch] = [:]

        for item in try analyzeScripts(manifest: manifest, packPath: packPath) {
            guard let relativePath = item.relativePath else {
                // A doctor `command`/`fixScript` is a path or an inline command, told apart only
                // by whether the file exists — so deleting a trusted script reclassifies it as
                // inline. Inline items are keyed `inline:<hash>`, so a stored hash under the value
                // itself means it was trusted as a file that is now gone.
                if trustedHashes[item.content] != nil {
                    offenders[item.content] = .mismatched
                }
                continue
            }
            guard let reason = mismatch(for: item, against: trustedHashes, packPath: packPath)
            else { continue }
            offenders[relativePath] = reason
        }

        return offenders
    }

    /// Filter analyzed items down to those needing user approval.
    func newOrChanged(
        in items: [TrustableItem],
        against currentHashes: [String: String],
        packPath: URL
    ) -> [TrustableItem] {
        items.filter { mismatch(for: $0, against: currentHashes, packPath: packPath) != nil }
    }

    /// The one comparison rule behind both load-time verification and update-time change detection.
    private func mismatch(
        for item: TrustableItem,
        against trustedHashes: [String: String],
        packPath: URL
    ) -> TrustMismatch? {
        guard let relativePath = item.relativePath else {
            guard let trustedHash = trustedHashes[Self.syntheticKey(for: item)] else {
                // Never trusted before. An item that merely restates the behaviour a pack already
                // had needs no prompt — that is how packs predating hook-interpreter tracking stay
                // quiet on their first update. Anything else is genuinely new.
                return item.representsDefaultBehavior ? nil : .neverTrusted
            }
            return trustedHash == Self.contentHash(of: item.content) ? nil : .mismatched
        }

        guard let trustedHash = trustedHashes[relativePath] else {
            return .neverTrusted
        }
        // A deleted file reads as `.mismatched` rather than `.unreadable`, so the message stays
        // about trust instead of quoting a "no such file" error.
        let fileURL = packPath.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .mismatched
        }
        do {
            return try FileHasher.sha256(of: fileURL) == trustedHash ? nil : .mismatched
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    /// Deterministic synthetic key for inline commands (not backed by a file).
    /// Uses SHA-256 of the description to ensure stability across process invocations.
    /// Note: Swift's `String.hashValue` is randomized per-process (SE-0206) and must not
    /// be used for persistent keys.
    private static func syntheticKey(for item: TrustableItem) -> String {
        "inline:\(contentHash(of: item.description))"
    }

    /// Hex-encoded SHA-256 of a string.
    private static func contentHash(of content: String) -> String {
        FileHasher.sha256(data: Data(content.utf8))
    }

    private func readFileContent(at url: URL, fallback: String) throws -> String {
        if FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return fallback
    }

    private func trustableItems(
        from check: ExternalDoctorCheckDefinition,
        packPath: URL
    ) throws -> [TrustableItem] {
        var items: [TrustableItem] = []

        // commandExists checks run arbitrary commands — surface them for trust review
        if check.type == .commandExists, let command = check.command {
            let fullCommand = ([command] + (check.args ?? [])).joined(separator: " ")
            items.append(TrustableItem(
                type: .doctorCommand,
                relativePath: nil,
                content: fullCommand,
                description: "Doctor check command: \(check.name) — runs during 'mcs doctor'"
            ))
        }

        if check.type == .shellScript, let command = check.command {
            // The command field may be a script file path or inline command
            let scriptFile = packPath.appendingPathComponent(command)
            if FileManager.default.fileExists(atPath: scriptFile.path) {
                let fileContent = try String(contentsOf: scriptFile, encoding: .utf8)
                items.append(TrustableItem(
                    type: .doctorScript,
                    relativePath: command,
                    content: fileContent,
                    description: "Doctor check script: \(check.name)"
                ))
            } else {
                // File doesn't exist — treat as inline command
                items.append(TrustableItem(
                    type: .doctorScript,
                    relativePath: nil,
                    content: command,
                    description: "Doctor check command: \(check.name)"
                ))
            }
        }

        if let fixCommand = check.fixCommand {
            items.append(TrustableItem(
                type: .fixScript,
                relativePath: nil,
                content: fixCommand,
                description: "Fix command for: \(check.name) — runs during 'mcs doctor --fix'"
            ))
        }

        if let fixScript = check.fixScript {
            let scriptFile = packPath.appendingPathComponent(fixScript)
            if FileManager.default.fileExists(atPath: scriptFile.path) {
                let fileContent = try String(contentsOf: scriptFile, encoding: .utf8)
                items.append(TrustableItem(
                    type: .fixScript,
                    relativePath: fixScript,
                    content: fileContent,
                    description: "Fix script for: \(check.name)"
                ))
            } else {
                // File doesn't exist — treat as inline fix command
                items.append(TrustableItem(
                    type: .fixScript,
                    relativePath: nil,
                    content: fixScript,
                    description: "Fix command for: \(check.name)"
                ))
            }
        }

        return items
    }

    /// Hashes for a set of trustable items — file hash by relative path, content hash under a
    /// synthetic key for inline items.
    ///
    /// Internal rather than private so tests can exercise the real key derivation: hand-rolling
    /// the synthetic-key formula in a test would let the two drift and hide exactly the
    /// change-detection gap these tests exist to catch.
    func computeScriptHashes(
        items: [TrustableItem],
        packPath: URL
    ) throws -> [String: String] {
        var hashes: [String: String] = [:]

        for item in items {
            if let relativePath = item.relativePath {
                let fileURL = packPath.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    hashes[relativePath] = try FileHasher.sha256(of: fileURL)
                }
            } else {
                // Inline command — hash the content with a deterministic synthetic key
                hashes[Self.syntheticKey(for: item)] = Self.contentHash(of: item.content)
            }
        }

        return hashes
    }
}

// MARK: - TrustableItem

/// An executable artifact within a pack that requires user trust approval.
struct TrustableItem {
    let type: TrustableType
    let relativePath: String? // For script files
    let content: String // The actual content to display
    let description: String // Human-readable description
    /// Whether this item describes the behaviour a pack already had before the artifact it covers
    /// was tracked for trust.
    ///
    /// Only meaningful for inline items on their *first* sighting: it distinguishes "this pack
    /// predates the tracking" from "this pack asks for something new", so introducing a new
    /// trustable artifact does not re-prompt every installed pack.
    var representsDefaultBehavior: Bool = false

    enum TrustableType {
        case shellCommand // From component install actions
        case hookFragment // From hook component files (runs on every session)
        case configureScript // From configureProject
        case doctorCommand // From commandExists doctor checks (runs during doctor)
        case doctorScript // From shellScript doctor checks
        case fixScript // From fix scripts / fix commands
        case mcpServerCommand // MCP server command (runs with user privs)
        case commandFile // Command file copied into .claude/commands/ (invoked by Claude)
        case hookInterpreter // Non-default command a hook file is invoked with (runs every session)
    }
}
