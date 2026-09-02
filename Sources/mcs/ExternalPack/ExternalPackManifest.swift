import Foundation
import Yams

// MARK: - Manifest Root

/// Codable model for `techpack.yaml` — the declarative manifest for external tech packs.
struct ExternalPackManifest: Codable {
    let schemaVersion: Int
    let identifier: String
    let displayName: String
    let description: String
    let author: String?
    let minMCSVersion: String?
    let components: [ExternalComponentDefinition]?
    let templates: [ExternalTemplateDefinition]?
    let prompts: [PromptDefinition]?
    let configureProject: ExternalConfigureProject?
    let supplementaryDoctorChecks: [ExternalDoctorCheckDefinition]?
    /// POSIX-glob patterns (see `GlobMatcher`) that mark paths as non-material:
    /// - `UpdateChecker`'s noise filter treats matching paths as infrastructure, extending the built-in
    ///   deny-list (README, LICENSE, etc.) with author-supplied entries.
    /// - `PackHeuristics.checkUnreferencedFiles` silences unreferenced-file warnings for matching paths.
    /// Entries cannot reference `techpack.yaml` or any path referenced by a component/template —
    /// `validate()` rejects those at publish time and the runtime loader strips them defensively.
    let ignore: [String]?
}

// MARK: - Loading

extension ExternalPackManifest {
    /// Load and decode a `techpack.yaml` file from disk.
    static func load(from url: URL) throws -> ExternalPackManifest {
        let data = try Data(contentsOf: url)
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ManifestError.invalidEncoding
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(ExternalPackManifest.self, from: yamlString)
    }
}

// MARK: - Validation

extension ExternalPackManifest {
    /// Validate the manifest for structural correctness.
    func validate() throws {
        // Schema version
        guard schemaVersion == 1 else {
            throw ManifestError.unsupportedSchemaVersion(schemaVersion)
        }

        // Identifier: non-empty, lowercase alphanumeric + hyphens only
        let identifierPattern = #"^[a-z0-9][a-z0-9-]*$"#
        guard !identifier.isEmpty,
              identifier.range(of: identifierPattern, options: .regularExpression) != nil
        else {
            throw ManifestError.invalidIdentifier(identifier)
        }

        // Component ID prefix and dependency resolution
        var seenComponentIDs = Set<String>()
        if let components {
            let expectedPrefix = "\(identifier)."
            for component in components {
                guard component.id.hasPrefix(expectedPrefix) else {
                    throw ManifestError.componentIDPrefixViolation(
                        componentID: component.id,
                        expectedPrefix: expectedPrefix
                    )
                }
                guard !seenComponentIDs.contains(component.id) else {
                    throw ManifestError.duplicateComponentID(component.id)
                }
                seenComponentIDs.insert(component.id)

                // Validate hook registration metadata
                if let reg = component.hookRegistration {
                    if let timeout = reg.timeout, timeout <= 0 {
                        throw ManifestError.invalidHookMetadata(
                            componentID: component.id,
                            reason: "hookTimeout must be positive (got \(timeout))"
                        )
                    }
                    if let interpreter = reg.interpreter,
                       let reason = HookInterpreter.rejectionReason(for: interpreter) {
                        throw ManifestError.invalidHookMetadata(
                            componentID: component.id,
                            reason: reason
                        )
                    }
                }
            }

            // Validate intra-pack dependency references resolve to existing component IDs
            for component in components {
                for dep in component.dependencies ?? [] {
                    if dep.hasPrefix(expectedPrefix), !seenComponentIDs.contains(dep) {
                        throw ManifestError.unresolvedDependency(
                            componentID: component.id,
                            dependency: dep
                        )
                    }
                }
            }

            // Validate no conflicting copyPackFile destinations within the pack.
            // Multiple components may legitimately share a (destination, fileType) when
            // they copy the same source — e.g., one hook script registered against two
            // hook events via two components. A real conflict is same destination with
            // different sources.
            struct DestKey: Hashable {
                let destination: String
                let fileType: String
            }
            struct DestEntry {
                let componentID: String
                let source: String
            }
            var seenDestinations: [DestKey: [DestEntry]] = [:]
            for component in components {
                if case let .copyPackFile(config) = component.installAction {
                    let key = DestKey(
                        destination: config.destination,
                        fileType: config.fileType?.rawValue ?? ExternalCopyFileType.generic.rawValue
                    )
                    seenDestinations[key, default: []].append(
                        DestEntry(componentID: component.id, source: config.source)
                    )
                }
            }
            let sortedDestinations = seenDestinations.sorted { lhs, rhs in
                (lhs.key.destination, lhs.key.fileType) < (rhs.key.destination, rhs.key.fileType)
            }
            for (key, entries) in sortedDestinations {
                guard entries.count > 1 else { continue }
                // Identity case: every entry copies the same source file — benign.
                if entries.dropFirst().allSatisfy({ $0.source == entries[0].source }) { continue }
                throw ManifestError.duplicateDestination(
                    destination: key.destination,
                    fileType: key.fileType,
                    componentIDs: entries.map(\.componentID)
                )
            }
        }

        // Template section identifiers must be prefixed with pack identifier
        if let templates {
            for template in templates {
                guard template.sectionIdentifier.hasPrefix("\(identifier).") else {
                    throw ManifestError.templateSectionMismatch(
                        sectionIdentifier: template.sectionIdentifier,
                        packIdentifier: identifier
                    )
                }
                for dep in template.dependencies ?? [] {
                    guard seenComponentIDs.contains(dep) else {
                        throw ManifestError.templateDependencyMismatch(
                            sectionIdentifier: template.sectionIdentifier,
                            componentID: dep
                        )
                    }
                }
            }
        }

        // Prompt key uniqueness
        if let prompts {
            var seenKeys = Set<String>()
            for prompt in prompts {
                guard !seenKeys.contains(prompt.key) else {
                    throw ManifestError.duplicatePromptKey(prompt.key)
                }
                seenKeys.insert(prompt.key)
            }
        }

        // Doctor check field validation
        if let checks = supplementaryDoctorChecks {
            for check in checks {
                try validateDoctorCheck(check)
            }
        }
        if let components {
            for component in components {
                if let checks = component.doctorChecks {
                    for check in checks {
                        try validateDoctorCheck(check)
                    }
                }
            }
        }

        // `ignore:` entries cannot silence load-bearing files (issue #338).
        // `techpack.yaml` is always material; any path referenced by a component/template
        // is required for install — silencing it would produce a broken pack.
        try validateIgnoreEntries()
    }

