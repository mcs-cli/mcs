import Foundation
@testable import mcs
import Testing

// MARK: - Shared Test Helpers

private let collisionTestOutput = CLIOutput(colorsEnabled: false)
private let collisionTestDummySource = URL(fileURLWithPath: "/tmp/dummy.sh")

private func makeCollisionComponent(
    pack: String, id: String, destination: String, fileType: CopyFileType
) -> ComponentDefinition {
    let componentType: ComponentType = switch fileType {
    case .hook: .hookFile
    case .command: .command
    case .skill: .skill
    default: .agent
    }
    return ComponentDefinition(
        id: "\(pack).\(id)",
        displayName: id,
        description: "Test component",
        type: componentType,
        packIdentifier: pack,
        dependencies: [],
        isRequired: false,
        installAction: .copyPackFile(source: collisionTestDummySource, destination: destination, fileType: fileType),
        supplementaryChecks: []
    )
}

private func makeCollisionPack(id: String, components: [ComponentDefinition]) -> MockTechPack {
    MockTechPack(identifier: id, displayName: id, components: components)
}

// MARK: - Mock Filesystem Context

private struct MockCollisionContext: CollisionFilesystemContext {
    var existingFiles: Set<String> = []
    var trackedFiles: Set<String> = []

    func fileExists(destination: String, fileType: CopyFileType) -> Bool {
        existingFiles.contains("\(fileType.subdirectory)\(destination)")
    }

    func isTrackedByPack(destination: String, fileType: CopyFileType) -> Bool {
        trackedFiles.contains("\(fileType.subdirectory)\(destination)")
    }
}

// MARK: - Cross-Pack Collision Tests (backward compat — no filesystemContext)

struct DestinationCollisionResolverTests {
    @Test("No collision — destinations unchanged")
    func noCollision() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "format", destination: "format.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: collisionTestOutput)

        // No wrapping needed — original packs returned
        #expect(result.count == 2)
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "format.sh")
        }
    }

    @Test("Two packs with same hook destination — both get subdirectory namespace")
    func hookCollision() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "lint", destination: "lint.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: collisionTestOutput)

        #expect(result.count == 2)
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pack-a/lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pack-b/lint.sh")
        }
    }

    @Test("Skill collision — first pack keeps clean name, second gets suffix")
    func skillCollisionSuffix() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "my-skill", destination: "my-skill", fileType: .skill),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "my-skill", destination: "my-skill", fileType: .skill),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: collisionTestOutput)

        #expect(result.count == 2)
        // First pack keeps clean name
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "my-skill")
        }
        // Second pack gets suffix
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "my-skill-pack-b")
        }
    }

    @Test("Three packs — only the two that collide get namespaced")
    func partialCollision() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packC = makeCollisionPack(id: "pack-c", components: [
            makeCollisionComponent(pack: "pack-c", id: "format", destination: "format.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB, packC], output: collisionTestOutput)

        // pack-a and pack-b collide on lint.sh → namespaced
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pack-a/lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pack-b/lint.sh")
        }
        // pack-c has no collision → unchanged
        if case let .copyPackFile(_, destination, _) = result[2].components[0].installAction {
            #expect(destination == "format.sh")
        }
    }

    @Test("Same destination but different fileType — no collision")
    func differentFileTypeNoCollision() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "pr", destination: "pr.md", fileType: .agent),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: collisionTestOutput)

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pr.md")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Single pack — no namespace without filesystem context (backward compat)")
    func singlePackNoNamespace() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "lint", destination: "lint.sh", fileType: .hook),
            makeCollisionComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [pack], output: collisionTestOutput)

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[0].components[1].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Mixed: skill collision gets suffix, command collision gets subdirectory")
    func mixedCollisionTypes() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "my-skill", destination: "my-skill", fileType: .skill),
            makeCollisionComponent(pack: "pack-a", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "my-skill", destination: "my-skill", fileType: .skill),
            makeCollisionComponent(pack: "pack-b", id: "pr", destination: "pr.md", fileType: .command),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: collisionTestOutput)

        // Pack A: skill keeps clean name, command gets subdirectory
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "my-skill")
        }
        if case let .copyPackFile(_, destination, _) = result[0].components[1].installAction {
            #expect(destination == "pack-a/pr.md")
        }
        // Pack B: skill gets suffix, command gets subdirectory
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "my-skill-pack-b")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[1].installAction {
            #expect(destination == "pack-b/pr.md")
        }
    }
}

