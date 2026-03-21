import Foundation
@testable import mcs
import Testing

struct PathContainmentTests {
    private func makeTmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcs-pathcontain-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - safePath

    @Test("Returns URL for a safe relative path")
    func safePathValid() throws {
        let base = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = PathContainment.safePath(relativePath: "subdir/file.txt", within: base)
        #expect(result != nil)
        #expect(result?.lastPathComponent == "file.txt")
    }

    @Test("Returns nil for ../ traversal")
    func safePathBlocksTraversal() throws {
        let base = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(PathContainment.safePath(relativePath: "../escape.txt", within: base) == nil)
    }

    @Test("Returns nil for nested traversal")
    func safePathBlocksNestedTraversal() throws {
        let base = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(PathContainment.safePath(relativePath: "a/b/../../..", within: base) == nil)
    }

    @Test("Returns nil for symlink escape when target exists")
    func safePathBlocksSymlinkEscape() throws {
        let base = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // Create a symlink inside base that points outside
        let outsideDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        // The target file must exist for resolvingSymlinksInPath() to resolve the symlink
        try "sensitive".write(
            to: outsideDir.appendingPathComponent("secret.txt"),
            atomically: true, encoding: .utf8
        )

        let link = base.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)

        #expect(PathContainment.safePath(relativePath: "escape-link/secret.txt", within: base) == nil)
    }

    @Test("Allows legitimate nested paths")
    func safePathAllowsNested() throws {
        let base = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: base) }

        let result = PathContainment.safePath(relativePath: "a/b/c/d.txt", within: base)
        #expect(result != nil)
    }

    // MARK: - isContained

    @Test("isContained with matching paths")
    func isContainedMatching() {
        #expect(PathContainment.isContained(path: "/a/b/c", within: "/a/b"))
        #expect(PathContainment.isContained(path: "/a/b", within: "/a/b"))
    }

    @Test("isContained rejects escape")
    func isContainedRejectsEscape() {
        #expect(!PathContainment.isContained(path: "/a/b", within: "/a/b/c"))
        #expect(!PathContainment.isContained(path: "/other", within: "/a/b"))
    }

    @Test("isContained rejects prefix-but-not-child")
    func isContainedRejectsPrefixCollision() {
        // "/a/bar" starts with "/a/b" as a string but is NOT a child of "/a/b"
        #expect(!PathContainment.isContained(path: "/a/bar", within: "/a/b"))
    }
}
