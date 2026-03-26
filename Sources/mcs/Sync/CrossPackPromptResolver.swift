import Foundation

/// Collects prompt definitions from multiple packs, identifies shared keys,
/// and executes shared prompts once with a combined display showing each pack's label.
///
/// Only `input` and `select` prompt types are eligible for deduplication.
/// `script` and `fileDetect` types are pack-specific and always run per-pack.
enum CrossPackPromptResolver {
    /// A prompt definition paired with the pack that declares it.
    struct PackPromptInfo {
        let packName: String
        let prompt: PromptDefinition
    }

    /// Prompt types eligible for cross-pack deduplication.
    static let deduplicableTypes: Set<PromptType> = [.input, .select]

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
    /// - Returns: Resolved values for all shared prompt keys.
    static func resolveSharedPrompts(
        _ shared: [String: [PackPromptInfo]],
        output: CLIOutput
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

            // Use the first non-nil default value
            let defaultValue = infos.compactMap(\.prompt.defaultValue).first

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
                    resolved[key] = defaultValue ?? ""
                    continue
                }
                let items = mergedOptions.map { (name: $0.label, description: $0.value) }
                let label = "Select value for \(key)"
                let selected = output.singleSelect(title: label, items: items)
                resolved[key] = mergedOptions[selected].value
            } else {
                // Default to text input
                let value = output.promptInline("  Enter value for \(key)", default: defaultValue)
                resolved[key] = value
            }
        }

        return resolved
    }
}