    /// Why an `ignore:` entry is forbidden. Both `validateIgnoreEntries` (publish-strict)
    /// and `sanitizedIgnoreEntries` (runtime-lenient) classify entries via this enum so the
    /// rule list lives in one place.
    enum IgnoreEntryRejection {
        case empty
        case manifestFile
        case referencedPath

        var reason: String {
            switch self {
            case .empty:
                "empty entries are not allowed"
            case .manifestFile:
                "\(Constants.ExternalPacks.manifestFilename) is always tracked — manifest edits can change the install surface"
            case .referencedPath:
                "path is referenced by a component or template. Remove it from `ignore:` or remove the component."
            }
        }
    }

    /// Classify a single `ignore:` entry; returns nil if the entry is acceptable.
    ///
    /// `ignore:` is glob-aware (issue #338), so the safety rule must be glob-aware too —
    /// otherwise patterns like `*.yaml`, `hooks/*`, or `hooks/` would silently bypass the
    /// "load-bearing files are always tracked" invariant. The entry is rejected whenever
    /// its pattern *matches* `techpack.yaml` or any referenced path, not just when the
    /// strings are equal.
    static func classifyIgnoreEntry(
        _ entry: String,
        referenced: Set<String>
    ) -> IgnoreEntryRejection? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if GlobMatcher.matches(trimmed, path: Constants.ExternalPacks.manifestFilename) {
            return .manifestFile
        }
        for path in referenced where GlobMatcher.matches(trimmed, path: path) {
            return .referencedPath
        }
        return nil
    }

    private func validateIgnoreEntries() throws {
        guard let ignore, !ignore.isEmpty else { return }
        let referenced = referencedPaths
        for entry in ignore {
            if let rejection = Self.classifyIgnoreEntry(entry, referenced: referenced) {
                throw ManifestError.ignoreEntryLoadBearing(entry: entry, reason: rejection.reason)
            }
        }
    }

    private func validateDoctorCheck(_ check: ExternalDoctorCheckDefinition) throws {
        switch check.type {
        case .commandExists:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "commandExists requires non-empty 'command'")
            }
        case .fileExists, .directoryExists:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
        case .fileContains, .fileNotContains:
            guard let path = check.path, !path.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'path'")
            }
            guard let pattern = check.pattern, !pattern.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "\(check.type.rawValue) requires non-empty 'pattern'")
            }
        case .shellScript:
            guard let command = check.command, !command.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "shellScript requires non-empty 'command'")
            }
        case .hookEventExists:
            guard let event = check.event, !event.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "hookEventExists requires non-empty 'event'")
            }
            guard Constants.HookEvent.validRawValues.contains(event) else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "hookEventExists has unknown event '\(event)'")
            }
            // An empty matcher is ambiguous: it reads as an assertion but compares equal to a
            // group with no matcher at all. Omit the key to skip the assertion.
            if let matcher = check.matcher, matcher.isEmpty {
                throw ManifestError.invalidDoctorCheck(
                    name: check.name,
                    reason: "hookEventExists 'matcher' must be non-empty — omit it to skip the assertion"
                )
            }
            if let command = check.command, command.isEmpty {
                throw ManifestError.invalidDoctorCheck(
                    name: check.name,
                    reason: "hookEventExists 'command' must be non-empty — omit it to skip the assertion"
                )
            }
        case .settingsKeyEquals:
            guard let keyPath = check.keyPath, !keyPath.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'keyPath'")
            }
            guard let expectedValue = check.expectedValue, !expectedValue.isEmpty else {
                throw ManifestError.invalidDoctorCheck(name: check.name, reason: "settingsKeyEquals requires non-empty 'expectedValue'")
            }
        }
    }
}

