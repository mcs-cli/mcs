import Foundation
@testable import mcs
import Testing

// MARK: - hookCommand(pathPrefix:)

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
            component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory)
                == "bash .claude/hooks/gate.sh"
        )
        #expect(
            component.hookCommand(pathPrefix: Constants.HookCommand.globalDirectory)
                == "bash ~/.claude/hooks/gate.sh"
        )
    }

    @Test("uses an explicitly declared interpreter, arguments included")
    func usesExplicitInterpreter() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(
                event: .postToolUse,
                interpreter: "node --experimental-strip-types --disable-warning=ExperimentalWarning"
            ),
            installAction: hookFile(destination: "gate.ts")
        )
        #expect(
            component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory)
                == "node --experimental-strip-types --disable-warning=ExperimentalWarning .claude/hooks/gate.ts"
        )
    }

    @Test("infers the interpreter from the destination extension")
    func infersInterpreterFromExtension() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .sessionStart),
            installAction: hookFile(destination: "fmt.js")
        )
        #expect(
            component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory)
                == "node .claude/hooks/fmt.js"
        )
    }

    @Test("falls back to the source extension when the destination has none")
    func infersFromSourceExtension() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .sessionStart),
            installAction: .copyPackFile(
                source: URL(fileURLWithPath: "/tmp/hooks/audit.py"),
                destination: "audit",
                fileType: .hook
            )
        )
        #expect(
            component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory)
                == "python3 .claude/hooks/audit"
        )
    }

    @Test("nil when the component declares no hook registration")
    func nilWithoutRegistration() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: nil,
            installAction: hookFile(destination: "gate.sh")
        )
        #expect(component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory) == nil)
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
        #expect(component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory) == nil)
    }

    @Test("nil for an install action that copies no file")
    func nilForNonCopyAction() {
        let component = makeComponent(
            type: .hookFile,
            hookRegistration: HookRegistration(event: .sessionStart, matcher: nil),
            installAction: .shellCommand(command: "echo hi")
        )
        #expect(component.hookCommand(pathPrefix: Constants.HookCommand.projectDirectory) == nil)
    }
}
