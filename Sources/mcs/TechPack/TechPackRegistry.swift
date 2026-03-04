import Foundation

/// Registry of all available tech packs loaded from external pack sources.
struct TechPackRegistry {
    static let shared = TechPackRegistry()

    private let packs: [any TechPack]

    init(packs: [any TechPack] = []) {
        self.packs = packs
    }

    /// All registered packs sorted by identifier.
    var availablePacks: [any TechPack] {
        packs.sorted { $0.identifier < $1.identifier }
    }

    /// Find a pack by identifier.
    func pack(for identifier: String) -> (any TechPack)? {
        packs.first { $0.identifier == identifier }
    }

    /// Get all components from all packs.
    var allPackComponents: [ComponentDefinition] {
        availablePacks.flatMap(\.components)
    }

    /// Get supplementary doctor checks only for installed packs.
    /// These are pack-level checks that cannot be auto-derived from components.
    func supplementaryDoctorChecks(installedPacks ids: Set<String>, projectRoot: URL?) -> [any DoctorCheck] {
        availablePacks.filter { ids.contains($0.identifier) }
            .flatMap { $0.supplementaryDoctorChecks(projectRoot: projectRoot) }
    }

    /// Get template contributions for a specific pack.
    func templateContributions(for packIdentifier: String) throws -> [TemplateContribution] {
        try pack(for: packIdentifier)?.templates ?? []
    }

    /// Create a registry from external packs loaded from disk.
    /// This is the primary entry point for command-level code.
    static func loadWithExternalPacks(
        environment: Environment,
        output: CLIOutput
    ) -> TechPackRegistry {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let loader = ExternalPackLoader(environment: environment, registry: packRegistryFile)
        let adapters = loader.loadAll(output: output)
        if adapters.isEmpty {
            return .shared
        }
        return TechPackRegistry(packs: adapters)
    }
}