// MARK: - Ignore-entry sanitization (runtime safety guard)

extension ExternalPackManifest {
    /// Return a copy with forbidden `ignore:` entries stripped, emitting a warning for each.
    /// Used by the sync-time load path so a malformed manifest (older toolchain, hand-edited)
    /// doesn't break the user's workflow — `mcs pack validate` catches the same entries
    /// with a hard error at publish time. Issue #338 belt-and-suspenders.
    func sanitizedIgnoreEntries(output: CLIOutput) -> ExternalPackManifest {
        sanitizedIgnoreEntries { entry, rejection in
            output.warn("Pack '\(identifier)': dropping `ignore:` entry '\(entry)' — \(rejection.reason)")
        }
    }

    /// Silent counterpart of `sanitizedIgnoreEntries(output:)` — used on hook paths
    /// (e.g. update-check) where there is no `CLIOutput` to warn through but a malformed
    /// local manifest still must not silence load-bearing files.
    func silentlySanitizedIgnoreEntries() -> ExternalPackManifest {
        sanitizedIgnoreEntries { _, _ in }
    }

    private func sanitizedIgnoreEntries(
        rejected: (_ entry: String, _ rejection: IgnoreEntryRejection) -> Void
    ) -> ExternalPackManifest {
        guard let ignore, !ignore.isEmpty else { return self }
        let referenced = referencedPaths
        var kept: [String] = []
        for entry in ignore {
            if let rejection = Self.classifyIgnoreEntry(entry, referenced: referenced) {
                rejected(entry, rejection)
                continue
            }
            kept.append(entry)
        }
        // Empty and absent collapse to nil so downstream callers (e.g. `isIgnoredByManifest`)
        // can treat "no ignore list" as a single state.
        return ExternalPackManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: displayName,
            description: description,
            author: author,
            minMCSVersion: minMCSVersion,
            components: components,
            templates: templates,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks,
            ignore: kept.isEmpty ? nil : kept
        )
    }
}

// MARK: - Hook eligibility

extension ExternalComponentDefinition {
    /// The interpreter and installed filename this component's hook runs as, or nil when it
    /// registers no hook.
    ///
    /// The manifest-model counterpart of `ComponentDefinition.hookInvocation`, and it must apply
    /// the same three conditions — `type`, a registration, and `fileType` — because the adapter
    /// drops any component failing them. A copy of this rule that omits one reports findings for
    /// hooks sync never registers, which is how the two sides drifted before.
    var hookInvocation: (interpreter: String, destination: String)? {
        guard type == .hookFile, let registration = hookRegistration,
              case let .copyPackFile(config) = installAction,
              config.fileType == .hook
        else { return nil }
        let interpreter = HookInterpreter.resolve(
            explicit: registration.interpreter,
            destination: config.destination,
            source: config.source
        )
        return (interpreter, config.destination)
    }
}

// MARK: - Hook interpreter sanitization (runtime safety guard)

extension ExternalPackManifest {
    /// Return a copy with unusable `hookInterpreter` values dropped, warning for each.
    ///
    /// Same publish-strict / runtime-lenient split as `sanitizedIgnoreEntries(output:)`:
    /// `mcs pack validate` fails hard on the same value, while a user's sync keeps working — the
    /// hook falls back to extension inference, then bash.
    func sanitizedHookInterpreters(output: CLIOutput) -> ExternalPackManifest {
        guard let components else { return self }

        var strippedAny = false
        let cleaned = components.map { component -> ExternalComponentDefinition in
            guard let registration = component.hookRegistration,
                  let interpreter = registration.interpreter,
                  let reason = HookInterpreter.rejectionReason(for: interpreter)
            else { return component }
            output.warn(
                "Pack '\(identifier)': dropping `hookInterpreter` '\(interpreter)' from"
                    + " '\(component.id)' — \(reason)"
            )
            strippedAny = true
            var sanitized = component
            sanitized.hookRegistration = HookRegistration(
                event: registration.event,
                matcher: registration.matcher,
                timeout: registration.timeout,
                isAsync: registration.isAsync,
                statusMessage: registration.statusMessage,
                interpreter: nil
            )
            return sanitized
        }
        guard strippedAny else { return self }

        return ExternalPackManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: displayName,
            description: description,
            author: author,
            minMCSVersion: minMCSVersion,
            components: cleaned,
            templates: templates,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks,
            ignore: ignore
        )
    }
}

// MARK: - Normalization

