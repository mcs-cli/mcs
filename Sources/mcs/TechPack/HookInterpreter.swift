import Foundation

/// Resolution and validation of the interpreter a hook command runs under.
///
/// The registered command is `"<interpreter> <path>"`. The interpreter is resolved in three steps:
/// an explicit `hookInterpreter` from the pack, then inference from the script's file extension,
/// then `Constants.HookCommand.defaultInterpreter`. Defaulting to bash keeps every pack authored
/// before this existed byte-identical.
///
/// This type also owns the inverse — recovering the interpreter from a command already in a
/// settings file — so the composed shape has one parser rather than one per consumer.
enum HookInterpreter {
    /// Extensions whose interpreter is unambiguous.
    ///
    /// Deliberately excludes TypeScript: `.ts` could mean `tsx`, `bun`, `deno`, or node with
    /// `--experimental-strip-types`, and guessing wrong is worse than falling back to bash with a
    /// warning from `mcs pack validate`.
    private static let inferenceTable: [String: String] = [
        "sh": "bash",
        "bash": "bash",
        "zsh": "zsh",
        "js": "node",
        "mjs": "node",
        "cjs": "node",
        "py": "python3",
        "rb": "ruby",
        "pl": "perl",
    ]

    /// Extensions that name a script language with no single safe interpreter.
    ///
    /// These resolve to the default (bash), which will not run them — `PackHeuristics` warns the
    /// author at publish time to declare `hookInterpreter` explicitly.
    private static let ambiguousExtensions: Set<String> = ["ts", "mts", "cts", "tsx"]

    /// Interpreters whose absence is not worth reporting — always present on macOS.
    private static let assumedPresent: Set<String> = ["bash", "sh", "zsh"]

    /// Longest interpreter string accepted, guarding against a pathological manifest value.
    ///
    /// Deliberately the only size limit: every token is charset-validated independently, so a long
    /// token list is no more dangerous than a short one, and capping the count would reject
    /// legitimate invocations like a `deno run` with six `--allow-*` flags.
    private static let maxLength = 200

    // MARK: - Resolution

    /// The interpreter for a hook, in precedence order: explicit, inferred, default.
    ///
    /// - Parameters:
    ///   - explicit: The component's `hookInterpreter`, already validated.
    ///   - destination: Installed filename — the script that actually runs.
    ///   - source: Pack-relative source path, consulted when `destination` has no extension.
    static func resolve(explicit: String?, destination: String, source: String?) -> String {
        // Rejoin on single spaces rather than returning the raw value. Validation already refuses
        // embedded newlines, and this makes that guarantee structural: no run of whitespace can
        // reach the composed command, where a newline would act as a shell command separator.
        if let explicit, case let normalized = tokens(of: explicit).joined(separator: " "),
           !normalized.isEmpty {
            return normalized
        }
        if let inferred = inferred(forPath: destination) {
            return inferred
        }
        // Only when the destination carries no extension at all. An extension that is present but
        // ambiguous (TypeScript) or unrecognised is an answer in itself — falling through to the
        // source would infer `node` for a `.ts` destination whose source happens to be `.js`.
        if fileExtension(of: destination).isEmpty,
           let source, let inferred = inferred(forPath: source) {
            return inferred
        }
        return Constants.HookCommand.defaultInterpreter
    }

    /// Whether a path's extension names a language with no safe default interpreter.
    static func isAmbiguous(path: String) -> Bool {
        ambiguousExtensions.contains(fileExtension(of: path))
    }

    /// Whether an interpreter is the engine default, compared as a whole value.
    ///
    /// Not a prefix test on the composed command: `bash -e` is an explicit choice that happens to
    /// start with the default, and `bashly` merely starts with the same letters.
    static func isDefault(_ interpreter: String) -> Bool {
        interpreter == Constants.HookCommand.defaultInterpreter
    }

    /// Whether a binary's absence is worth reporting. A missing `bash` is not a hook problem.
    static func isCheckable(binary: String) -> Bool {
        !assumedPresent.contains(binary)
    }

    /// The binary an interpreter string invokes, for existence checks.
    ///
    /// Looks through `env`: `/usr/bin/env node` dispatches to `node`, and verifying `env` — which
    /// is always present — would make the check pass while the hook dies for want of `node`.
    /// Skips env's own options and any `NAME=value` assignments preceding the command.
    static func binary(of interpreter: String) -> String {
        let parts = tokens(of: interpreter)
        guard let first = parts.first else { return interpreter }
        guard URL(fileURLWithPath: first).lastPathComponent == "env" else { return first }

        var rest = Array(parts.dropFirst())
        while let token = rest.first {
            if token == "-u" || token == "--unset" {
                // Consumes the following variable name.
                rest = Array(rest.dropFirst(2))
            } else if token.hasPrefix("-") || token.contains("=") {
                rest = Array(rest.dropFirst())
            } else {
                return token
            }
        }
        // `env` with nothing to dispatch — report it as-is rather than inventing a binary.
        return first
    }

