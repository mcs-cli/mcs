import ArgumentParser
import Foundation
@testable import mcs
import Testing

struct SyncCommandTests {
    @Test("Parses with no arguments (defaults)")
    func parsesDefaults() throws {
        let cmd = try SyncCommand.parse([])
        #expect(cmd.path == nil)
        #expect(cmd.pack.isEmpty)
        #expect(cmd.all == false)
        #expect(cmd.dryRun == false)
        #expect(cmd.lock == false)
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

    // MARK: - Lockfile Dispatch Matrix

    @Test("Dispatch: dry-run always skips lockfile work")
    func dispatchDryRunSkips() {
        var config = MCSConfig()
        for flag in [nil, true, false] as [Bool?] {
            config.generateLockfile = flag
            #expect(SyncCommand.lockfileAction(dryRun: true, config: config) == .skip)
        }
    }

    @Test("Dispatch: generate-lockfile=true writes")
    func dispatchConfigTrueWrites() {
        var config = MCSConfig()
        config.generateLockfile = true
        #expect(SyncCommand.lockfileAction(dryRun: false, config: config) == .write)
    }

    @Test("Dispatch: generate-lockfile=nil (unset) reports drift — upgrade path")
    func dispatchConfigNilReportsDrift() {
        let config = MCSConfig()
        #expect(config.generateLockfile == nil)
        #expect(SyncCommand.lockfileAction(dryRun: false, config: config) == .reportDrift)
    }

    @Test("Dispatch: generate-lockfile=false stays silent — explicit opt-out")
    func dispatchConfigFalseSkips() {
        var config = MCSConfig()
        config.generateLockfile = false
        #expect(SyncCommand.lockfileAction(dryRun: false, config: config) == .skip)
    }
}

// MARK: - Guard: cwd inside ~/.claude detection

struct SyncCommandGuardTests {
    private func silentOutput() -> CLIOutput {
        CLIOutput(colorsEnabled: false)
    }

    @Test("Guard returns self.global unchanged when target is outside ~/.claude")
    func guardSkipsWhenTargetOutsideHome() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let project = home.appendingPathComponent("some-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let bare = try SyncCommand.parse([project.path])
        #expect(try bare.guardClaudeHomeCwd(env: env, output: silentOutput()) == false)

        let withGlobal = try SyncCommand.parse([project.path, "--global"])
        #expect(try withGlobal.guardClaudeHomeCwd(env: env, output: silentOutput()) == true)
    }

    @Test("Guard skips when .claude.json sibling is missing (fresh install edge case)")
    func guardSkipsWhenSiblingMissing() throws {
        let home = try makeClaudeHome(withJSON: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.claudeDirectory.path, "--pack", "foo"])
        #expect(try cmd.guardClaudeHomeCwd(env: env, output: silentOutput()) == false)
    }

    @Test("Guard throws when target is ~/.claude and --pack is set")
    func guardThrowsOnNonInteractivePack() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.claudeDirectory.path, "--pack", "foo"])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }

    @Test("Guard throws when target is ~/.claude and --all is set")
    func guardThrowsOnNonInteractiveAll() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.claudeDirectory.path, "--all"])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }

    @Test("Guard redirects to global and chdirs to home when --global + cwd in ~/.claude")
    func guardSilentRedirectWithGlobalFlag() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let originalCwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }

        let cmd = try SyncCommand.parse([env.claudeDirectory.path, "--global", "--pack", "foo"])
        let effective = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        #expect(effective == true)

        let resultCwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath()
        #expect(resultCwd == env.homeDirectory.resolvingSymlinksInPath())
    }

    @Test("Guard triggers for nested paths like ~/.claude/skills")
    func guardTriggersOnNestedPath() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let nested = env.claudeDirectory.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let cmd = try SyncCommand.parse([nested.path, "--pack", "foo"])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }

    @Test("Guard triggers when target is $HOME itself (where .claude and .claude.json live)")
    func guardTriggersOnHomeItself() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.homeDirectory.path, "--pack", "foo"])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }

    @Test("Guard does NOT trigger for $HOME/subdir (legitimate project locations)")
    func guardSkipsForHomeSubdir() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let project = home.appendingPathComponent("Projects/my-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let cmd = try SyncCommand.parse([project.path, "--pack", "foo"])
        #expect(try cmd.guardClaudeHomeCwd(env: env, output: silentOutput()) == false)
    }

    @Test("Guard hard-errors on bare sync from ~/.claude when stdin is non-interactive")
    func guardHardErrorsOnBareSyncNonInteractive() throws {
        // Prevents CI/piped-stdin from silently accepting the askYesNo default.
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.claudeDirectory.path])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }

    @Test("Guard hard-errors on --dry-run from ~/.claude (treats dry-run as non-interactive)")
    func guardHardErrorsOnDryRun() throws {
        let home = try makeClaudeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let cmd = try SyncCommand.parse([env.claudeDirectory.path, "--dry-run"])
        #expect(throws: ExitCode.self) {
            _ = try cmd.guardClaudeHomeCwd(env: env, output: silentOutput())
        }
    }
}