extension ExternalPackManifest {
    /// Returns a copy with short component IDs and intra-pack dependencies auto-prefixed
    /// with the pack identifier. Throws if any component ID or template section identifier
    /// contains a dot — pack authors must use short names and let the tool add the prefix.
    func normalized() throws -> ExternalPackManifest {
        let prefix = "\(identifier)."
        let normalizedComponents = try components?.map { component -> ExternalComponentDefinition in
            var c = component
            guard !c.id.contains(".") else {
                throw ManifestError.dotInRawID(c.id)
            }
            c.id = prefix + c.id
            c.dependencies = c.dependencies?.map { dep in
                dep.contains(".") ? dep : prefix + dep
            }
            return c
        }
        let normalizedTemplates = try templates?.map { template -> ExternalTemplateDefinition in
            var t = template
            guard !t.sectionIdentifier.contains(".") else {
                throw ManifestError.dotInRawID(t.sectionIdentifier)
            }
            t.sectionIdentifier = prefix + t.sectionIdentifier
            t.dependencies = try t.dependencies?.map { dep in
                guard !dep.contains(".") else {
                    throw ManifestError.dotInRawID(dep)
                }
                return prefix + dep
            }
            return t
        }
        return ExternalPackManifest(
            schemaVersion: schemaVersion,
            identifier: identifier,
            displayName: displayName,
            description: description,
            author: author,
            minMCSVersion: minMCSVersion,
            components: normalizedComponents,
            templates: normalizedTemplates,
            prompts: prompts,
            configureProject: configureProject,
            supplementaryDoctorChecks: supplementaryDoctorChecks,
            ignore: ignore
        )
    }
}

// MARK: - Errors

/// Errors that can occur during manifest loading or validation.
enum ManifestError: Error, Equatable, LocalizedError {
    case invalidEncoding
    case unsupportedSchemaVersion(Int)
    case invalidIdentifier(String)
    case componentIDPrefixViolation(componentID: String, expectedPrefix: String)
    case duplicateComponentID(String)
    case templateSectionMismatch(sectionIdentifier: String, packIdentifier: String)
    case duplicatePromptKey(String)
    case invalidDoctorCheck(name: String, reason: String)
    case dotInRawID(String)
    case templateDependencyMismatch(sectionIdentifier: String, componentID: String)
    case unresolvedDependency(componentID: String, dependency: String)
    case invalidHookMetadata(componentID: String, reason: String)
    case duplicateDestination(destination: String, fileType: String, componentIDs: [String])
    case ignoreEntryLoadBearing(entry: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "Manifest file is not valid UTF-8"
        case let .unsupportedSchemaVersion(version):
            "Unsupported schema version: \(version) (expected 1)"
        case let .invalidIdentifier(id):
            "Invalid pack identifier '\(id)': must be non-empty, lowercase alphanumeric with hyphens"
        case let .componentIDPrefixViolation(componentID, expectedPrefix):
            "Component ID '\(componentID)' must start with '\(expectedPrefix)'"
        case let .duplicateComponentID(id):
            "Duplicate component ID: '\(id)'"
        case let .templateSectionMismatch(section, pack):
            "Template section '\(section)' must be prefixed with '\(pack).' (e.g. '\(pack).main')"
        case let .templateDependencyMismatch(section, component):
            "Template '\(section)' depends on component '\(component)' which does not exist in the pack"
        case let .duplicatePromptKey(key):
            "Duplicate prompt key: '\(key)'"
        case let .invalidDoctorCheck(name, reason):
            "Invalid doctor check '\(name)': \(reason)"
        case let .dotInRawID(id):
            "ID '\(id)' must not contain dots — use a short name and the pack prefix will be added automatically"
        case let .unresolvedDependency(componentID, dependency):
            "Component '\(componentID)' depends on '\(dependency)' which does not exist in the pack"
        case let .invalidHookMetadata(componentID, reason):
            "Component '\(componentID)': \(reason)"
        case let .duplicateDestination(destination, fileType, componentIDs):
            "Duplicate copyPackFile destination '\(destination)' (fileType: \(fileType))"
                + " in components: \(componentIDs.joined(separator: ", "))"
        case let .ignoreEntryLoadBearing(entry, reason):
            "ignore: entry '\(entry)' is not allowed: \(reason)"
        }
    }
}

// MARK: - Components

/// Declarative definition of an installable component within an external pack.
///
/// Supports two authoring styles:
///
/// **Verbose** (all fields explicit):
/// ```yaml
/// - id: node
///   displayName: Node.js
///   description: JavaScript runtime
///   type: brewPackage
///   installAction:
///     type: brewInstall
///     package: node
/// ```
///
/// **Shorthand** (type + installAction inferred from a single key):
/// ```yaml
/// - id: node
///   description: JavaScript runtime
///   brew: node
/// ```
///
/// Shorthand keys: `brew`, `mcp`, `plugin`, `shell`, `hook`, `command`,
/// `skill`, `settingsFile`, `gitignore`. See `ShorthandKeys` for details.
struct ExternalComponentDefinition: Codable, Equatable {
    var id: String
    let displayName: String
    let description: String
    let type: ExternalComponentType
    var dependencies: [String]?
    let isRequired: Bool?
    /// Hook registration metadata. When set, the engine auto-registers this hook
    /// in `settings.local.json` with the specified handler fields.
    /// YAML keys remain flat (`hookEvent`, `hookTimeout`, `hookAsync`, `hookStatusMessage`)
    /// for pack author ergonomics; the custom Codable implementation maps them to this struct.
    ///
    /// `var` like `id` and `dependencies`, so a sanitizing copy can rewrite one field without
    /// respelling every other — a respelling silently drops any field added later.
    var hookRegistration: HookRegistration?
    let installAction: ExternalInstallAction
    let doctorChecks: [ExternalDoctorCheckDefinition]?

