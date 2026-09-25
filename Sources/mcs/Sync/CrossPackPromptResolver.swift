import Foundation

/// Collects prompt definitions from multiple packs, identifies shared keys,
/// and executes shared prompts once with a combined display showing each pack's label.
///
/// Only `input` and `select` prompt types are eligible for deduplication; `script` and
/// `fileDetect` are pack-specific and always resolve per-pack. Per-pack is not per-sync:
/// a `fileDetect` prior that `partitionDeclaredPrompts` accepts skips the executor entirely.
enum CrossPackPromptResolver {
    /// A prompt definition paired with the pack that declares it.
    struct PackPromptInfo {
        /// Identity of the declaring pack; display names need not be unique.
        let packID: String
        let packName: String
        let prompt: PromptDefinition
    }

    /// Prompt types eligible for cross-pack deduplication.
    static let deduplicableTypes: Set<PromptType> = [.input, .select]

    /// Prompt types whose prior value can survive into the next sync. `script` is absent
    /// because its value is computed, not answered — re-running it costs the user nothing.
    static let reusableTypes: Set<PromptType> = [.input, .select, .fileDetect]

    /// Prompt types whose resolved value is safe to print back to the user. Only types the pack
    /// resolves by scanning: everything a user typed is treated as potentially secret.
    static let visibleValueTypes: Set<PromptType> = [.fileDetect]

    /// Flat list of every declaration from every pack. Multiple packs can declare
    /// the same key — `partitionDeclaredPrompts` groups them when merging select options.
    static func collectDeclaredPrompts(
        packs: [any TechPack],
        context: ProjectConfigContext
    ) -> [PromptDefinition] {
        packs.flatMap { $0.declaredPrompts(context: context) }
    }

    /// Every value key a pack set consumes: its declared prompts, plus the `__KEY__`
    /// placeholders its artifacts reference without a prompt declaring them.
    struct ConsumedKeys {
        let declared: [PromptDefinition]
        let undeclared: Set<String>

        var all: Set<String> {
            undeclared.union(declared.map(\.key))
        }
    }

    static func consumedKeys(
        packs: [any TechPack],
        context: ProjectConfigContext,
        includeTemplates: Bool,
        onWarning: ((String) -> Void)? = nil
    ) -> ConsumedKeys {
        let declared = collectDeclaredPrompts(packs: packs, context: context)
        let referenced = ConfiguratorSupport.referencedPlaceholderKeys(
            packs: packs,
            includeTemplates: includeTemplates,
            onWarning: onWarning
        )
        return ConsumedKeys(declared: declared, undeclared: referenced.subtracting(declared.map(\.key)))
    }

    /// Partition declared prompts against `priorValues`.
    ///
    /// `script` keys are excluded from both outputs — they always re-execute and must
    /// not trigger the "new prompts" UX branch.
    ///
    /// Select priors are reusable when:
    /// - no declaration constrains the value (all have nil/empty options — the executor
    ///   falls back to free-form input), OR
    /// - at least one declaration constrains via `options` AND the prior is in the
    ///   merged set of constrained options.
    ///
    /// Conservative rule for mixed declarations: when any pack constrains the value,
    /// the prior must satisfy those constraints (matches `resolveSharedPrompts` which
    /// presents the merged constrained option list to the user).
    ///
    /// `fileDetect` priors are reusable only when this run's scan still finds the stored
    /// file: the scan stays dynamic, but a project that hasn't changed stops re-asking.
    /// An empty scan re-asks, mirroring the executor's zero-match branch, which prompts.
    ///
    /// Type conflicts across packs (input vs select) fall back to input semantics.
    ///
    /// - Parameter projectPath: Directory the `fileDetect` patterns are scanned in.
    static func partitionDeclaredPrompts(
        _ prompts: [PromptDefinition],
        priorValues: [String: String],
        projectPath: URL
    ) -> (reusableValues: [String: String], newDeclaredKeys: Set<String>) {
        var constrainedOptionsByKey: [String: Set<String>] = [:]
        var detectedFilesByKey: [String: Set<String>] = [:]
        for prompt in prompts {
            if prompt.type == .select, let options = prompt.options, !options.isEmpty {
                constrainedOptionsByKey[prompt.key, default: []].formUnion(options.map(\.value))
            }
            // Only a prior can be validated against the scan, so a key without one skips it.
            if prompt.type == .fileDetect, priorValues[prompt.key] != nil {
                let detected = PromptExecutor.detectFiles(
                    matching: prompt.detectPatterns ?? ["*"], in: projectPath
                )
                detectedFilesByKey[prompt.key, default: []].formUnion(detected)
            }
        }

        var reusable: [String: String] = [:]
        var newKeys: Set<String> = []
        for (key, types) in typesByKey(in: prompts) {
            let answerableTypes = types.intersection(reusableTypes)
            guard !answerableTypes.isEmpty else { continue }

            guard let prior = priorValues[key] else {
                newKeys.insert(key)
                continue
            }

            let constrained = constrainedOptionsByKey[key] ?? []
            let permitted: Bool = if answerableTypes.contains(.input) {
                true
            } else if answerableTypes.contains(.fileDetect) {
                detectedFilesByKey[key, default: []].contains(prior)
            } else {
                // No constraints → free-form; any constraint → prior must satisfy it.
                constrained.isEmpty || constrained.contains(prior)
            }

            if permitted {
                reusable[key] = prior
            } else {
                newKeys.insert(key)
            }
        }
        return (reusable, newKeys)
    }

