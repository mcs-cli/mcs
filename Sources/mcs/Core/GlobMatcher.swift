import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thin wrapper over POSIX `fnmatch(3)` for path-vs-pattern matching.
///
/// Used by the `techpack.yaml` `ignore:` field (issue #338). Semantics:
/// - `*` matches any sequence of non-`/` characters.
/// - `?` matches a single non-`/` character.
/// - `[...]` matches one character from the set.
/// - `FNM_PATHNAME` is on: `*` does not cross `/`. To silence an entire directory
///   tree, authors should write either `docs/` (trailing slash — see below) or an
///   explicit prefix match.
///
/// **POSIX, not gitignore.** This matcher does NOT support `**` recursion. If pack
/// authors need deep globbing, we'll need a gitignore-semantics matcher; start with
/// POSIX glob and expand when real use cases appear.
enum GlobMatcher {
    /// Returns `true` iff `path` matches `pattern`.
    ///
    /// Directory-suffix convention: a pattern ending in `/` (e.g. `docs/`) matches
    /// any path whose first segment is the directory name. This is the intuitive
    /// "silence this whole directory" behavior pack authors expect, layered on top
    /// of `fnmatch` since POSIX globs have no native notion of directory trees.
    static func matches(_ pattern: String, path: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Directory-suffix shortcut: `docs/` silences `docs/guide.md`, `docs/sub/x.md`, etc.
        if trimmed.hasSuffix("/") {
            let dirName = String(trimmed.dropLast())
            guard !dirName.isEmpty else { return false }
            return path == dirName || path.hasPrefix("\(dirName)/")
        }

        let result = trimmed.withCString { patternCStr in
            path.withCString { pathCStr in
                fnmatch(patternCStr, pathCStr, FNM_PATHNAME)
            }
        }
        return result == 0
    }
}