    // MARK: CodingKeys

    /// Standard keys matching stored properties (used by encode).
    enum CodingKeys: String, CodingKey {
        case id, displayName, description, type, dependencies, isRequired
        case hookEvent, hookMatcher, hookTimeout, hookAsync, hookStatusMessage, hookInterpreter
        case installAction, doctorChecks
    }

    /// Shorthand install-action keys that replace `type` + `installAction`.
    enum ShorthandKeys: String, CodingKey {
        case brew // String — brew package name
        case mcp // Map — MCPShorthand (name inferred from id)
        case plugin // String — plugin full name
        case shell // String — shell command (requires explicit `type`)
        case shellInteractive // Bool — allocate PTY for commands needing terminal access (e.g. sudo)
        case hook // Map — CopyFileShorthand (fileType: .hook)
        case command // Map — CopyFileShorthand (fileType: .command)
        case skill // Map — CopyFileShorthand (fileType: .skill)
        case agent // Map — CopyFileShorthand (fileType: .agent)
        case settingsFile // String — source path
        case gitignore // [String] — gitignore entries
    }

    // MARK: Memberwise init

    init(
        id: String,
        displayName: String,
        description: String,
        type: ExternalComponentType,
        dependencies: [String]? = nil,
        isRequired: Bool? = nil,
        hookRegistration: HookRegistration? = nil,
        installAction: ExternalInstallAction,
        doctorChecks: [ExternalDoctorCheckDefinition]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.type = type
        self.dependencies = dependencies
        self.isRequired = isRequired
        self.hookRegistration = hookRegistration
        self.installAction = installAction
        self.doctorChecks = doctorChecks
    }

    // MARK: Decode (shorthand + verbose)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shorthand = try decoder.container(keyedBy: ShorthandKeys.self)

