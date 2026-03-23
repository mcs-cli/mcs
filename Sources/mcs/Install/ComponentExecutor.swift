import Foundation

/// Shared component installation logic used by `PackInstaller` and
/// `Configurator`. Ensures consistent behavior across install paths.
struct ComponentExecutor {
    let environment: Environment
    let output: CLIOutput
    let shell: any ShellRunning
    let claudeCLI: any ClaudeCLI

    // MARK: - Brew Packages

    /// Install a Homebrew package, or confirm it's already available.
    func installBrewPackage(_ package: String) -> Bool {
        if shell.commandExists(package) { return true }
        let brew = Homebrew(shell: shell, environment: environment)
        guard brew.isInstalled else {
            output.warn("Homebrew not found, cannot install \(package)")
            return false
        }
        if brew.isPackageInstalled(package) { return true }
        let result = brew.install(package)
        if !result.succeeded {
            output.warn(String(result.stderr.prefix(200)))
        }
        return result.succeeded
    }

    // MARK: - MCP Servers

    /// Register an MCP server via the Claude CLI.
    func installMCPServer(_ config: MCPServerConfig) -> Bool {
        guard claudeCLI.isAvailable else {
            output.warn("Claude Code CLI not found, skipping MCP server")
            return false
        }
        var args: [String] = []
        for (key, value) in config.env.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if config.command == "http" {
            args.append(contentsOf: ["--transport", "http"])
            args.append(contentsOf: config.args)
        } else {
            args.append("--")
            args.append(config.command)
            args.append(contentsOf: config.args)
        }

        let result = claudeCLI.mcpAdd(name: config.name, scope: config.resolvedScope, arguments: args)
        return result.succeeded
    }

    // MARK: - Plugins

    /// Install a plugin via the Claude CLI.
    func installPlugin(_ fullName: String) -> Bool {
        guard claudeCLI.isAvailable else {
            output.warn("Claude Code CLI not found, skipping plugin")
            return false
        }
        let ref = PluginRef(fullName)
        let result = claudeCLI.pluginInstall(ref: ref)
        return result.succeeded
    }

    /// Uninstall a Homebrew package. Returns `true` if removal succeeded or package was already gone.
    func uninstallBrewPackage(_ package: String) -> Bool {
        let brew = Homebrew(shell: shell, environment: environment)
        guard brew.isInstalled else {
            output.warn("Homebrew not found, cannot uninstall '\(package)'")
            return false
        }
        guard brew.isPackageInstalled(package) else { return true }
        let result = brew.uninstall(package)
        if !result.succeeded {
            output.warn("Could not uninstall brew package '\(package)': \(String(result.stderr.prefix(200)))")
        }
        return result.succeeded
    }

    /// Remove a plugin via the Claude CLI. Returns `true` if removal succeeded.
    func removePlugin(_ fullName: String) -> Bool {
        guard claudeCLI.isAvailable else {
            output.warn("Claude Code CLI not found, cannot remove plugin")
            return false
        }
        let ref = PluginRef(fullName)
        let result = claudeCLI.pluginRemove(ref: ref)
        if !result.succeeded {
            output.warn("Could not remove plugin '\(ref.bareName)': \(result.stderr)")
        }
        return result.succeeded
    }

    // MARK: - Gitignore

