@testable import mcs
import Testing

struct DoctorCommandTests {
    @Test("Parses with no arguments (defaults)")
    func parsesDefaults() throws {
        let cmd = try DoctorCommand.parse([])
        #expect(cmd.fix == false)
        #expect(cmd.yes == false)
        #expect(cmd.pack == nil)
        #expect(cmd.global == false)
    }

    @Test("Parses --global flag")
    func parsesGlobal() throws {
        let cmd = try DoctorCommand.parse(["--global"])
        #expect(cmd.global == true)
    }

    @Test("Parses --global with --pack")
    func parsesGlobalWithPack() throws {
        let cmd = try DoctorCommand.parse(["--global", "--pack", "ios"])
        #expect(cmd.global == true)
        #expect(cmd.pack == "ios")
    }

    @Test("Parses --global with --fix")
    func parsesGlobalWithFix() throws {
        let cmd = try DoctorCommand.parse(["--global", "--fix"])
        #expect(cmd.global == true)
        #expect(cmd.fix == true)
    }

    @Test("Parses combined flags")
    func parsesCombined() throws {
        let cmd = try DoctorCommand.parse(["--fix", "--yes", "--pack", "ios", "--global"])
        #expect(cmd.fix == true)
        #expect(cmd.yes == true)
        #expect(cmd.pack == "ios")
        #expect(cmd.global == true)
    }

    @Test("skipLock is true when --fix is not set")
    func skipLockWithoutFix() throws {
        let cmd = try DoctorCommand.parse(["--global"])
        #expect(cmd.skipLock == true)
    }

    @Test("skipLock is false when --fix is set")
    func skipLockWithFix() throws {
        let cmd = try DoctorCommand.parse(["--fix"])
        #expect(cmd.skipLock == false)
    }
}
