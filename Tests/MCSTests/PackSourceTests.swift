import Foundation
@testable import mcs
import Testing

@Suite("PackSourceResolver")
struct PackSourceResolverTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-packsource-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - URL scheme detection

    @Test("HTTPS URL returns gitURL")
    func httpsURL() throws {
        let result = try PackSourceResolver().resolve("https://github.com/user/repo.git")
        #expect(result == .gitURL("https://github.com/user/repo.git"))
    }

    @Test("git@ URL returns gitURL")
    func gitAtURL() throws {
        let result = try PackSourceResolver().resolve("git@github.com:user/repo.git")
        #expect(result == .gitURL("git@github.com:user/repo.git"))
    }

    @Test("ssh:// URL returns gitURL")
    func sshURL() throws {
        let result = try PackSourceResolver().resolve("ssh://git@github.com/user/repo")
        #expect(result == .gitURL("ssh://git@github.com/user/repo"))
    }

    @Test("git:// URL returns gitURL")
    func gitProtocolURL() throws {
        let result = try PackSourceResolver().resolve("git://github.com/user/repo.git")
        #expect(result == .gitURL("git://github.com/user/repo.git"))
    }

    @Test("http:// URL returns gitURL")
    func httpURL() throws {
        let result = try PackSourceResolver().resolve("http://example.com/user/repo.git")
        #expect(result == .gitURL("http://example.com/user/repo.git"))
    }

    // MARK: - GitHub shorthand

    @Test("user/repo expands to GitHub URL")
    func githubShorthand() throws {
        let result = try PackSourceResolver().resolve("user/repo")
        #expect(result == .gitURL("https://github.com/user/repo.git"))
    }

    @Test("user/repo.git deduplicates .git suffix")
    func githubShorthandDotGit() throws {
        let result = try PackSourceResolver().resolve("user/repo.git")
        #expect(result == .gitURL("https://github.com/user/repo.git"))
    }

    @Test("Shorthand with dots and hyphens expands correctly")
    func githubShorthandSpecialChars() throws {
        let result = try PackSourceResolver().resolve("my-org/my.pack")
        #expect(result == .gitURL("https://github.com/my-org/my.pack.git"))
    }

    @Test("Three-component path is not shorthand")
    func threeComponents() throws {
        // three/levels/deep doesn't match shorthand regex, treated as path
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("three/levels/deep")
        }
    }

    @Test("Single component is not shorthand")
    func singleComponent() throws {
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("justarepo")
        }
    }

    // MARK: - Shorthand regex excludes path-like inputs

    @Test("../foo is not treated as shorthand")
    func dotDotSlash() throws {
        // Should NOT match the shorthand regex (starts with .)
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("../nonexistent")
        }
    }

    @Test("./foo is not treated as shorthand")
    func dotSlash() throws {
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("./nonexistent")
        }
    }

    // MARK: - Filesystem paths

    @Test("Existing directory returns localPath")
    func existingDirectory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try PackSourceResolver().resolve(tmpDir.path)
        guard case let .localPath(url) = result else {
            Issue.record("Expected .localPath, got \(result)")
            return
        }
        #expect(url.standardizedFileURL.path == tmpDir.standardizedFileURL.path)
    }

    @Test("file:// prefix is stripped and treated as local path")
    func fileScheme() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try PackSourceResolver().resolve("file://\(tmpDir.path)")
        guard case let .localPath(url) = result else {
            Issue.record("Expected .localPath, got \(result)")
            return
        }
        #expect(url.standardizedFileURL.path == tmpDir.standardizedFileURL.path)
    }

    @Test("file://localhost/ URL is parsed correctly via Foundation URL")
    func fileLocalhostScheme() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try PackSourceResolver().resolve("file://localhost\(tmpDir.path)")
        guard case let .localPath(url) = result else {
            Issue.record("Expected .localPath, got \(result)")
            return
        }
        #expect(url.standardizedFileURL.path == tmpDir.standardizedFileURL.path)
    }

    @Test("Path to a file (not directory) throws")
    func fileNotDirectory() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("somefile.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve(file.path)
        }
    }

    @Test("Nonexistent absolute path throws pathNotFound")
    func nonexistentAbsolutePath() throws {
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("/nonexistent/path/to/pack")
        }
    }

    // MARK: - Filesystem before shorthand (ambiguity resolution)

    @Test("Existing directory matching shorthand pattern resolves as local path")
    func localPathWinsOverShorthand() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create org/pack inside tmpDir
        let orgDir = tmpDir.appendingPathComponent("org")
            .appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)

        // Change CWD to tmpDir so "org/pack" resolves to the directory
        let originalDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tmpDir.path)
        defer { FileManager.default.changeCurrentDirectoryPath(originalDir) }

        let result = try PackSourceResolver().resolve("org/pack")
        guard case let .localPath(url) = result else {
            Issue.record("Expected .localPath, got \(result)")
            return
        }
        #expect(url.resolvingSymlinksInPath().path == orgDir.resolvingSymlinksInPath().path)
    }

    // MARK: - Argument injection prevention

    @Test("Input starting with dash is rejected")
    func dashInjection() throws {
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("-malicious")
        }
    }

    @Test("Input starting with --flag is rejected")
    func flagInjection() throws {
        #expect(throws: PackSourceError.self) {
            try PackSourceResolver().resolve("--upload-pack=evil")
        }
    }
}
