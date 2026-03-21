import CryptoKit
import Foundation

/// Manages the trust lifecycle for external packs — analyzing executable content,
/// prompting for user approval, and verifying script integrity before execution.
struct PackTrustManager {
    let output: CLIOutput

    struct TrustDecision {
        let approved: Bool
        let scriptHashes: [String: String] // relativePath -> SHA-256
    }

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
                case let .shellCommand(command):
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
    /// If the pack has no executable content, trust is implicit (returns approved with empty hashes).
    func promptForTrust(
        manifest: ExternalPackManifest,
        packPath: URL,
        items: [TrustableItem]
    ) throws -> TrustDecision {
        if items.isEmpty {
            return TrustDecision(approved: true, scriptHashes: [:])
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
        let approved = output.askYesNo("Trust this pack?", default: false)

        if approved {
            let hashes = try computeScriptHashes(items: items, packPath: packPath)
            return TrustDecision(approved: true, scriptHashes: hashes)
        }

        return TrustDecision(approved: false, scriptHashes: [:])
    }

    // MARK: - Verify

    /// Verify that trusted scripts haven't changed since they were approved.
    /// Returns relative paths of scripts that have been modified.
    func verifyTrust(
        trustedHashes: [String: String],
        packPath: URL
    ) -> [String] {
        var modified: [String] = []
        let fm = FileManager.default

        for (relativePath, expectedHash) in trustedHashes {
            // Skip synthetic keys for inline commands (they have no file on disk)
            if relativePath.hasPrefix("inline:") {
                continue
            }

            let fileURL = packPath.appendingPathComponent(relativePath)

            guard fm.fileExists(atPath: fileURL.path) else {
                modified.append(relativePath)
                continue
            }

            do {
                let currentHash = try FileHasher.sha256(of: fileURL)
                if currentHash != expectedHash {
                    modified.append(relativePath)
                }
            } catch {
                // I/O error is distinct from tampering — surface the cause
                modified.append("\(relativePath) (unreadable: \(error.localizedDescription))")
            }
        }

        return modified.sorted()
    }

    /// Check if an update introduces new scripts not in the trusted set.
    /// Returns items for scripts that are new or have changed.
    func detectNewScripts(
        currentHashes: [String: String],
        updatedPackPath: URL,
        manifest: ExternalPackManifest
    ) throws -> [TrustableItem] {
        let allItems = try analyzeScripts(manifest: manifest, packPath: updatedPackPath)

        // Filter to items that are new or changed compared to trusted hashes
        return allItems.filter { item in
            guard let relativePath = item.relativePath else {
                // Inline command — check synthetic hash against trusted set
                let contentData = Data(item.content.utf8)
                let hash = SHA256.hash(data: contentData)
                    .map { String(format: "%02x", $0) }.joined()
                let syntheticKey = Self.syntheticKey(for: item)
                if let trustedHash = currentHashes[syntheticKey], trustedHash == hash {
                    return false // Unchanged
                }
                return true // New or changed
            }
            guard let trustedHash = currentHashes[relativePath] else {
                return true // New script not in trusted set
            }
            let fileURL = updatedPackPath.appendingPathComponent(relativePath)
            let hash: String
            do {
                hash = try FileHasher.sha256(of: fileURL)
            } catch {
                return true // Can't verify — flag for re-trust
            }
            return hash != trustedHash // Changed since last trust
        }
    }

    // MARK: - Helpers

    /// Deterministic synthetic key for inline commands (not backed by a file).
    /// Uses SHA-256 of the description to ensure stability across process invocations.
    /// Note: Swift's `String.hashValue` is randomized per-process (SE-0206) and must not
    /// be used for persistent keys.
    private static func syntheticKey(for item: TrustableItem) -> String {
        let descData = Data(item.description.utf8)
        let descHash = SHA256.hash(data: descData)
            .map { String(format: "%02x", $0) }.joined()
        return "inline:\(descHash)"
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

    /// Compute SHA-256 hashes for all trustable items — both script files and inline commands.
    private func computeScriptHashes(
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
                let contentData = Data(item.content.utf8)
                let hash = SHA256.hash(data: contentData)
                    .map { String(format: "%02x", $0) }.joined()
                let syntheticKey = Self.syntheticKey(for: item)
                hashes[syntheticKey] = hash
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

    enum TrustableType {
        case shellCommand // From component install actions
        case hookFragment // From hook component files (runs on every session)
        case configureScript // From configureProject
        case doctorCommand // From commandExists doctor checks (runs during doctor)
        case doctorScript // From shellScript doctor checks
        case fixScript // From fix scripts / fix commands
        case mcpServerCommand // MCP server command (runs with user privs)
        case commandFile // Command file copied into .claude/commands/ (invoked by Claude)
    }
}
