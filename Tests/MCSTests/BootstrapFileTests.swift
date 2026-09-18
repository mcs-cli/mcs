import Foundation
@testable import mcs
import Testing

struct BootstrapFileTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-bootstrap-file-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, to dir: URL) throws -> URL {
        let path = dir.appendingPathComponent(BootstrapFile.defaultFilename)
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Success

    @Test("Loads a minimal v1 file with just a source")
    func loadsMinimalFile() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
        """, to: tmp)

        let file = try BootstrapFile.load(from: path)
        #expect(file.schemaVersion == 1)
        #expect(file.packs.count == 1)
        #expect(file.packs[0].source == "user/repo")
        #expect(file.packs[0].ref == nil)
        #expect(file.packs[0].values == nil)
        #expect(file.packs[0].scope == nil)
    }

    @Test("Loads a file with ref, values, and explicit project scope")
    func loadsFullFile() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
            ref: v1.2.0
            scope: project
            values:
              PROJECT: MyApp.xcodeproj
              REGION: us-east-1
        """, to: tmp)

        let file = try BootstrapFile.load(from: path)
        let pack = file.packs[0]
        #expect(pack.ref == "v1.2.0")
        #expect(pack.scope == "project")
        #expect(pack.values?["PROJECT"] == "MyApp.xcodeproj")
        #expect(pack.values?["REGION"] == "us-east-1")
    }

    // MARK: - Failures

    @Test("Missing file surfaces a notFound error")
    func missingFile() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = tmp.appendingPathComponent(BootstrapFile.defaultFilename)
        #expect(throws: BootstrapFileError.notFound(path: path.path)) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Rejects unsupported schemaVersion")
    func rejectsFutureSchema() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 99
        packs:
          - source: user/repo
        """, to: tmp)

        #expect(throws: BootstrapFileError.unsupportedSchemaVersion(found: 99, expected: 1)) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Rejects an empty packs list")
    func rejectsEmptyPackList() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs: []
        """, to: tmp)

        #expect(throws: BootstrapFileError.emptyPackList) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Rejects duplicate source entries")
    func rejectsDuplicateSource() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
          - source: user/repo
        """, to: tmp)

        #expect(throws: BootstrapFileError.duplicateSource("user/repo")) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Rejects a blank source")
    func rejectsBlankSource() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: "   "
        """, to: tmp)

        #expect(throws: BootstrapFileError.blankSource) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Rejects a scope value other than 'project'")
    func rejectsReservedScope() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
            scope: global
        """, to: tmp)

        #expect(throws: BootstrapFileError.reservedScope(source: "user/repo", scope: "global")) {
            _ = try BootstrapFile.load(from: path)
        }
    }

    @Test("Explicit 'project' scope is accepted")
    func acceptsProjectScope() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
            scope: project
        """, to: tmp)

        let file = try BootstrapFile.load(from: path)
        #expect(file.packs[0].scope == "project")
    }

    @Test("Source is normalized (trimmed) so validation and installation see the same value")
    func normalizesSourceWhitespace() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Quoted source with surrounding whitespace — must not survive as-is.
        // Prior behavior: validation trimmed, storage did not — install then failed
        // as a missing path.
        let path = try write("""
        schemaVersion: 1
        packs:
          - source: "  user/repo  "
        """, to: tmp)

        let file = try BootstrapFile.load(from: path)
        #expect(file.packs[0].source == "user/repo")
    }

    @Test("Trimming happens before duplicate detection, so quoted/spaced duplicates are caught")
    func duplicateDetectionUsesTrimmedValue() throws {
        let tmp = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try write("""
        schemaVersion: 1
        packs:
          - source: user/repo
          - source: "  user/repo  "
        """, to: tmp)

        #expect(throws: BootstrapFileError.duplicateSource("user/repo")) {
            _ = try BootstrapFile.load(from: path)
        }
    }
}

// MARK: - Source redaction

/// `redactSourceForDisplay` guards against leaking userinfo (`user:token@`) from
/// clone URLs into CI logs. Every terminal-facing sink in `BootstrapCommand`
/// runs through it, so a regression that reintroduces raw interpolation would
/// expose credentials — pin the redaction contract directly.
struct BootstrapSourceRedactionTests {
    @Test("HTTPS URL with embedded credentials strips user and password")
    func stripsUserinfoFromHTTPS() {
        let redacted = redactSourceForDisplay("https://user:secret@github.com/org/repo.git")
        #expect(!redacted.contains("secret"))
        #expect(!redacted.contains("user"))
        #expect(redacted.contains("github.com/org/repo.git"))
    }

    @Test("HTTPS URL with only a token as user strips the token")
    func stripsTokenOnlyUserinfo() {
        let redacted = redactSourceForDisplay("https://ghp_abc123token@github.com/org/repo.git")
        #expect(!redacted.contains("ghp_abc123token"))
        #expect(redacted.contains("github.com/org/repo.git"))
    }

    @Test("SSH URL passes through unchanged")
    func sshURLIsPreserved() {
        let source = "git@github.com:org/repo.git"
        #expect(redactSourceForDisplay(source) == source)
    }

    @Test("GitHub shorthand passes through unchanged")
    func githubShorthandIsPreserved() {
        #expect(redactSourceForDisplay("user/repo") == "user/repo")
    }

    @Test("Absolute local path passes through unchanged")
    func absolutePathIsPreserved() {
        #expect(redactSourceForDisplay("/Users/dev/repos/pack") == "/Users/dev/repos/pack")
    }

    @Test("Plain HTTPS URL without credentials passes through unchanged")
    func cleanHTTPSIsPreserved() {
        let source = "https://github.com/org/repo.git"
        #expect(redactSourceForDisplay(source) == source)
    }
}
