import Foundation
@testable import mcs
import Testing

struct EnvironmentTests {
    /// Create a unique temp directory simulating a home directory.
    private func makeTmpHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-env-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Path construction

    @Test("Environment paths are relative to home directory")
    func pathsRelativeToHome() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let env = Environment(home: home)

        #expect(env.claudeDirectory.path == home.appendingPathComponent(".claude").path)
        #expect(env.claudeJSON.path == home.appendingPathComponent(".claude.json").path)
        #expect(env.claudeSettings.path ==
            home.appendingPathComponent(".claude/settings.json").path)
    }

    // MARK: - isInsideClaudeHome

    @Test("isInsideClaudeHome: true for claudeDirectory itself when .claude.json exists")
    func isInsideClaudeHomeExactMatch() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        #expect(env.isInsideClaudeHome(env.claudeDirectory))
    }

    @Test("isInsideClaudeHome: true for nested paths inside claudeDirectory")
    func isInsideClaudeHomeNested() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let nested = env.claudeDirectory.appendingPathComponent("skills/foo")
        #expect(env.isInsideClaudeHome(nested))
    }

    @Test("isInsideClaudeHome: false when .claude.json is missing (fresh install edge case)")
    func isInsideClaudeHomeMissingSibling() throws {
        let home = try makeClaudeHome(withJSON: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        #expect(!env.isInsideClaudeHome(env.claudeDirectory))
    }

    @Test("isInsideClaudeHome: false for unrelated paths")
    func isInsideClaudeHomeUnrelatedPath() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        #expect(!env.isInsideClaudeHome(home.appendingPathComponent("project")))
        #expect(!env.isInsideClaudeHome(URL(fileURLWithPath: "/tmp")))
    }

    @Test("isInsideClaudeHome: false for sibling dir that merely shares a name prefix")
    func isInsideClaudeHomePrefixCollision() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        // `/~/.claudex` must not be considered inside `/~/.claude`
        let spoof = home.appendingPathComponent(".claudex")
        #expect(!env.isInsideClaudeHome(spoof))
    }

    @Test("isInsideClaudeHome: true for $HOME itself when layout matches")
    func isInsideClaudeHomeExactHome() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        #expect(env.isInsideClaudeHome(env.homeDirectory))
    }

    @Test("isInsideClaudeHome: false for $HOME/subdir (legitimate project locations)")
    func isInsideClaudeHomeSiblingSubdir() throws {
        let home = try makeClaudeHome(withJSON: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let subdir = home.appendingPathComponent("Documents")
        #expect(!env.isInsideClaudeHome(subdir))
    }

    @Test("isInsideClaudeHome: false for $HOME match when .claude.json missing")
    func isInsideClaudeHomeExactHomeWithoutSibling() throws {
        let home = try makeClaudeHome(withJSON: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        #expect(!env.isInsideClaudeHome(env.homeDirectory))
    }

    // MARK: - Homebrew prefix

    @Test("brewPrefix keeps the symlinked entry point's own prefix")
    func brewPrefixDoesNotFollowSymlinks() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // The shape Linuxbrew and Intel macOS install: $PREFIX/bin/brew -> ../Homebrew/bin/brew.
        let prefix = home.appendingPathComponent("prefix")
        let repositoryBin = prefix.appendingPathComponent("Homebrew/bin")
        let prefixBin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: repositoryBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefixBin, withIntermediateDirectories: true)
        try Data().write(to: repositoryBin.appendingPathComponent("brew"))
        try FileManager.default.createSymbolicLink(
            atPath: prefixBin.appendingPathComponent("brew").path,
            withDestinationPath: "../Homebrew/bin/brew"
        )

        // Resolving the symlink first would yield <prefix>/Homebrew, whose bin holds only brew.
        #expect(Environment.brewPrefix(forBrewPath: prefixBin.appendingPathComponent("brew").path) == prefix.path)
    }

    @Test("brewPrefix handles a real file at $PREFIX/bin/brew (arm64 macOS shape)")
    func brewPrefixForRealFile() {
        #expect(Environment.brewPrefix(forBrewPath: "/opt/homebrew/bin/brew") == "/opt/homebrew")
    }

    @Test("The fallback prefix is the platform's own default")
    func defaultBrewPrefixPerPlatform() {
        #if canImport(Darwin) && arch(arm64)
        #expect(Environment.defaultBrewPrefix == "/opt/homebrew")
        #elseif canImport(Darwin)
        #expect(Environment.defaultBrewPrefix == "/usr/local")
        #else
        #expect(Environment.defaultBrewPrefix == "/home/linuxbrew/.linuxbrew")
        #endif
    }

    @Test("pathWithBrew prepends the prefix bin directory exactly once")
    func pathWithBrewPrependsOnce() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment(home: home)

        let path = env.pathWithBrew
        let brewBin = "\(env.brewPrefix)/bin"
        #expect(path.contains(brewBin))
        #expect(path.components(separatedBy: brewBin).count == 2, "brew bin must appear exactly once")
    }
}