    private static func tokens(of string: String) -> [String] {
        string.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The interpreter implied by a path's extension, or nil when the extension is unknown,
    /// ambiguous, or absent.
    private static func inferred(forPath path: String) -> String? {
        let ext = fileExtension(of: path)
        guard !ext.isEmpty, !ambiguousExtensions.contains(ext) else { return nil }
        return inferenceTable[ext]
    }

    private static func fileExtension(of path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    // MARK: - Parsing a registered command

    /// The hook path a registered command points at, when that path lives in `directory`.
    ///
    /// Parsing counterpart of `ComponentDefinition.hookCommand(pathPrefix:)`. Any token may be the
    /// path, not just the last, so a command carrying trailing arguments is still recognised —
    /// which is what lets global-scope cleanup reclaim its own directory whatever the interpreter
    /// or argument list.
    static func managedHookPath(in command: String, directory: String) -> String? {
        tokens(of: command).first { $0.hasPrefix(directory) }
    }

    /// The interpreter a registered hook command runs under, or nil when the command is not a
    /// managed hook invocation.
    ///
    /// The strict inverse of `ComponentDefinition.hookCommand(pathPrefix:)`: the path must be the
    /// *trailing* token, because that is the shape the engine composes. Requiring it is what stops
    /// an unrelated multi-token command — `mcs check-updates --hook`, say — from yielding a
    /// nonsense interpreter.
    static func interpreter(ofRegisteredCommand command: String, directory: String) -> String? {
        let parts = tokens(of: command)
        guard parts.count > 1, parts[parts.count - 1].hasPrefix(directory) else { return nil }
        return parts.dropLast().joined(separator: " ")
    }

    /// Distinct interpreter binaries worth verifying across a set of registered hook commands.
    ///
    /// Driven by recorded commands rather than component definitions so the result reflects what
    /// sync actually installed — excluded components contribute nothing, and a hook a pack has
    /// declared but not yet synced does not demand its runtime early. Deduplicated so ten node
    /// hooks produce one check; order follows the commands so doctor output is stable.
    static func distinctCheckableBinaries(inRegisteredCommands commands: [String], directory: String) -> [String] {
        var seen: Set<String> = []
        var binaries: [String] = []
        for command in commands {
            let interpreter = interpreter(ofRegisteredCommand: command, directory: directory)
                ?? Constants.HookCommand.defaultInterpreter
            let binary = binary(of: interpreter)
            guard isCheckable(binary: binary), seen.insert(binary).inserted else { continue }
            binaries.append(binary)
        }
        return binaries
    }

    // MARK: - Validation

    /// Why an interpreter string is unusable, phrased for a pack author.
    ///
    /// Returns nil when the value is acceptable. Callers decide the consequence: the manifest's
    /// `validate()` throws at publish time, the sync-time load path drops the value with a warning.
    static func rejectionReason(for interpreter: String) -> String? {
        let trimmed = interpreter.trimmingCharacters(in: .whitespacesAndNewlines)
        // Before tokenizing: a newline inside the value would be split away as token whitespace
        // and never reach the per-token charset check, while surviving into the composed command
        // as a shell command separator. Same for any other control character.
        if let offender = trimmed.unicodeScalars.first(where: { isForbiddenScalar($0) }) {
            return "hookInterpreter must not contain control characters or line breaks"
                + " (found U+\(String(format: "%04X", offender.value)))"
        }
        if trimmed.count > maxLength {
            return "hookInterpreter must be at most \(maxLength) characters (got \(trimmed.count))"
        }
        let parts = tokens(of: trimmed)
        guard let binary = parts.first else {
            return "hookInterpreter must not be empty — omit it to use bash"
        }
        guard isValidBinary(binary) else {
            return "hookInterpreter binary '\(binary)' must be a bare command name or an absolute"
                + " path, without shell metacharacters"
        }
        for argument in parts.dropFirst() where !isValidArgument(argument) {
            return "hookInterpreter argument '\(argument)' must be a plain flag or word, without"
                + " shell metacharacters — use a wrapper script for anything else"
        }
        return nil
    }

    /// Whether a scalar may never appear in an interpreter value.
    ///
    /// Every whitespace character except the plain space: tab, newline, carriage return and the
    /// exotic Unicode spaces all either separate shell commands or separate arguments in ways the
    /// per-token validation cannot see once splitting has consumed them.
    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return false }
        return CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: - Token shapes

    /// A bare command name (`node`) or a single path segment of an absolute path.
    private static let bareNamePattern = "[A-Za-z0-9][A-Za-z0-9._+-]*"

    /// A bare command name (`node`) or an absolute path (`/opt/homebrew/bin/bun`).
    ///
    /// Relative paths are rejected: the command runs with a working directory mcs does not
    /// control, so `./bin/node` would resolve unpredictably.
    private static func isValidBinary(_ token: String) -> Bool {
        if token.hasPrefix("/") {
            return matches(token, "^(/\(bareNamePattern))+$")
        }
        return matches(token, "^\(bareNamePattern)$")
    }

    /// A flag (`-u`, `--experimental-strip-types`, `--disable-warning=ExperimentalWarning`) or a
    /// plain word (the `run` in `uv run`).
    private static func isValidArgument(_ token: String) -> Bool {
        matches(token, "^-{0,2}[A-Za-z0-9][A-Za-z0-9._+=-]*$")
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        string.range(of: pattern, options: .regularExpression) != nil
    }
}