    /// Where every value resolution starts: the keys a pack set consumes, partitioned against
    /// the priors. Sync and the non-interactive preflight both build it here, so they cannot
    /// disagree about which keys exist or which priors survive.
    struct ValuePlan {
        let declared: [PromptDefinition]
        /// `__KEY__` placeholders no prompt declares, less the keys already in `context.resolvedValues`.
        let undeclaredKeys: Set<String>
        let reusableValues: [String: String]
        let newKeys: Set<String>
    }

    static func planValues(
        packs: [any TechPack],
        context: ProjectConfigContext,
        includeTemplates: Bool,
        onWarning: ((String) -> Void)? = nil
    ) -> ValuePlan {
        let consumed = consumedKeys(
            packs: packs, context: context, includeTemplates: includeTemplates, onWarning: onWarning
        )
        let undeclaredKeys = consumed.undeclared.subtracting(context.resolvedValues.keys)
        // Nothing constrains an undeclared placeholder's value, so it partitions as `input`.
        let placeholderPrompts = undeclaredKeys.map {
            PromptDefinition(
                key: $0, type: .input,
                label: nil, defaultValue: nil, options: nil,
                detectPatterns: nil, scriptCommand: nil
            )
        }
        let (reusable, newKeys) = partitionDeclaredPrompts(
            consumed.declared + placeholderPrompts,
            priorValues: context.priorValues,
            projectPath: context.projectPath
        )
        return ValuePlan(
            declared: consumed.declared, undeclaredKeys: undeclaredKeys,
            reusableValues: reusable, newKeys: newKeys
        )
    }

