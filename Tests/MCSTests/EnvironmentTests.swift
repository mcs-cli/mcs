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

    // MARK: - Home directory

    @Test("The default home directory prefers $HOME")
    func defaultHomeDirectoryPrefersHOME() {
        // Tested as a pure function rather than by mutating the process environment: swift-testing
        // runs in parallel, and setenv would leak into every other test in flight.
        #expect(Environment.defaultHomeDirectory(environment: ["HOME": "/sandbox/home"]) == "/sandbox/home")
    }

    @Test("An unset or empty $HOME falls back to the passwd entry")
    func defaultHomeDirectoryFallsBackToPasswd() {
        #expect(Environment.defaultHomeDirectory(environment: [:]) == NSHomeDirectory())
        #expect(Environment.defaultHomeDirectory(environment: ["HOME": ""]) == NSHomeDirectory())
        #expect(Environment.defaultHomeDirectory(environment: ["HOME": "relative/home"]) == NSHomeDirectory())
    }

    @Test("The default initializer wires the resolved home through")
    func defaultInitUsesDefaultHomeDirectory() {
        #expect(Environment().homeDirectory.path == Environment.defaultHomeDirectory())
    }

    @Test("A leading tilde expands against the environment's home, not the passwd entry")
    func expandingTildeUsesEnvironmentHome() {
        let env = Environment(home: URL(fileURLWithPath: "/sandbox/home"))

        #expect(env.expandingTilde("~") == "/sandbox/home")
        #expect(env.expandingTilde("~/") == "/sandbox/home")
        #expect(env.expandingTilde("~/packs/ios") == "/sandbox/home/packs/ios")
        #expect(env.expandingTilde("/abs/path") == "/abs/path")
        #expect(env.expandingTilde("relative/~/x") == "relative/~/x")
        #expect(env.expandingTilde("~other/x") == "~other/x")
    }

    // MARK: - Homebrew prefix

    @Test("brewPrefix strips the Homebrew repository component the installer's symlink resolves to")
    func brewPrefixStripsRepositoryCheckout() throws {
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

        // Resolving alone yields <prefix>/Homebrew, whose bin holds only brew.
        #expect(Environment.brewPrefix(forBrewPath: prefixBin.appendingPathComponent("brew").path) == prefix.path)
    }

    @Test("brewPrefix follows a shim symlink back to the real prefix")
    func brewPrefixFollowsShim() throws {
        let home = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: home) }

        // A user-made ~/.local/bin/brew -> <prefix>/bin/brew with <prefix>/bin off PATH: the
        // prefix formulae link into is the target's, not the shim's.
        let prefix = home.appendingPathComponent("opt/homebrew")
        let prefixBin = prefix.appendingPathComponent("bin")
        let shimBin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: prefixBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shimBin, withIntermediateDirectories: true)
        try Data().write(to: prefixBin.appendingPathComponent("brew"))
        try FileManager.default.createSymbolicLink(
            atPath: shimBin.appendingPathComponent("brew").path,
            withDestinationPath: prefixBin.appendingPathComponent("brew").path
        )

        let expected = prefix.resolvingSymlinksInPath().path
        #expect(Environment.brewPrefix(forBrewPath: shimBin.appendingPathComponent("brew").path) == expected)
    }

    @Test("brewPrefix handles a real file at $PREFIX/bin/brew (arm64 macOS shape)")
    func brewPrefixForRealFile() {
        #expect(Environment.brewPrefix(forBrewPath: "/opt/homebrew/bin/brew") == "/opt/homebrew")
    }
}
