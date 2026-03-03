import Foundation
@testable import mcs
import Testing

@Suite("FileHasher")
struct FileHasherTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-filehasher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Compute file hash for known content produces expected SHA-256")
    func knownHash() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file = tmpDir.appendingPathComponent("hello.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let hash = try FileHasher.sha256(of: file)

        // SHA-256 of "hello\n"
        let expected = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        #expect(hash == expected)
    }

    @Test("directoryFileHashes returns sorted entries for all files")
    func directoryHashes() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "alpha".write(
            to: tmpDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        try "beta".write(
            to: tmpDir.appendingPathComponent("b.txt"),
            atomically: true, encoding: .utf8
        )

        let results = try FileHasher.directoryFileHashes(at: tmpDir)
        let paths = results.map(\.relativePath)
        #expect(paths == ["a.txt", "b.txt"])
        #expect(results.allSatisfy { !$0.hash.isEmpty })
    }
}
