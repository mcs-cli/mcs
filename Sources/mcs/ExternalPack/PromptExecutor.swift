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
        case unresolved(key: String)

        var errorDescription: String? {
            switch self {
            case let .noFilesDetected(pattern):
                "No files matching '\(pattern)' were found"
            case let .scriptFailed(key, stderr):
                "Script for prompt '\(key)' failed: \(stderr)"
            case let .unresolved(key):
                "Prompt '\(key)' has no seeded, stored or default value and stdin is not interactive"
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
        if !output.hasInteractiveStdin, prompt.type != .script {
            guard let value = Self.nonInteractiveValue(
                declarations: [prompt], prior: priorValue, projectPath: projectPath
            ) else {
                throw PromptError.unresolved(key: prompt.key)
            }
            return value
        }
        return switch prompt.type {
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

    /// Scan for files matching one or more patterns and present a selector (interactive only;
    /// off a TTY `execute` resolves through `nonInteractiveValue` instead).
    /// `priorValue` pre-selects the file chosen last sync, then the declared default — pattern
    /// order decides the cursor otherwise, which can land on a sibling of the file the user picked.
    /// With no match it pre-fills the manual entry, so a path below the top level isn't retyped.
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
            let entered = output.promptInline(label, default: priorValue ?? prompt.defaultValue)
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
            let initialIndex = (priorValue.flatMap { files.firstIndex(of: $0) })
                ?? (prompt.defaultValue.flatMap { files.firstIndex(of: $0) })
                ?? 0
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
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        return contents
            .map(\.lastPathComponent)
            .filter { matches($0, pattern: pattern) }
            .sorted()
    }

    /// Whether a file name matches a `detectPatterns` entry: `*`, `*.<ext>`, or a literal name.
    static func matches(_ name: String, pattern: String) -> Bool {
        if pattern == "*" {
            return true
        }
        if pattern.hasPrefix("*."), pattern.count > 2 {
            return (name as NSString).pathExtension == String(pattern.dropFirst(2))
        }
        return name == pattern
    }

    /// Whether a stored `fileDetect` answer still names a file the patterns accept.
    /// The scan only lists the project's top level, so a path the user typed into a
    /// subdirectory (a monorepo's `apps/ios/App.xcworkspace`) is checked on disk instead.
    static func priorStillExists(_ prior: String, patterns: [String], in projectPath: URL) -> Bool {
        guard !prior.isEmpty,
              let url = PathContainment.safePath(relativePath: prior, within: projectPath),
              FileManager.default.fileExists(atPath: url.path)
        else { return false }
        return patterns.contains { matches(url.lastPathComponent, pattern: $0) }
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
        let initialIndex = PromptOption.index(of: priorValue, in: options, fallback: prompt.defaultValue)
        let selected = output.singleSelect(title: label, items: items, initialIndex: initialIndex)
        return options[selected].value
    }

    // MARK: - Non-Interactive

    /// The value one key resolves to without a reader: the prior, then the first declared
    /// default, each only if the declarations admit it. `nil` means the key is unanswerable
    /// and the run must fail rather than store whatever EOF yields.
    ///
    /// `declarations` are the ones the answering sync step would use: one pack's, or a shared
    /// group's — never a `script`. Any `input` declaration admits a value verbatim; a set that
    /// is all `fileDetect` scans every declaration's patterns and follows the executor's
    /// zero-, one- and many-match branches; otherwise the merged `select` options constrain it.
    static func nonInteractiveValue(
        declarations: [PromptDefinition],
        prior: String?,
        projectPath: URL
    ) -> String? {
        let types = Set(declarations.map(\.type))
        guard !types.isEmpty else { return nil }
        let declaredDefault = declarations.compactMap(\.defaultValue).first
        let candidates = [prior, declaredDefault].compactMap(\.self)

        if types.contains(.input) {
            return candidates.first
        }

        if types == [.fileDetect] {
            let patterns = declarations.flatMap { $0.detectPatterns ?? ["*"] }
            let files = detectFiles(matching: patterns, in: projectPath)
            switch files.count {
            case 0:
                // Only a prior or a default can name a file the scan can't see, and an empty
                // default is rejected here just as the interactive zero-match branch rejects it.
                if let prior, priorStillExists(prior, patterns: patterns, in: projectPath) {
                    return prior
                }
                return declaredDefault.flatMap { $0.isEmpty ? nil : $0 }
            case 1:
                return files[0]
            default:
                return candidates.first { files.contains($0) }
            }
        }

        let constrained = Set(declarations.flatMap { $0.options ?? [] }.map(\.value))
        return candidates.first { constrained.isEmpty || constrained.contains($0) }
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