        id = try container.decode(String.self, forKey: .id)
        description = try container.decode(String.self, forKey: .description)
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies)
        isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired)
        let hookEventRaw = try container.decodeIfPresent(String.self, forKey: .hookEvent)
        let hookMatcher = try container.decodeIfPresent(String.self, forKey: .hookMatcher)
        let hookTimeout = try container.decodeIfPresent(Int.self, forKey: .hookTimeout)
        let hookAsync = try container.decodeIfPresent(Bool.self, forKey: .hookAsync)
        let hookStatusMessage = try container.decodeIfPresent(String.self, forKey: .hookStatusMessage)
        let hookInterpreter = try container.decodeIfPresent(String.self, forKey: .hookInterpreter)
        if let hookEventRaw {
            guard let hookEvent = Constants.HookEvent(rawValue: hookEventRaw) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Component '\(id)': unknown hookEvent '\(hookEventRaw)'"
                    )
                )
            }
            hookRegistration = HookRegistration(
                event: hookEvent, matcher: hookMatcher, timeout: hookTimeout, isAsync: hookAsync,
                statusMessage: hookStatusMessage, interpreter: hookInterpreter
            )
        } else {
            hookRegistration = nil
            // Reject orphaned hook metadata (matcher/timeout/async/statusMessage/interpreter
            // without hookEvent)
            let orphanedMetadata = [hookMatcher, hookStatusMessage, hookInterpreter].contains { $0 != nil }
                || hookTimeout != nil || hookAsync != nil
            if orphanedMetadata {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription:
                        "Component '\(id)': hookMatcher/hookTimeout/hookAsync/hookStatusMessage/hookInterpreter"
                            + " require hookEvent to be set"
                    )
                )
            }
        }
        doctorChecks = try container.decodeIfPresent([ExternalDoctorCheckDefinition].self, forKey: .doctorChecks)

        if let resolved = try Self.resolveShorthand(shorthand, componentId: id) {
            type = try resolved.type ?? container.decode(ExternalComponentType.self, forKey: .type)
            installAction = resolved.action
        } else {
            type = try container.decode(ExternalComponentType.self, forKey: .type)
            installAction = try container.decode(ExternalInstallAction.self, forKey: .installAction)
        }

        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
    }

    // MARK: Encode (always verbose)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(description, forKey: .description)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(isRequired, forKey: .isRequired)
        try container.encodeIfPresent(hookRegistration?.event.rawValue, forKey: .hookEvent)
        try container.encodeIfPresent(hookRegistration?.matcher, forKey: .hookMatcher)
        try container.encodeIfPresent(hookRegistration?.timeout, forKey: .hookTimeout)
        try container.encodeIfPresent(hookRegistration?.isAsync, forKey: .hookAsync)
        try container.encodeIfPresent(hookRegistration?.statusMessage, forKey: .hookStatusMessage)
        try container.encodeIfPresent(hookRegistration?.interpreter, forKey: .hookInterpreter)
        try container.encode(installAction, forKey: .installAction)
        try container.encodeIfPresent(doctorChecks, forKey: .doctorChecks)
    }

    // MARK: - Shorthand Resolution

    private struct ResolvedShorthand {
        let type: ExternalComponentType?
        let action: ExternalInstallAction
    }

    private static func resolveShorthand(
        _ shorthand: KeyedDecodingContainer<ShorthandKeys>,
        componentId: String
    ) throws -> ResolvedShorthand? {
        if shorthand.contains(.brew) {
            let package = try shorthand.decode(String.self, forKey: .brew)
            return ResolvedShorthand(type: .brewPackage, action: .brewInstall(package: package))
        }
        if shorthand.contains(.mcp) {
            let config = try shorthand.decode(MCPShorthand.self, forKey: .mcp)
            let defaultName = componentId.split(separator: ".").last.map(String.init) ?? componentId
            return ResolvedShorthand(type: .mcpServer, action: .mcpServer(config.toExternalConfig(defaultName: defaultName)))
        }
        if shorthand.contains(.plugin) {
            let name = try shorthand.decode(String.self, forKey: .plugin)
            return ResolvedShorthand(type: .plugin, action: .plugin(name: name))
        }
        if shorthand.contains(.shell) {
            let command = try shorthand.decode(String.self, forKey: .shell)
            let interactive = try shorthand.decodeIfPresent(Bool.self, forKey: .shellInteractive) ?? false
            return ResolvedShorthand(type: nil, action: .shellCommand(command: command, interactive: interactive))
        }
        if shorthand.contains(.hook) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .hook)
            return ResolvedShorthand(type: .hookFile, action: .copyPackFile(config.toExternalConfig(fileType: .hook)))
        }
        if shorthand.contains(.command) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .command)
            return ResolvedShorthand(type: .command, action: .copyPackFile(config.toExternalConfig(fileType: .command)))
        }
        if shorthand.contains(.skill) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .skill)
            return ResolvedShorthand(type: .skill, action: .copyPackFile(config.toExternalConfig(fileType: .skill)))
        }
        if shorthand.contains(.agent) {
            let config = try shorthand.decode(CopyFileShorthand.self, forKey: .agent)
            return ResolvedShorthand(type: .agent, action: .copyPackFile(config.toExternalConfig(fileType: .agent)))
        }
        if shorthand.contains(.settingsFile) {
            let source = try shorthand.decode(String.self, forKey: .settingsFile)
            return ResolvedShorthand(type: .configuration, action: .settingsFile(source: source))
        }
        if shorthand.contains(.gitignore) {
            let entries = try shorthand.decode([String].self, forKey: .gitignore)
            return ResolvedShorthand(type: .configuration, action: .gitignoreEntries(entries: entries))
        }
        return nil
    }
}

// MARK: - Shorthand Helper Structs

/// Shorthand MCP server configuration — `name` defaults to the component id
/// but can be overridden (e.g. when the server name uses mixed case).
struct MCPShorthand: Codable {
    let name: String?
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let scope: ExternalScope?

    func toExternalConfig(defaultName: String) -> ExternalMCPServerConfig {
        ExternalMCPServerConfig(
            name: name ?? defaultName,
            command: command,
            args: args,
            env: env,
            transport: url != nil ? .http : nil,
            url: url,
            scope: scope
        )
    }
}

/// Shorthand copy-file configuration — `fileType` is inferred from the shorthand key.
struct CopyFileShorthand: Codable {
    let source: String
    let destination: String

    func toExternalConfig(fileType: ExternalCopyFileType) -> ExternalCopyPackFileConfig {
        ExternalCopyPackFileConfig(
            source: source,
            destination: destination,
            fileType: fileType
        )
    }
}

/// String-backed component type that maps to the internal `ComponentType`.
enum ExternalComponentType: String, Codable {
    case mcpServer
    case plugin
    case skill
    case hookFile
    case command
    case agent
    case brewPackage
    case configuration

    /// Convert to the internal `ComponentType`.
    var componentType: ComponentType {
        switch self {
        case .mcpServer: .mcpServer
        case .plugin: .plugin
        case .skill: .skill
        case .hookFile: .hookFile
        case .command: .command
        case .agent: .agent
        case .brewPackage: .brewPackage
        case .configuration: .configuration
        }
    }
}

// MARK: - Install Actions

/// String-backed install action type discriminator for YAML serialization.
enum ExternalInstallActionType: String, Codable {
    case mcpServer
    case plugin
    case brewInstall
    case shellCommand
    case gitignoreEntries
    case settingsMerge
    case settingsFile
    case copyPackFile
}

