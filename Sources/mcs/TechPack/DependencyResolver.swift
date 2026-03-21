import Foundation

enum DependencyResolver {
    struct ResolvedPlan {
        let orderedComponents: [ComponentDefinition]
        let addedDependencies: [ComponentDefinition] // Auto-added deps not in original selection
    }

    /// Resolve dependencies for selected component IDs and return installation order
    static func resolve(
        selectedIDs: Set<String>,
        allComponents: [ComponentDefinition]
    ) throws -> ResolvedPlan {
        // Build map safely — last definition wins if there are duplicate IDs
        var componentMap: [String: ComponentDefinition] = [:]
        for component in allComponents {
            componentMap[component.id] = component
        }

        var resolved: [String] = []
        var visited: Set<String> = []
        var inStack: Set<String> = [] // For cycle detection
        var addedDeps: Set<String> = []

        func visit(_ id: String) throws {
            if resolved.contains(id) { return }
            if inStack.contains(id) {
                throw MCSError.invalidConfiguration("Circular dependency detected involving '\(id)'")
            }
            guard let component = componentMap[id] else {
                throw MCSError.invalidConfiguration("Unknown component '\(id)'")
            }

            inStack.insert(id)
            visited.insert(id)

            // Visit dependencies first
            for depID in component.dependencies {
                if !selectedIDs.contains(depID) {
                    addedDeps.insert(depID)
                }
                try visit(depID)
            }

            inStack.remove(id)
            resolved.append(id)
        }

        // Resolve all selected components
        for id in selectedIDs.sorted() {
            try visit(id)
        }

        let orderedComponents = resolved.compactMap { componentMap[$0] }
        let addedComponents = addedDeps.compactMap { componentMap[$0] }

        return ResolvedPlan(
            orderedComponents: orderedComponents,
            addedDependencies: addedComponents
        )
    }
}
