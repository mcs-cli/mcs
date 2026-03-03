import Foundation

/// How the pack source was resolved from user input.
enum PackSource: Equatable {
    case gitURL(String)
    case localPath(URL)
}

/// Errors from pack source resolution.
enum PackSourceError: Error, Equatable, LocalizedError {
    case invalidInput(String)
    case notADirectory(String)
    case pathNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(reason): "Invalid input: \(reason)"
        case let .notADirectory(path): "Path is not a directory: \(path)"
        case let .pathNotFound(path): "Path does not exist: \(path)"
        }
    }
}

/// Resolves user input into a pack source (git URL or local filesystem path).
///
/// Detection order:
/// 1. Known URL schemes (`https://`, `http://`, `git@`, `ssh://`, `git://`) → git pack
/// 2. Existing filesystem path (absolute, relative, `~/`, `file://`) → local pack
/// 3. GitHub shorthand (`user/repo`) → expand to `https://github.com/user/repo.git`
///
/// Filesystem paths are checked before GitHub shorthand so that `org/pack`
/// resolves to a local directory when it exists on disk.
struct PackSourceResolver {
    /// The shorthand regex pattern. Each segment must start with an alphanumeric
    /// character to exclude path-like inputs such as `../foo` or `./bar`.
    static let shorthandPattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#

    func resolve(_ input: String) throws -> PackSource {
        guard !input.hasPrefix("-") else {
            throw PackSourceError.invalidInput("must not start with '-'")
        }

        // 1. Known URL schemes → git pack
        let urlPrefixes = ["https://", "http://", "git@", "ssh://", "git://"]
        if urlPrefixes.contains(where: { input.hasPrefix($0) }) {
            return .gitURL(input)
        }

        // 2. Filesystem path — check if input resolves to an existing directory.
        //    file:// is parsed via Foundation URL for correct RFC 8089 handling
        //    (e.g. file://localhost/path), with fallback to simple prefix stripping.
        let pathString: String = if input.hasPrefix("file://") {
            if let fileURL = URL(string: input), fileURL.isFileURL, !fileURL.path.isEmpty {
                fileURL.path
            } else {
                String(input.dropFirst("file://".count))
            }
        } else {
            input
        }

        // expandingTildeInPath handles ~/... and is a no-op for other paths.
        // URL(fileURLWithPath:) resolves relative paths (../, ./) against CWD.
        // Extract .path first to get the absolute string, then re-wrap —
        // calling .standardized directly on a relative URL mangles ".." components.
        let expanded = NSString(string: pathString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: URL(fileURLWithPath: expanded).path)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw PackSourceError.notADirectory(resolved.path)
            }
            return .localPath(resolved)
        }

        // 3. GitHub shorthand: user/repo (exactly two path components, no scheme).
        if input.range(of: Self.shorthandPattern, options: .regularExpression) != nil {
            return .gitURL("https://github.com/\(input.strippingGitSuffix).git")
        }

        throw PackSourceError.pathNotFound(resolved.path)
    }
}