    /// Add entries to the global gitignore.
    func addGitignoreEntries(_ entries: [String]) -> Bool {
        let manager = GitignoreManager(shell: shell)
        do {
            for entry in entries {
                try manager.addEntry(entry)
            }
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Copy Pack File

    /// Copy files from an external pack checkout to the appropriate Claude directory.
    /// When `resolvedValues` is non-empty, `__PLACEHOLDER__` tokens in text files are
    /// substituted before writing.
    func installCopyPackFile(
        source: URL,
        destination: String,
        fileType: CopyFileType,
        resolvedValues: [String: String] = [:]
    ) -> (success: Bool, hashes: [String: String]) {
        let fm = FileManager.default
        let expectedParent = fileType.baseDirectory(in: environment)

        guard let destURL = PathContainment.safePath(relativePath: destination, within: expectedParent) else {
            output.warn("Destination '\(destination)' escapes expected directory")
            return (false, [:])
        }

        guard fm.fileExists(atPath: source.path) else {
            output.warn("Pack source not found: \(source.path)")
            return (false, [:])
        }

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            var installedHashes: [String: String] = [:]

            if isDir.boolValue {
                // Source is a directory — copy all files recursively
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for file in contents {
                    let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try Self.copyWithSubstitution(from: file, to: destFile, values: resolvedValues)
                    if fileType == .hook {
                        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destFile.path)
                    }
                }
                // Hash all files recursively (directories can't be hashed directly)
                let hashResult = try FileHasher.directoryFileHashes(at: destURL)
                for (nestedRelPath, hash) in hashResult.hashes {
                    let fullPath = destURL.appendingPathComponent(nestedRelPath)
                    let relPath = PathContainment.relativePath(
                        of: fullPath.path,
                        within: environment.claudeDirectory.path
                    )
                    installedHashes[relPath] = hash
                }
                for (failedPath, error) in hashResult.failures {
                    output.warn("Could not compute hash for \(failedPath): \(error.localizedDescription)")
                }
            } else {
                // Source is a single file
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try Self.copyWithSubstitution(from: source, to: destURL, values: resolvedValues)

                // Make hooks executable
                if fileType == .hook {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                }
                let relPath = PathContainment.relativePath(
                    of: destURL.path,
                    within: environment.claudeDirectory.path
                )
                recordHash(of: destURL, relativePath: relPath, into: &installedHashes)
            }
            return (true, installedHashes)
        } catch {
            output.warn(error.localizedDescription)
            return (false, [:])
        }
    }

    // MARK: - Project-Scoped File Installation

    /// Copy a file or directory from an external pack into the project's `.claude/` tree.
    /// Text files are run through the template engine so `__PLACEHOLDER__` tokens
    /// are replaced with resolved prompt values.
    /// Returns the project-relative paths of installed files (for artifact tracking).
    mutating func installProjectFile(
        source: URL,
        destination: String,
        fileType: CopyFileType,
        projectPath: URL,
        resolvedValues: [String: String] = [:]
    ) -> (paths: [String], hashes: [String: String]) {
        let fm = FileManager.default
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)

        guard let destURL = PathContainment.safePath(relativePath: destination, within: baseDir) else {
            output.warn("Destination '\(destination)' escapes project directory")
            return ([], [:])
        }

        guard fm.fileExists(atPath: source.path) else {
            output.warn("Pack source not found: \(source.path)")
            return ([], [:])
        }

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            var installedPaths: [String] = []
            var installedHashes: [String: String] = [:]