// MARK: - Hook Always-Namespace Tests (with filesystemContext)

struct HookAlwaysNamespaceTests {
    @Test("Hook always namespaced with filesystem context — single pack")
    func hookAlwaysNamespaced() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let ctx = MockCollisionContext()

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "my-pack/lint.sh")
        }
    }

    @Test("Hook stays flat without filesystem context (backward compat)")
    func hookNoNamespaceWithoutContext() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "lint", destination: "lint.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [pack], output: collisionTestOutput)

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "lint.sh")
        }
    }

    @Test("Non-hook command stays flat with context when no conflict")
    func commandStaysFlatWithContext() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "lint", destination: "lint.sh", fileType: .hook),
            makeCollisionComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let ctx = MockCollisionContext()

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        // Hook is namespaced
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "my-pack/lint.sh")
        }
        // Command stays flat (no conflict)
        if case let .copyPackFile(_, destination, _) = result[0].components[1].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Two packs: hooks always namespaced, cross-pack collision guard skips them")
    func hookCrossPackWithContext() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let ctx = MockCollisionContext()

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [packA, packB], output: collisionTestOutput, filesystemContext: ctx
        )

        // Both hooks namespaced by Phase 0 — Phase 1a's cross-pack detection doesn't double-namespace
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pack-a/lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pack-b/lint.sh")
        }
    }
}

// MARK: - User-File Conflict Tests

struct UserFileConflictTests {
    @Test("Untracked command file on disk — pack namespaced to <pack-id>/")
    func userFileCommandConflict() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let ctx = MockCollisionContext(
            existingFiles: ["commands/pr.md"], // file exists on disk
            trackedFiles: [] // not tracked by any pack
        )

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "my-pack/pr.md")
        }
    }

    @Test("Untracked skill on disk — pack namespaced with suffix")
    func userFileSkillConflict() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "review", destination: "review", fileType: .skill),
        ])
        let ctx = MockCollisionContext(
            existingFiles: ["skills/review"],
            trackedFiles: []
        )

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "review-my-pack")
        }
    }

    @Test("Tracked command file on disk — no namespacing (mcs owns it)")
    func trackedFileNoConflict() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let ctx = MockCollisionContext(
            existingFiles: ["commands/pr.md"],
            trackedFiles: ["commands/pr.md"] // tracked → mcs owns it
        )

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Cross-pack collision + user file — cross-pack resolver handles, no double-namespace")
    func crossPackPlusUserFile() {
        let packA = makeCollisionPack(id: "pack-a", components: [
            makeCollisionComponent(pack: "pack-a", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let packB = makeCollisionPack(id: "pack-b", components: [
            makeCollisionComponent(pack: "pack-b", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let ctx = MockCollisionContext(
            existingFiles: ["commands/pr.md"], // user file exists too
            trackedFiles: [] // not tracked
        )

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [packA, packB], output: collisionTestOutput, filesystemContext: ctx
        )

        // Both get cross-pack namespacing; Phase 1b doesn't double-namespace
        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pack-a/pr.md")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pack-b/pr.md")
        }
    }

    @Test("File does not exist on disk — no namespacing for non-hook")
    func noFileNoConflict() {
        let pack = makeCollisionPack(id: "my-pack", components: [
            makeCollisionComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let ctx = MockCollisionContext(existingFiles: [], trackedFiles: [])

        let result = DestinationCollisionResolver.resolveCollisions(
            packs: [pack], output: collisionTestOutput, filesystemContext: ctx
        )

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pr.md")
        }
    }
}
