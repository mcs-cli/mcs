import Foundation

/// Registry of all available tech packs loaded from external pack sources.
struct TechPackRegistry {
    static let shared = TechPackRegistry()

    private let packs: [any TechPack]

    /// Identifiers present in `registry.yaml`, whether or not they produced a pack. A pack in
    /// this set but absent from `packs` failed to load; one in neither is not installed at all.
    private let registeredPackIDs: Set<String>

    init(packs: [any TechPack] = [], registeredPackIDs: Set<String>? = nil) {
        self.packs = packs
        self.registeredPackIDs = registeredPackIDs ?? Set(packs.map(\.identifier))
    }

    /// All registered packs sorted by identifier.
    var availablePacks: [any TechPack] {
        packs.sorted { $0.identifier < $1.identifier }
    }

    /// Identifiers of the packs that loaded. Unsorted — callers wanting order sort at the edge.
    var availablePackIDs: Set<String> {
        Set(packs.map(\.identifier))
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

        // Registered identifiers are read even when nothing loaded, so callers can still tell a
        // pack that failed to load from one that was never installed.
        var registered: Set<String>
        do {
            registered = try Set(packRegistryFile.load().packs.map(\.identifier))
        } catch {
            output.warn("Could not read the pack registry: \(error.localizedDescription)")
            registered = Set(adapters.map(\.identifier))
        }

        return TechPackRegistry(packs: adapters, registeredPackIDs: registered)
    }

    /// Packs a scope has configured that are registered but failed to load — an entry exists in
    /// `registry.yaml`, yet no adapter came back (trust verification, invalid manifest, missing
    /// checkout, incompatible `minMCSVersion`; `loadAll` has already printed which).
    ///
    /// Callers must not hand these to `Configurator.configure`. It treats its pack list as the
    /// complete desired state and unconfigures whatever is missing, so a pack that merely failed
    /// to load reads as "the user deselected this" and has its artifacts deleted.
    ///
    /// A pack with **no** registry entry is deliberately excluded: it is genuinely absent, so
    /// converging it away is the intended repair rather than data loss. (It would also be
    /// unremovable otherwise — `mcs pack remove` refuses an identifier missing from the registry.)
    func unloadableConfiguredPacks(configured: Set<String>) -> [String] {
        configured.intersection(registeredPackIDs).subtracting(availablePackIDs).sorted()
    }
}