            if isDir.boolValue {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for file in contents {
                    let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try Self.copyWithSubstitution(from: file, to: destFile, values: resolvedValues)
                    let relPath = projectRelativePath(destFile, projectPath: projectPath)
                    installedPaths.append(relPath)
                }
                // Hash all files recursively (directories can't be hashed directly)
                let hashResult = try FileHasher.directoryFileHashes(at: destURL)
                for (nestedRelPath, hash) in hashResult.hashes {
                    let fullPath = destURL.appendingPathComponent(nestedRelPath)
                    let relPath = projectRelativePath(fullPath, projectPath: projectPath)
                    installedHashes[relPath] = hash
                }
                for (failedPath, error) in hashResult.failures {
                    output.warn("Could not compute hash for \(failedPath): \(error.localizedDescription)")
                }
            } else {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try Self.copyWithSubstitution(from: source, to: destURL, values: resolvedValues)
                if fileType == .hook {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                }
                let relPath = projectRelativePath(destURL, projectPath: projectPath)
                installedPaths.append(relPath)
                recordHash(of: destURL, relativePath: relPath, into: &installedHashes)
            }
            return (installedPaths, installedHashes)
        } catch {
            output.warn(error.localizedDescription)
            return ([], [:])
        }
    }

    /// Copy a file or directory, substituting `__PLACEHOLDER__` values in text files.
    /// Recurses into subdirectories. Falls back to binary copy for non-UTF-8 files
    /// or when no values are provided.
    private static func copyWithSubstitution(
        from source: URL,
        to destination: URL,
        values: [String: String]
    ) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)

        if isDir.boolValue {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in contents {
                let destChild = destination.appendingPathComponent(child.lastPathComponent)
                try copyWithSubstitution(from: child, to: destChild, values: values)
            }
            return
        }

        if !values.isEmpty {
            // Read as Data first to surface I/O errors (permission, disk),
            // then attempt UTF-8 decode to detect binary vs text files.
            let data = try Data(contentsOf: source)
            if let text = String(data: data, encoding: .utf8) {
                let substituted = TemplateEngine.substitute(template: text, values: values)
                try substituted.write(to: destination, atomically: true, encoding: .utf8)
                return
            }
        }
        // Binary file or no values to substitute
        try fm.copyItem(at: source, to: destination)
    }

    /// Remove a file from the project by its project-relative path.
    /// Returns `true` if the file was removed, didn't exist, or escapes the project directory.
    @discardableResult
    func removeProjectFile(relativePath: String, projectPath: URL) -> Bool {
        guard let fullPath = PathContainment.safePath(relativePath: relativePath, within: projectPath) else {
            output.warn("Path '\(relativePath)' escapes project directory — clearing from tracking")
            return true
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: fullPath.path) else { return true }

        do {
            try fm.removeItem(at: fullPath)
            return true
        } catch {
            output.warn("Could not remove \(relativePath): \(error.localizedDescription)")
            return false
        }
    }

    /// Remove an MCP server by name and scope.
    /// Returns `true` if removal succeeded.
    @discardableResult
    func removeMCPServer(name: String, scope: String) -> Bool {
        let result = claudeCLI.mcpRemove(name: name, scope: scope)
        if !result.succeeded {
            output.warn("Could not remove MCP server '\(name)' (scope: \(scope)): \(result.stderr)")
        }
        return result.succeeded
    }

    /// Compute and record a SHA-256 hash for a just-installed file.
    /// Warns (without aborting the install) if hashing fails.
    private func recordHash(
        of file: URL,
        relativePath: String,
        into hashes: inout [String: String]
    ) {
        do {
            hashes[relativePath] = try FileHasher.sha256(of: file)
        } catch {
            output.warn("Could not compute hash for \(relativePath): \(error.localizedDescription)")
        }
    }

    private func projectRelativePath(_ url: URL, projectPath: URL) -> String {
        PathContainment.relativePath(of: url.path, within: projectPath.path)
    }

    // MARK: - Already-Installed Detection

    /// Check if a component is already installed using the same derived + supplementary
    /// doctor checks used by `mcs doctor`, ensuring install and doctor always use
    /// the same detection logic.
    static func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        // Convergent actions: always re-run to pick up config changes
        switch component.installAction {
        case .settingsMerge, .gitignoreEntries, .copyPackFile, .mcpServer:
            return false
        default:
            break
        }

        // Try derived check (auto-generated from installAction)
        if let check = component.deriveDoctorCheck() {
            if case .pass = check.check() { return true }
        }

        // Try supplementary checks (component-specific extras).
        // nil projectRoot: project-scoped checks will .skip, which is safe because
        // convergent actions (settings, gitignore, copyFile, MCP) are already short-
        // circuited above, and shellCommand re-runs are idempotent by convention.
        for check in component.supplementaryChecks(nil, Environment()) {
            if case .pass = check.check() { return true }
        }

        return false
    }
}
