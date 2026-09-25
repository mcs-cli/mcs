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

    // MARK: - Packs

    @Test("Packs appear in availablePacks")
    func packsAppear() {
        let fakePack = MockTechPack(identifier: "android", displayName: "Fake Pack")
        let registry = TechPackRegistry(packs: [fakePack])
        let ids = registry.availablePacks.map(\.identifier)
        #expect(ids.contains("android"))
    }

    @Test("Find pack by identifier")
    func findByIdentifier() {
        let fakePack = MockTechPack(identifier: "android", displayName: "Fake Pack")
        let registry = TechPackRegistry(packs: [fakePack])
        let found = registry.pack(for: "android")
        #expect(found != nil)
        #expect(found?.displayName == "Fake Pack")
    }

    // MARK: - unloadableConfiguredPacks

    @Test("A registered pack that did not load is reported as unloadable")
    func unloadableReportsRegisteredButNotLoaded() {
        // pack-b is in `registry.yaml` but produced no adapter — trust verification, an invalid
        // manifest, or a missing checkout, all of which `loadAll` warned about and skipped.
        let registry = TechPackRegistry(
            packs: [MockTechPack(identifier: "pack-a", displayName: "pack-a")],
            registeredPackIDs: ["pack-a", "pack-b"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a", "pack-b"]) == ["pack-b"])
    }

    @Test("A configured pack with no registry entry is not reported as unloadable")
    func unloadableExcludesUnregisteredPack() {
        // `ghost-pack` is in project state but not installed at all, so converging it away is the
        // intended repair — and `mcs pack remove` could not clean it up if it were retained.
        let registry = TechPackRegistry(
            packs: [MockTechPack(identifier: "pack-a", displayName: "pack-a")],
            registeredPackIDs: ["pack-a"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a", "ghost-pack"]).isEmpty)
    }

    @Test("Everything loading cleanly reports nothing")
    func unloadableEmptyWhenAllLoaded() {
        let registry = TechPackRegistry(
            packs: [MockTechPack(identifier: "pack-a", displayName: "pack-a")],
            registeredPackIDs: ["pack-a"]
        )

        #expect(registry.unloadableConfiguredPacks(configured: ["pack-a"]).isEmpty)
    }
}

// MARK: - Test Helper