/// Declarative install action types that can be expressed in YAML.
enum ExternalInstallAction: Codable, Equatable {
    case mcpServer(ExternalMCPServerConfig)
    case plugin(name: String)
    case brewInstall(package: String)
    case shellCommand(command: String, interactive: Bool = false)
    case gitignoreEntries(entries: [String])
    case settingsMerge
    case settingsFile(source: String)
    case copyPackFile(ExternalCopyPackFileConfig)

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case package
        case command
        case interactive
        case args
        case env
        case transport
        case url
        case scope
        case entries
        case source
        case destination
        case fileType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actionType = try container.decode(ExternalInstallActionType.self, forKey: .type)

        switch actionType {
        case .mcpServer:
            let config = try ExternalMCPServerConfig(from: decoder)
            self = .mcpServer(config)
        case .plugin:
            let name = try container.decode(String.self, forKey: .name)
            self = .plugin(name: name)
        case .brewInstall:
            let package = try container.decode(String.self, forKey: .package)
            self = .brewInstall(package: package)
        case .shellCommand:
            let command = try container.decode(String.self, forKey: .command)
            let interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive) ?? false
            self = .shellCommand(command: command, interactive: interactive)
        case .gitignoreEntries:
            let entries = try container.decode([String].self, forKey: .entries)
            self = .gitignoreEntries(entries: entries)
        case .settingsMerge:
            self = .settingsMerge
        case .settingsFile:
            let source = try container.decode(String.self, forKey: .source)
            self = .settingsFile(source: source)
        case .copyPackFile:
            let config = try ExternalCopyPackFileConfig(from: decoder)
            self = .copyPackFile(config)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .mcpServer(config):
            try container.encode(ExternalInstallActionType.mcpServer, forKey: .type)
            try config.encode(to: encoder)
        case let .plugin(name):
            try container.encode(ExternalInstallActionType.plugin, forKey: .type)
            try container.encode(name, forKey: .name)
        case let .brewInstall(package):
            try container.encode(ExternalInstallActionType.brewInstall, forKey: .type)
            try container.encode(package, forKey: .package)
        case let .shellCommand(command, interactive):
            try container.encode(ExternalInstallActionType.shellCommand, forKey: .type)
            try container.encode(command, forKey: .command)
            if interactive {
                try container.encode(interactive, forKey: .interactive)
            }
        case let .gitignoreEntries(entries):
            try container.encode(ExternalInstallActionType.gitignoreEntries, forKey: .type)
            try container.encode(entries, forKey: .entries)
        case .settingsMerge:
            try container.encode(ExternalInstallActionType.settingsMerge, forKey: .type)
        case let .settingsFile(source):
            try container.encode(ExternalInstallActionType.settingsFile, forKey: .type)
            try container.encode(source, forKey: .source)
        case let .copyPackFile(config):
            try container.encode(ExternalInstallActionType.copyPackFile, forKey: .type)
            try config.encode(to: encoder)
        }
    }
}

// MARK: - MCP Server Config

/// Configuration for an MCP server declared in an external pack manifest.
struct ExternalMCPServerConfig: Codable, Equatable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let transport: ExternalTransport?
    let url: String?
    let scope: ExternalScope?

    /// Convert to the internal `MCPServerConfig`.
    func toMCPServerConfig() -> MCPServerConfig {
        if transport == .http, let url {
            return .http(name: name, url: url, scope: scope?.rawValue)
        }
        return MCPServerConfig(
            name: name,
            command: command ?? "",
            args: args ?? [],
            env: env ?? [:],
            scope: scope?.rawValue
        )
    }
}

enum ExternalTransport: String, Codable {
    case stdio
    case http
}

enum ExternalScope: String, Codable {
    case local
    case user
    case project
}

// MARK: - Copy Pack File Config

/// Configuration for copying a file from the pack into the Claude directory.
struct ExternalCopyPackFileConfig: Codable, Equatable {
    let source: String
    let destination: String
    let fileType: ExternalCopyFileType?
}

enum ExternalCopyFileType: String, Codable {
    case skill
    case hook
    case command
    case agent
    case generic
}

// MARK: - Referenced Pack Files

/// Normalize a pack-relative path so equivalent expressions collapse to the same key.
/// Trims whitespace and strips a leading `./` so `hooks/foo.sh`, `./hooks/foo.sh`, and
/// ` hooks/foo.sh` are one path.
///
/// Private so the only way to obtain a pack-relative path is through the `referencedSource` of
/// the declaration that owns it — `ignore:` validation, unreferenced-file linting, and
/// `PackDiff`'s content hashing all key on these strings, and a consumer that normalized
/// differently would silently drop a file from one side of a comparison.
private func normalizedPackPath(_ path: String) -> String {
    var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
    return normalized
}

extension ExternalComponentDefinition {
    /// The pack-relative file this component installs, normalized, or `nil` when the
    /// component's install action copies nothing (brew, MCP, plugin, shell, gitignore).
    var referencedSource: String? {
        switch installAction {
        case let .copyPackFile(config):
            normalizedPackPath(config.source)
        case let .settingsFile(source):
            normalizedPackPath(source)
        case .brewInstall, .gitignoreEntries, .mcpServer, .plugin, .settingsMerge, .shellCommand:
            nil
        }
    }

