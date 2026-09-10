import Foundation

/// Executes declarative prompt definitions from external pack manifests,
/// gathering user input during install or configure flows.
struct PromptExecutor {
    let output: CLIOutput
    let scriptRunner: ScriptRunner

    /// Errors specific to prompt execution.
    enum PromptError: Error, Equatable, LocalizedError {
        case noFilesDetected(pattern: String)
        case scriptFailed(key: String, stderr: String)

        var errorDescription: String? {
            switch self {
            case let .noFilesDetected(pattern):
                "No files matching '\(pattern)' were found"
            case let .scriptFailed(key, stderr):
                "Script for prompt '\(key)' failed: \(stderr)"
            }
        }
    }

    /// Execute a single prompt definition and return the resolved value.
    ///
    /// - Parameters:
    ///   - prompt: The declarative prompt definition
    ///   - packPath: Root directory of the external pack
    ///   - projectPath: Current project root directory
    ///   - priorValue: Value resolved in a previous sync, used as the default for
    ///     `input`/`select` prompts and as the pre-selected file for `fileDetect`.
    ///     Ignored for `script`, which re-computes every sync.
    /// - Returns: The resolved value string
    func execute(
        prompt: PromptDefinition,
        packPath: URL,
        projectPath: URL,
        priorValue: String? = nil
    ) throws -> String {
        switch prompt.type {
        case .fileDetect:
            try executeFileDetect(prompt: prompt, projectPath: projectPath, priorValue: priorValue)
        case .input:
            executeInput(prompt: prompt, priorValue: priorValue)
        case .select:
            executeSelect(prompt: prompt, priorValue: priorValue)
        case .script:
            try executeScript(prompt: prompt, packPath: packPath, projectPath: projectPath)
        }
    }

    /// Execute all prompts from a manifest, returning resolved key-value pairs.
    ///
    /// - Parameters:
    ///   - prompts: Array of prompt definitions
    ///   - packPath: Root directory of the external pack
    ///   - projectPath: Current project root directory
    ///   - priorValues: Values from the previous sync, keyed by prompt key,
    ///     used as defaults for `input`/`select` prompts.
    /// - Returns: Dictionary of prompt key to resolved value
    func executeAll(
        prompts: [PromptDefinition],
        packPath: URL,
        projectPath: URL,
        priorValues: [String: String] = [:]
    ) throws -> [String: String] {
        var resolved: [String: String] = [:]
        for prompt in prompts {
            let value = try execute(
                prompt: prompt,
                packPath: packPath,
                projectPath: projectPath,
                priorValue: priorValues[prompt.key]
            )
            resolved[prompt.key] = value
        }
        return resolved
    }

    // MARK: - File Detect

    /// Scan for files matching one or more patterns and present a selector.
    /// `priorValue` pre-selects the file chosen last sync — pattern order decides the
    /// cursor otherwise, which can land on a sibling of the file the user actually picked.
    private func executeFileDetect(
        prompt: PromptDefinition,
        projectPath: URL,
        priorValue: String?
    ) throws -> String {
        let patterns = prompt.detectPatterns ?? ["*"]
        let files = Self.detectFiles(matching: patterns, in: projectPath)
        let patternDesc = patterns.joined(separator: ", ")

        switch files.count {
        case 0:
            // No files found — fall back to manual input
            let label = prompt.label ?? "Enter value for \(prompt.key)"
            let entered = output.promptInline(label, default: prompt.defaultValue)
            if entered.isEmpty {
                throw PromptError.noFilesDetected(pattern: patternDesc)
            }
            return entered

        case 1:
            output.info("Found: \(files[0])")
            return files[0]

        default:
            let items = files.map { name -> (name: String, description: String) in
                let ext = (name as NSString).pathExtension
                return (name: name, description: ext.isEmpty ? "File" : ext)
            }
            let label = prompt.label ?? "Select a file"
            let initialIndex = priorValue.flatMap { files.firstIndex(of: $0) } ?? 0
            let selected = output.singleSelect(title: label, items: items, initialIndex: initialIndex)
            return files[selected]
        }
    }

    /// Detect files matching multiple patterns in a directory.
    /// Results are returned in pattern order (first pattern's matches first),
    /// deduplicated, so earlier patterns take priority.
    static func detectFiles(matching patterns: [String], in directory: URL) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for pattern in patterns {
            for file in detectFiles(matching: pattern, in: directory)
                where seen.insert(file).inserted {
                result.append(file)
            }
        }
        return result
    }

    /// Detect files matching a simple extension-based pattern in a directory.
    /// Supports patterns like `*.xcodeproj`, `*.json`, or `*` for all files.
    /// Returns sorted file names (not full paths).
    static func detectFiles(matching pattern: String, in directory: URL) -> [String] {
        let fm = FileManager.default

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        // Extract extension from pattern (e.g., "*.xcodeproj" -> "xcodeproj")
        let ext: String?
        if pattern.hasPrefix("*."), pattern.count > 2 {
            ext = String(pattern.dropFirst(2))
        } else if pattern == "*" {
            ext = nil
        } else {
            // Literal filename match
            return contents
                .filter { $0.lastPathComponent == pattern }
                .map(\.lastPathComponent)
                .sorted()
        }

        if let ext {
            return contents
                .filter { $0.pathExtension == ext }
                .map(\.lastPathComponent)
                .sorted()
        }

        return contents
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: - Input

    /// Free-text prompt with optional default value.
    /// `priorValue` (stored from a previous sync) wins over `prompt.defaultValue` as the
    /// Enter-to-accept default. Prior values are masked in the prompt hint — pack-declared
    /// defaults are authored publicly and remain visible.
    private func executeInput(prompt: PromptDefinition, priorValue: String?) -> String {
        let label = prompt.label ?? "Enter value for \(prompt.key)"
        let effectiveDefault = priorValue ?? prompt.defaultValue
        return output.promptInline(label, default: effectiveDefault, maskDefault: priorValue != nil)
    }

    // MARK: - Select

    /// Single choice from a fixed list of options.
    /// `priorValue` (stored from a previous sync) becomes the pre-selected option when
    /// it matches an option value; otherwise the stored value is ignored (caller should
    /// have already purged invalid select priors upstream).
    private func executeSelect(prompt: PromptDefinition, priorValue: String?) -> String {
        guard let options = prompt.options, !options.isEmpty else {
            return priorValue ?? prompt.defaultValue ?? ""
        }

        let items = options.map { option -> (name: String, description: String) in
            (name: option.label, description: option.value)
        }
        let label = prompt.label ?? "Select value for \(prompt.key)"
        let initialIndex = PromptOption.index(of: priorValue, in: options)
        let selected = output.singleSelect(title: label, items: items, initialIndex: initialIndex)
        return options[selected].value
    }

    // MARK: - Script

    /// Run a script that outputs the resolved value to stdout.
    private func executeScript(
        prompt: PromptDefinition,
        packPath _: URL,
        projectPath _: URL
    ) throws -> String {
        if let scriptCommand = prompt.scriptCommand {
            // Run as a shell command
            let result = scriptRunner.runCommand(scriptCommand)
            if result.succeeded {
                return result.stdout
            }
            throw PromptError.scriptFailed(key: prompt.key, stderr: result.stderr)
        }

        // No script command provided
        return prompt.defaultValue ?? ""
    }
}
