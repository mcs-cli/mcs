import Foundation
@testable import mcs
import Testing

struct DependencyResolverTests {
    /// Helper to create a minimal ComponentDefinition for testing.
    private func component(
        id: String,
        dependencies: [String] = []
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: id,
            displayName: id,
            description: "Test component \(id)",
            type: .brewPackage,
            packIdentifier: nil,
            dependencies: dependencies,
            isRequired: false,
            installAction: .shellCommand(command: "echo \(id)")
        )
    }

    // MARK: - Basic resolution

    @Test("Simple direct dependency: A depends on B")
    func simpleDependency() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A"]),
            allComponents: components
        )

        let ids = plan.orderedComponents.map(\.id)
        #expect(ids == ["B", "A"])
    }

    @Test("Transitive dependencies: A -> B -> C")
    func transitiveDependencies() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B", dependencies: ["C"]),
            component(id: "C"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A"]),
            allComponents: components
        )

        let ids = plan.orderedComponents.map(\.id)
        #expect(ids == ["C", "B", "A"])
    }

    // MARK: - Deduplication

    @Test("No duplicates when multiple components share a dependency")
    func noDuplicates() throws {
        let components = [
            component(id: "A", dependencies: ["C"]),
            component(id: "B", dependencies: ["C"]),
            component(id: "C"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A", "B"]),
            allComponents: components
        )

        let ids = plan.orderedComponents.map(\.id)
        // C should appear exactly once
        #expect(ids.count(where: { $0 == "C" }) == 1)
        // All three should be present
        #expect(Set(ids) == Set(["A", "B", "C"]))
    }

    // MARK: - Ordering

    @Test("Dependencies come before dependents")
    func dependenciesBeforeDependents() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B", dependencies: ["C"]),
            component(id: "C"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A"]),
            allComponents: components
        )

        let ids = plan.orderedComponents.map(\.id)
        let indexOfA = try #require(ids.firstIndex(of: "A"))
        let indexOfB = try #require(ids.firstIndex(of: "B"))
        let indexOfC = try #require(ids.firstIndex(of: "C"))

        #expect(indexOfC < indexOfB)
        #expect(indexOfB < indexOfA)
    }

    // MARK: - Circular dependency

    @Test("Circular dependency throws error")
    func circularDependency() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B", dependencies: ["A"]),
        ]

        #expect(throws: (any Error).self) {
            try DependencyResolver.resolve(
                selectedIDs: Set(["A"]),
                allComponents: components
            )
        }
    }

    @Test("Self-referencing dependency throws error")
    func selfDependency() throws {
        let components = [
            component(id: "A", dependencies: ["A"]),
        ]

        #expect(throws: (any Error).self) {
            try DependencyResolver.resolve(
                selectedIDs: Set(["A"]),
                allComponents: components
            )
        }
    }

    // MARK: - Empty / no-dependency cases

    @Test("Empty selection produces empty result")
    func emptySelection() throws {
        let components = [component(id: "A")]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set([]),
            allComponents: components
        )

        #expect(plan.orderedComponents.isEmpty)
    }

    @Test("Components with no dependencies resolve to just themselves")
    func noDependencies() throws {
        let components = [
            component(id: "A"),
            component(id: "B"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A", "B"]),
            allComponents: components
        )

        let ids = Set(plan.orderedComponents.map(\.id))
        #expect(ids == Set(["A", "B"]))
        #expect(plan.addedDependencies.isEmpty)
    }

    // MARK: - Added dependencies tracking

    @Test("Auto-added dependencies are tracked separately")
    func addedDependenciesTracked() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A"]),
            allComponents: components
        )

        // B was not in the selection, so it should be in addedDependencies
        let addedIDs = plan.addedDependencies.map(\.id)
        #expect(addedIDs.contains("B"))
    }

    @Test("Unknown component ID throws error")
    func unknownComponentID() throws {
        let components = [
            component(id: "A", dependencies: ["nonexistent"]),
        ]

        #expect(throws: (any Error).self) {
            try DependencyResolver.resolve(
                selectedIDs: Set(["A"]),
                allComponents: components
            )
        }
    }

    @Test("Unknown selected ID throws error")
    func unknownSelectedID() throws {
        let components = [component(id: "A")]

        #expect(throws: (any Error).self) {
            try DependencyResolver.resolve(
                selectedIDs: Set(["nonexistent"]),
                allComponents: components
            )
        }
    }

    @Test("Explicitly selected dependencies are not in addedDependencies")
    func explicitDepsNotAdded() throws {
        let components = [
            component(id: "A", dependencies: ["B"]),
            component(id: "B"),
        ]

        let plan = try DependencyResolver.resolve(
            selectedIDs: Set(["A", "B"]),
            allComponents: components
        )

        // B was explicitly selected, so it should NOT be in addedDependencies
        let addedIDs = plan.addedDependencies.map(\.id)
        #expect(!addedIDs.contains("B"))
    }
}
