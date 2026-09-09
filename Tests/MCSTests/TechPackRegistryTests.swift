import Foundation
@testable import mcs
import Testing

struct TechPackRegistryTests {
    // MARK: - Basic registry

    @Test("Shared registry has no packs")
    func sharedIsEmpty() {
        let packs = TechPackRegistry.shared.availablePacks
        #expect(packs.isEmpty)
    }

    @Test("Find pack by identifier returns nil for unknown")
    func findByIdentifierUnknown() {
        let result = TechPackRegistry.shared.pack(for: "nonexistent")
        #expect(result == nil)
    }

    // MARK: - Filtered by installed packs

    @Test("supplementaryDoctorChecks returns empty when no packs installed")
    func supplementaryDoctorChecksEmpty() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: [], projectRoot: nil)
        #expect(checks.isEmpty)
    }

    @Test("supplementaryDoctorChecks ignores unrecognized pack identifiers")
    func supplementaryDoctorChecksUnknownPack() {
        let checks = TechPackRegistry.shared.supplementaryDoctorChecks(installedPacks: ["nonexistent"], projectRoot: nil)
        #expect(checks.isEmpty)
    }

    // MARK: - Template contributions

    @Test("templateContributions returns templates for registered pack")
    func templateContributions() throws {
        let template = TemplateContribution(
            sectionIdentifier: "test",
            templateContent: "Test content __NAME__",
            placeholders: ["__NAME__"]
        )
        let fakePack = FakeTechPack(identifier: "test-pack", templates: [template])
        let registry = TechPackRegistry(packs: [fakePack])
        let templates = try registry.templateContributions(for: "test-pack")
        #expect(!templates.isEmpty)
        #expect(templates.first?.sectionIdentifier == "test")
    }

    @Test("templateContributions returns empty for unknown pack")
    func templateContributionsUnknown() throws {
        let templates = try TechPackRegistry.shared.templateContributions(for: "android")
        #expect(templates.isEmpty)
    }

    // MARK: - Packs

    @Test("Packs appear in availablePacks")
    func packsAppear() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry(packs: [fakePack])
        let ids = registry.availablePacks.map(\.identifier)
        #expect(ids.contains("android"))
    }

    @Test("Find pack by identifier")
    func findByIdentifier() {
        let fakePack = FakeTechPack(identifier: "android")
        let registry = TechPackRegistry(packs: [fakePack])
        let found = registry.pack(for: "android")
        #expect(found != nil)
        #expect(found?.displayName == "Fake Pack")
    }

    @Test("Pack components included in allPackComponents")
    func packComponents() {
        let component = ComponentDefinition(
            id: "ext.comp",
            displayName: "Ext Comp",
            description: "An external component",
            type: .configuration,
            packIdentifier: "ext",
            dependencies: [],
            isRequired: false,
            installAction: .shellCommand(command: "echo")
        )
        let fakePack = FakeTechPack(
            identifier: "ext",
            components: [component]
        )
        let registry = TechPackRegistry(packs: [fakePack])
        let allIDs = registry.allPackComponents.map(\.id)
        #expect(allIDs.contains("ext.comp"))
    }

    @Test("Registry with empty packs has no available packs")
    func emptyPacks() {
        let registry = TechPackRegistry(packs: [])
        #expect(registry.availablePacks.isEmpty)
    }

    @Test("supplementaryDoctorChecks returns checks for registered pack")
    func supplementaryDoctorChecksWithPack() {
        let check = BrewPackageCheck(name: "test-check", section: "Dependencies", package: "test")
        let fakePack = FakeTechPack(
            identifier: "test-pack",
            supplementaryDoctorChecks: [check]
        )
        let registry = TechPackRegistry(packs: [fakePack])
        let checks = registry.supplementaryDoctorChecks(installedPacks: ["test-pack"], projectRoot: nil)
        #expect(!checks.isEmpty)
        #expect(checks.first?.name == "test-check")
    }

    // MARK: - unloadableConfiguredPacks

    @Test("A registered pack that did not load is reported as unloadable")
    func unloadableReportsRegisteredButNotLoaded() {
        // pack-b is in `registry.yaml` but produced no adapter — trust verification, an invalid
        // manifest, or a missing checkout, all of which `loadAll` warned about and skipped.
        let registry = TechPackRegistry(
            packs: [FakeTechPack(identifier: "pack-a")],
            registeredPackIDs: ["pack-a", "pack-b"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a", "pack-b"]) == ["pack-b"])
    }

    @Test("A configured pack with no registry entry is not reported as unloadable")
    func unloadableExcludesUnregisteredPack() {
        // `ghost-pack` is in project state but not installed at all, so converging it away is the
        // intended repair — and `mcs pack remove` could not clean it up if it were retained.
        let registry = TechPackRegistry(
            packs: [FakeTechPack(identifier: "pack-a")],
            registeredPackIDs: ["pack-a"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a", "ghost-pack"]).isEmpty)
    }

    @Test("Everything loading cleanly reports nothing")
    func unloadableEmptyWhenAllLoaded() {
        let registry = TechPackRegistry(
            packs: [FakeTechPack(identifier: "pack-a")],
            registeredPackIDs: ["pack-a"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a"]).isEmpty)
    }
}

// MARK: - Test Helper

private struct FakeTechPack: TechPack {
    let identifier: String
    let displayName: String = "Fake Pack"
    let description: String = "A fake pack for testing"
    let components: [ComponentDefinition]
    let templates: [TemplateContribution]
    private let storedChecks: [any DoctorCheck]

    init(
        identifier: String,
        components: [ComponentDefinition] = [],
        templates: [TemplateContribution] = [],
        supplementaryDoctorChecks: [any DoctorCheck] = []
    ) {
        self.identifier = identifier
        self.components = components
        self.templates = templates
        storedChecks = supplementaryDoctorChecks
    }

    func supplementaryDoctorChecks(projectRoot _: URL?) -> [any DoctorCheck] {
        storedChecks
    }

    func configureProject(at _: URL, context _: ProjectConfigContext) throws {}
}