    /// Every value a run without an interactive stdin will store, and every key it can't answer.
    /// Replays sync's stages in sync's order, with `PromptExecutor.nonInteractiveValue` standing
    /// in for each reader: reused priors when `reusesPriors`, then shared prompts, then each
    /// pack in order for the keys still open, then undeclared placeholders from their prior.
    /// A key a pack computes by `script` is claimed by that pack and left to its script.
    static func resolveNonInteractively(
        packs: [any TechPack],
        context: ProjectConfigContext,
        plan: ValuePlan,
        reusesPriors: Bool,
        includeTemplates: Bool
    ) -> (resolved: [String: String], unresolved: [UnresolvedPrompt]) {
        let priors = context.priorValues
        var answered = context.resolvedValues
        var resolved: [String: String] = [:]
        var claimed = Set<String>()
        var unresolved: [UnresolvedPrompt] = []

        func answer(_ key: String, _ value: String) {
            answered[key] = value
            resolved[key] = value
        }

        if reusesPriors {
            for (key, value) in plan.reusableValues where answered[key] == nil {
                answer(key, value)
            }
        }

        let sharedContext = ProjectConfigContext(
            projectPath: context.projectPath, repoName: context.repoName, output: context.output,
            resolvedValues: answered, priorValues: priors, isGlobalScope: context.isGlobalScope
        )
        let shared = groupSharedPrompts(packs: packs, context: sharedContext)
        for key in shared.keys.sorted() {
            let infos = shared[key, default: []]
            claimed.insert(key)
            if let value = PromptExecutor.nonInteractiveValue(
                declarations: infos.map(\.prompt), prior: priors[key], projectPath: context.projectPath
            ) {
                answer(key, value)
            } else {
                unresolved.append(UnresolvedPrompt(packNames: infos.map(\.packName), key: key))
            }
        }

        for pack in packs {
            let open = pack.declaredPrompts(context: context)
                .filter { answered[$0.key] == nil && !claimed.contains($0.key) }
            var seen = Set<String>()
            for key in open.map(\.key) where seen.insert(key).inserted {
                claimed.insert(key)
                let declarations = open.filter { $0.key == key }
                guard !declarations.contains(where: { $0.type == .script }) else { continue }
                if let value = PromptExecutor.nonInteractiveValue(
                    declarations: declarations, prior: priors[key], projectPath: context.projectPath
                ) {
                    answer(key, value)
                } else {
                    unresolved.append(UnresolvedPrompt(packNames: [pack.displayName], key: key))
                }
            }
        }

        let missing = plan.undeclaredKeys.filter { answered[$0] == nil && !claimed.contains($0) }
        for key in missing {
            if let prior = priors[key] { answer(key, prior) }
        }
        let stillMissing = Set(missing.filter { answered[$0] == nil })
        if !stillMissing.isEmpty {
            // Only on failure: naming who references a key costs a scan per pack.
            var referencing: [String: [String]] = [:]
            for pack in packs {
                let referenced = ConfiguratorSupport.referencedPlaceholderKeys(
                    packs: [pack], includeTemplates: includeTemplates
                )
                for key in referenced.intersection(stillMissing) {
                    referencing[key, default: []].append(pack.displayName)
                }
            }
            unresolved += stillMissing.map { UnresolvedPrompt(packNames: referencing[$0, default: []], key: $0) }
        }

        return (resolved, unresolved.sorted { $0.key < $1.key })
    }

    /// Keys whose value every declaring pack resolves by scanning, per `visibleValueTypes`.
    /// A key any pack declares as another type stays hidden — the same conservative rule the
    /// reuse partition applies to mixed declarations.
    static func visibleValueKeys(in prompts: [PromptDefinition]) -> Set<String> {
        Set(typesByKey(in: prompts).filter { $0.value.isSubset(of: visibleValueTypes) }.keys)
    }

    /// Every type each key is declared as, across all packs.
    private static func typesByKey(in prompts: [PromptDefinition]) -> [String: Set<PromptType>] {
        var typesByKey: [String: Set<PromptType>] = [:]
        for prompt in prompts {
            typesByKey[prompt.key, default: []].insert(prompt.type)
        }
        return typesByKey
    }

    /// Collect prompts from all packs and group by key, skipping already-resolved keys.
    ///
    /// - Returns: A dictionary keyed by prompt key, with each value being the list
    ///   of packs that declare that key (only for deduplicable types, 2+ packs).
    static func groupSharedPrompts(
        packs: [any TechPack],
        context: ProjectConfigContext
    ) -> [String: [PackPromptInfo]] {
        promptInfosByKey(packs: packs, context: context)
            .mapValues { $0.filter { deduplicableTypes.contains($0.prompt.type) } }
            .filter { $0.value.count > 1 }
    }

    /// Every declaration of every key not yet in `context.resolvedValues`, in pack order.
    private static func promptInfosByKey(
        packs: [any TechPack],
        context: ProjectConfigContext
    ) -> [String: [PackPromptInfo]] {
        var byKey: [String: [PackPromptInfo]] = [:]
        for pack in packs {
            for prompt in pack.declaredPrompts(context: context) where context.resolvedValues[prompt.key] == nil {
                byKey[prompt.key, default: []].append(PackPromptInfo(packID: pack.identifier, packName: pack.displayName, prompt: prompt))
            }
        }
        return byKey
    }

