import Foundation
@testable import mcs
import Testing

// MARK: - hookCommand(prefix:)

struct ComponentHookCommandTests {
    private func makeComponent(
        type: ComponentType,
        hookRegistration: HookRegistration?,
        installAction: ComponentInstallAction
    ) -> ComponentDefinition {
        ComponentDefinition(
            id: "test",
            displayName: "Test",
            description: "test",
            type: type,
            packIdentifier: nil,
            dependencies: [],
            isRequired: false,
            hookRegistration: hookRegistration,
            installAction: installAction
        )
    }

    private func hookFile(destination: String) -> ComponentInstallAction {
        .copyPackFile(
            source: URL(fileURLWithPath: "/tmp/\(destination)"),
            destination: destination,
            fileType: .hook
        )
    }

    @Test("joins prefix and destination for a registered hook component")
    func buildsCommandForHookComponent() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .preToolUse, matcher: "Agent"),
            installAction: hookFile(destination: "gate.sh")
        )
        #expect(
            component.hookCommand(prefix: Constants.HookCommand.projectPrefix)
                == "bash .claude/hooks/gate.sh"
        )
        #expect(
            component.hookCommand(prefix: Constants.HookCommand.globalPrefix)
                == "bash ~/.claude/hooks/gate.sh"
        )
    }

    @Test("nil when the component declares no hook registration")
    func nilWithoutRegistration() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: nil,
            installAction: hookFile(destination: "gate.sh")
        )
        #expect(component.hookCommand(prefix: Constants.HookCommand.projectPrefix) == nil)
    }

    @Test("nil for a non-hook file type")
    func nilForNonHookFileType() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .preToolUse, matcher: nil),
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/gate.sh"),
                destination: "gate.sh",
                fileType: .command
            )
        )
        #expect(component.hookCommand(prefix: Constants.HookCommand.projectPrefix) == nil)
    }

    @Test("nil for an install action that copies no file")
    func nilForNonCopyAction() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .sessionStart, matcher: nil),
            installAction: .shellCommand(command: "echo hi")
        )
        #expect(component.hookCommand(prefix: Constants.HookCommand.projectPrefix) == nil)
    }
}
