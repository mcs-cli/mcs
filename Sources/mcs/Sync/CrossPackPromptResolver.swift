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
        var byKey: [String: [PackPromptInfo]] = [:]
        let alreadyResolved = Set(context.resolvedValues.keys)

        for pack in packs {
            for prompt in pack.declaredPrompts(context: context) {
                guard deduplicableTypes.contains(prompt.type) else { continue }
                guard !alreadyResolved.contains(prompt.key) else { continue }
                byKey[prompt.key, default: []].append(
                    PackPromptInfo(packName: pack.displayName, prompt: prompt)
                )
            }
        }

        // Only return keys shared by 2+ packs
        return byKey.filter { $0.value.count > 1 }
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
        priorValues: [String: String] = [:]
    ) -> [String: String] {
        var resolved: [String: String] = [:]

        for key in shared.keys.sorted() {
            guard let infos = shared[key], !infos.isEmpty else { continue }

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
                let initialIndex = PromptOption.index(of: prior, in: mergedOptions)
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

        return resolved
    }
}
