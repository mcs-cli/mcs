import Foundation
@testable import mcs
import Testing

struct DestinationCollisionResolverTests {
    private let output = CLIOutput(colorsEnabled: false)
    private let dummySource = URL(fileURLWithPath: "/tmp/dummy.sh")

    private func makeComponent(
        pack: String, id: String, destination: String, fileType: CopyFileType
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "\(pack).\(id)",
            displayName: id,
            description: "Test component",
            type: fileType == .hook ? .hookFile : (fileType == .command ? .command : (fileType == .skill ? .skill : .agent)),
            packIdentifier: pack,
            dependencies: [],
            isRequired: false,
            installAction: .copyPackFile(source: dummySource, destination: destination, fileType: fileType),
            supplementaryChecks: []
        )
    }

    private func makePack(id: String, components: [ComponentDefinition]) -> MockTechPack {
        MockTechPack(identifier: id, displayName: id, components: components)
    }

    @Test("No collision — destinations unchanged")
    func noCollision() {
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "format", destination: "format.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: output)

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
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "lint", destination: "lint.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: output)

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
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "my-skill", destination: "my-skill", fileType: .skill),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "my-skill", destination: "my-skill", fileType: .skill),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: output)

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
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "lint", destination: "lint.sh", fileType: .hook),
        ])
        let packC = makePack(id: "pack-c", components: [
            makeComponent(pack: "pack-c", id: "format", destination: "format.sh", fileType: .hook),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB, packC], output: output)

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
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "pr", destination: "pr.md", fileType: .agent),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: output)

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "pr.md")
        }
        if case let .copyPackFile(_, destination, _) = result[1].components[0].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Single pack — no namespace applied")
    func singlePackNoNamespace() {
        let pack = makePack(id: "my-pack", components: [
            makeComponent(pack: "my-pack", id: "lint", destination: "lint.sh", fileType: .hook),
            makeComponent(pack: "my-pack", id: "pr", destination: "pr.md", fileType: .command),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [pack], output: output)

        if case let .copyPackFile(_, destination, _) = result[0].components[0].installAction {
            #expect(destination == "lint.sh")
        }
        if case let .copyPackFile(_, destination, _) = result[0].components[1].installAction {
            #expect(destination == "pr.md")
        }
    }

    @Test("Mixed: skill collision gets suffix, command collision gets subdirectory")
    func mixedCollisionTypes() {
        let packA = makePack(id: "pack-a", components: [
            makeComponent(pack: "pack-a", id: "my-skill", destination: "my-skill", fileType: .skill),
            makeComponent(pack: "pack-a", id: "pr", destination: "pr.md", fileType: .command),
        ])
        let packB = makePack(id: "pack-b", components: [
            makeComponent(pack: "pack-b", id: "my-skill", destination: "my-skill", fileType: .skill),
            makeComponent(pack: "pack-b", id: "pr", destination: "pr.md", fileType: .command),
        ])

        let result = DestinationCollisionResolver.resolveCollisions(packs: [packA, packB], output: output)

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