    /// Execute shared prompts once, showing a combined label from all packs.
    ///
    /// - Parameter priorValues: Values from a previous sync; used as the default
    ///   when present, overriding pack-declared defaults. For `select` prompts,
    ///   a prior value only applies when it still matches a merged option.
    /// - Returns: Resolved values for all shared prompt keys.
    static func resolveSharedPrompts(
        _ shared: [String: [PackPromptInfo]],
        output: CLIOutput,
        priorValues: [String: String] = [:],
        projectPath: URL,
        isGlobalScope: Bool
    ) throws -> [String: String] {
        var resolved: [String: String] = [:]
        var unresolved: [UnresolvedPrompt] = []

        for key in shared.keys.sorted() {
            guard let infos = shared[key], !infos.isEmpty else { continue }

            if !output.hasInteractiveStdin {
                if let value = PromptExecutor.nonInteractiveValue(
                    declarations: infos.map(\.prompt), prior: priorValues[key], projectPath: projectPath
                ) {
                    resolved[key] = value
                } else {
                    unresolved.append(UnresolvedPrompt(packNames: infos.map(\.packName), key: key))
                }
                continue
            }

            // Display combined prompt header
            let packNames = infos.map(\.packName).joined(separator: ", ")
            output.plain("")
            output.info("\(key) (shared by \(packNames))")

            for info in infos {
                let label = info.prompt.label ?? "(no description)"
                output.dimmed("  \(info.packName): \"\(label)\"")
            }

            // Resolve based on the first prompt's type; warn on type conflicts
            let primaryType = infos[0].prompt.type
            let hasTypeConflict = infos.contains { $0.prompt.type != primaryType }
            if hasTypeConflict {
                let typesByPack = infos.map { "\($0.packName): \($0.prompt.type.rawValue)" }.joined(separator: ", ")
                output.warn("  Type conflict across packs (\(typesByPack)) — falling back to text input")
            }

            // Prior value wins over pack-declared defaults; fall back to first non-nil declared default
            let declaredDefault = infos.compactMap(\.prompt.defaultValue).first
            let prior = priorValues[key]

            if !hasTypeConflict, primaryType == .select {
                // Merge unique options from all packs (first occurrence of each value wins)
                var seenValues = Set<String>()
                var mergedOptions: [PromptOption] = []
                for info in infos {
                    for option in info.prompt.options ?? []
                        where seenValues.insert(option.value).inserted {
                        mergedOptions.append(option)
                    }
                }
                guard !mergedOptions.isEmpty else {
                    output.warn("  Shared select prompt '\(key)' has no options — using default value")
                    resolved[key] = prior ?? declaredDefault ?? ""
                    continue
                }
                let items = mergedOptions.map { (name: $0.label, description: $0.value) }
                let label = "Select value for \(key)"
                let initialIndex = PromptOption.index(of: prior, in: mergedOptions, fallback: declaredDefault)
                let selected = output.singleSelect(title: label, items: items, initialIndex: initialIndex)
                resolved[key] = mergedOptions[selected].value
            } else {
                // Default to text input; prior value seeds the Enter-to-accept default.
                // Mask the hint when the default came from a prior (may hold secrets).
                let effectiveDefault = prior ?? declaredDefault
                let value = output.promptInline(
                    "  Enter value for \(key)",
                    default: effectiveDefault,
                    maskDefault: prior != nil
                )
                resolved[key] = value
            }
        }

        if !unresolved.isEmpty {
            throw PromptResolutionError(unresolved: unresolved, isGlobalScope: isGlobalScope)
        }
        return resolved
    }
}

/// A prompt key no source can answer, with the packs whose declarations failed to answer it.
struct UnresolvedPrompt: Equatable {
    let packNames: [String]
    let key: String
}

/// Raised instead of storing whatever a closed stdin yields. Names keys only: prompt
/// values commonly hold secrets, and this message lands in CI logs.
struct PromptResolutionError: Error, Equatable, LocalizedError {
    let unresolved: [UnresolvedPrompt]
    /// Bootstrap seeds project scope only, so the remedy differs by scope.
    let isGlobalScope: Bool

    var errorDescription: String? {
        lines.joined(separator: "\n")
    }

    var lines: [String] {
        ["Cannot resolve \(unresolved.count) prompt value(s) without an interactive terminal:"]
            + unresolved.map { "  - \($0.packNames.joined(separator: ", ")): \($0.key)" }
            + [isGlobalScope
                ? "Re-run 'mcs sync --global' from a terminal to answer them; later unattended runs reuse the answers."
                : "Declare them under 'values:' in \(BootstrapFile.defaultFilename) and run 'mcs bootstrap',"
                + " or re-run from a terminal."]
    }
}