    /// Whether `source` copies the pack root wholesale (`.`), which would sweep in
    /// `techpack.yaml`, `LICENSE`, and `README`.
    var copiesPackRoot: Bool {
        guard case let .copyPackFile(config) = installAction else { return false }
        let normalized = normalizedPackPath(config.source)
        return normalized.isEmpty || normalized == "."
    }
}

extension ExternalTemplateDefinition {
    /// The pack-relative content file backing this template section, normalized.
    var referencedSource: String {
        normalizedPackPath(contentFile)
    }
}

extension ExternalConfigureProject {
    /// The pack-relative configure script, normalized.
    var referencedSource: String {
        normalizedPackPath(script)
    }
}

extension ExternalPackManifest {
    /// Every pack-relative path this manifest declares, normalized.
    ///
    /// Lives on the manifest because it is a property of what the pack declares, not a quality
    /// heuristic: `validate()` rejects `ignore:` entries that would mask one of these,
    /// `PackHeuristics` reports the files that are *not* here, and `PackSnapshot` hashes them.
    var referencedPaths: Set<String> {
        var paths = Set<String>()
        for component in components ?? [] {
            if let source = component.referencedSource {
                paths.insert(source)
            }
        }
        for template in templates ?? [] {
            paths.insert(template.referencedSource)
        }
        if let configureProject {
            paths.insert(configureProject.referencedSource)
        }
        return paths
    }
}

// MARK: - Templates

/// A template contribution declared in an external pack manifest.
struct ExternalTemplateDefinition: Codable, Equatable {
    var sectionIdentifier: String
    let placeholders: [String]?
    let contentFile: String
    var dependencies: [String]?
}

// MARK: - Configure Project

/// Script-based project configuration hook.
struct ExternalConfigureProject: Codable, Equatable {
    let script: String
}

// MARK: - Doctor Checks

/// A declarative doctor check definition for external packs.
struct ExternalDoctorCheckDefinition: Codable, Equatable {
    let type: ExternalDoctorCheckType
    let name: String
    let section: String?
    /// Meaning depends on `type`: the binary for `commandExists`, the script path for
    /// `shellScript`, a hook-command substring for `hookEventExists`.
    let command: String?
    let args: [String]?
    let path: String?
    let pattern: String?
    let scope: ExternalDoctorCheckScope?
    let fixCommand: String?
    let fixScript: String?
    let event: String?
    /// `hookEventExists` only — the exact matcher a hook group under `event` must carry.
    let matcher: String?
    let keyPath: String?
    let expectedValue: String?
    let isOptional: Bool?

    /// Written out rather than synthesized so optional fields carry `nil` defaults. Swift gives a
    /// `let` optional no default in the memberwise init, so every added field would otherwise have
    /// to be threaded through all 12 construction sites.
    init(
        type: ExternalDoctorCheckType,
        name: String,
        section: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        path: String? = nil,
        pattern: String? = nil,
        scope: ExternalDoctorCheckScope? = nil,
        fixCommand: String? = nil,
        fixScript: String? = nil,
        event: String? = nil,
        matcher: String? = nil,
        keyPath: String? = nil,
        expectedValue: String? = nil,
        isOptional: Bool? = nil
    ) {
        self.type = type
        self.name = name
        self.section = section
        self.command = command
        self.args = args
        self.path = path
        self.pattern = pattern
        self.scope = scope
        self.fixCommand = fixCommand
        self.fixScript = fixScript
        self.event = event
        self.matcher = matcher
        self.keyPath = keyPath
        self.expectedValue = expectedValue
        self.isOptional = isOptional
    }
}

enum ExternalDoctorCheckType: String, Codable, CaseIterable {
    case commandExists
    case fileExists
    case directoryExists
    case fileContains
    case fileNotContains
    case shellScript
    case hookEventExists
    case settingsKeyEquals

    /// Whether `scope` affects this check.
    ///
    /// `scope` selects the base directory for an author-supplied `path`, so it only means
    /// something for the path-based checks. The others either take no path (`hookEventExists`,
    /// `settingsKeyEquals` — the settings file is implied and resolved from the project root) or
    /// run a command (`commandExists`, `shellScript`). `mcs pack validate` warns when a pack
    /// declares `scope` on a type that ignores it.
    ///
    /// `ExternalDoctorCheckFactory.makeCheck` is the ground truth — only the checks it builds as
    /// `ScopedPathCheck` consume `scope`. `ExternalDoctorCheckTests.honorsScopeMatchesFactory`
    /// asserts this property agrees with the factory for every case, so the two cannot drift.
    var honorsScope: Bool {
        switch self {
        case .fileExists, .directoryExists, .fileContains, .fileNotContains:
            true
        case .commandExists, .shellScript, .hookEventExists, .settingsKeyEquals:
            false
        }
    }
}

enum ExternalDoctorCheckScope: String, Codable {
    case global
    case project
}
