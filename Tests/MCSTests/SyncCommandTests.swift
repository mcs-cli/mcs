@testable import mcs
import Testing

@Suite("SyncCommand argument parsing")
struct SyncCommandTests {
    @Test("Parses with no arguments (defaults)")
    func parsesDefaults() throws {
        let cmd = try SyncCommand.parse([])
        #expect(cmd.path == nil)
        #expect(cmd.pack.isEmpty)
        #expect(cmd.all == false)
        #expect(cmd.dryRun == false)
        #expect(cmd.lock == false)
        #expect(cmd.update == false)
        #expect(cmd.customize == false)
        #expect(cmd.global == false)
    }

    @Test("Parses path argument")
    func parsesPath() throws {
        let cmd = try SyncCommand.parse(["/tmp/my-project"])
        #expect(cmd.path == "/tmp/my-project")
    }

    @Test("Parses --pack flag (repeatable)")
    func parsesPackRepeatable() throws {
        let cmd = try SyncCommand.parse(["--pack", "ios", "--pack", "android"])
        #expect(cmd.pack == ["ios", "android"])
    }

    @Test("Parses --all flag")
    func parsesAll() throws {
        let cmd = try SyncCommand.parse(["--all"])
        #expect(cmd.all == true)
    }

    @Test("Parses --dry-run flag")
    func parsesDryRun() throws {
        let cmd = try SyncCommand.parse(["--dry-run"])
        #expect(cmd.dryRun == true)
    }

    @Test("Parses --lock flag")
    func parsesLock() throws {
        let cmd = try SyncCommand.parse(["--lock"])
        #expect(cmd.lock == true)
    }

    @Test("Parses --update flag")
    func parsesUpdate() throws {
        let cmd = try SyncCommand.parse(["--update"])
        #expect(cmd.update == true)
    }

    @Test("skipLock is true when --dry-run is set")
    func skipLockWhenDryRun() throws {
        let cmd = try SyncCommand.parse(["--dry-run"])
        #expect(cmd.skipLock == true)
    }

    @Test("skipLock is false by default")
    func skipLockDefaultFalse() throws {
        let cmd = try SyncCommand.parse([])
        #expect(cmd.skipLock == false)
    }

    @Test("Parses --customize flag")
    func parsesCustomize() throws {
        let cmd = try SyncCommand.parse(["--customize"])
        #expect(cmd.customize == true)
    }

    @Test("Parses combined flags with path")
    func parsesCombined() throws {
        let cmd = try SyncCommand.parse(["--pack", "ios", "--dry-run", "--lock", "/tmp/proj"])
        #expect(cmd.path == "/tmp/proj")
        #expect(cmd.pack == ["ios"])
        #expect(cmd.dryRun == true)
        #expect(cmd.lock == true)
        #expect(cmd.update == false)
        #expect(cmd.all == false)
    }

    @Test("Parses --global flag")
    func parsesGlobal() throws {
        let cmd = try SyncCommand.parse(["--global"])
        #expect(cmd.global == true)
    }

    @Test("skipLock is false when --global is set (global sync needs lock)")
    func skipLockWhenGlobal() throws {
        let cmd = try SyncCommand.parse(["--global"])
        #expect(cmd.skipLock == false)
    }

    @Test("Parses --global with --pack and --dry-run")
    func parsesGlobalCombined() throws {
        let cmd = try SyncCommand.parse(["--global", "--pack", "ios", "--dry-run"])
        #expect(cmd.global == true)
        #expect(cmd.pack == ["ios"])
        #expect(cmd.dryRun == true)
    }

    @Test("Parses --global with --all")
    func parsesGlobalAll() throws {
        let cmd = try SyncCommand.parse(["--global", "--all"])
        #expect(cmd.global == true)
        #expect(cmd.all == true)
    }

    @Test("Parses --global with --customize")
    func parsesGlobalCustomize() throws {
        let cmd = try SyncCommand.parse(["--global", "--customize"])
        #expect(cmd.global == true)
        #expect(cmd.customize == true)
    }
}
