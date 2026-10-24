import Foundation

/// Git clone/fetch operations for external tech packs.
struct PackFetcher {
    let shell: any ShellRunning
    let output: CLIOutput
    let packsDirectory: URL // ~/.mcs/packs/

    struct FetchResult {
        let localPath: URL // Where the pack was cloned to
        let commitSHA: String // The checked-out commit
        let ref: String? // The tag/branch if specified
    }

    // MARK: - Fetch (Clone)

    /// Clone a pack repo to `~/.mcs/packs/<identifier>/`.
    /// If `ref` is specified, clone at that tag, branch, or full commit SHA.
    /// If the pack directory already exists, it is removed first for a clean state.
    func fetch(url: String, identifier: String, ref: String?) throws -> FetchResult {
        try validateIdentifier(identifier)
        guard let packPath = PathContainment.safePath(
            relativePath: identifier,
            within: packsDirectory
        ) else {
            throw PackFetchError.pathEscapesPacksDirectory(path: identifier)
        }
        return try clone(url: url, into: packPath, ref: ref)
    }

    /// Clone into an already-resolved checkout path, replacing whatever is there.
    func clone(url: String, into packPath: URL, ref: String?) throws -> FetchResult {
        try ensureGitAvailable()
        try ensurePacksDirectory()
        if let ref { try validateRef(ref) }
        // `isContained` accepts the base itself, and the clean-state removal below would then
        // delete every installed pack.
        guard PathContainment.isContained(url: packPath, within: packsDirectory),
              packPath.resolvingSymlinksInPath() != packsDirectory.resolvingSymlinksInPath()
        else {
            throw PackFetchError.pathEscapesPacksDirectory(path: packPath.path)
        }

        // Clean state: remove existing checkout if present
        let fm = FileManager.default
        if fm.fileExists(atPath: packPath.path) {
            try fm.removeItem(at: packPath)
        }

        // Built by hand rather than `clone --branch`, which cannot resolve a commit SHA. The
        // checkout is the same detached, depth-1 shape `update` resets to, for every ref type.
        let steps: [(arguments: [String], workingDirectory: String?)] = [
            (["init", "--quiet", packPath.path], nil),
            (["remote", "add", "origin", url], packPath.path),
            (["fetch", "--depth", "1", "origin", Self.fetchRefspec(ref)], packPath.path),
            (["checkout", "--quiet", Self.fetchedRef], packPath.path),
        ]
        // Unlike `git clone`, a failed step leaves the initialised directory behind, and a
        // scheduled retry would pile them up under a fresh temp path each time.
        let commitSHA: String
        do {
            for step in steps {
                let result = shell.run(
                    shell.environment.gitPath, arguments: step.arguments, workingDirectory: step.workingDirectory
                )
                guard result.succeeded else {
                    throw PackFetchError.cloneFailed(url: url, stderr: result.stderr + Self.refHint(ref))
                }
            }
            commitSHA = try currentCommit(at: packPath)
        } catch {
            if fm.fileExists(atPath: packPath.path) {
                do {
                    try fm.removeItem(at: packPath)
                } catch let cleanup {
                    output.warn("Could not remove partial checkout at \(packPath.path): \(cleanup.localizedDescription)")
                }
            }
            throw error
        }

        return FetchResult(
            localPath: packPath,
            commitSHA: commitSHA,
            ref: ref
        )
    }

    /// A full 40-hex commit SHA: a ref that can never move.
    static func isCommitSHA(_ ref: String) -> Bool {
        ref.count == 40 && ref.allSatisfy(\.isHexDigit)
    }

    /// What every fetch asks the remote for. With no ref it is the remote's default branch,
    /// fetched by name so no checkout depends on a local `origin/HEAD`, which a pack first
    /// cloned at a ref never has.
    static func fetchTarget(_ ref: String?) -> String {
        ref ?? "HEAD"
    }

    /// Where clone and update land a fetch. A private ref rather than the shared `FETCH_HEAD`, so
    /// the update-check hook fetching in the same checkout can't swap what gets checked out.
    static let fetchedRef = "refs/mcs/fetch"

    static func fetchRefspec(_ ref: String?, into destination: String = fetchedRef) -> String {
        "+\(fetchTarget(ref)):\(destination)"
    }

    /// Appended to a failed fetch's stderr for the two ref shapes git's own message doesn't explain.
    static func refHint(_ ref: String?) -> String {
        guard let ref, ref.allSatisfy(\.isHexDigit) else { return "" }
        if isCommitSHA(ref) {
            return "\nThe server may not allow fetching a commit by SHA (it needs protocol v2 or"
                + " uploadpack.allowReachableSHA1InWant); pin a tag instead."
        }
        guard (7 ..< 40).contains(ref.count) else { return "" }
        return "\nIf '\(ref)' is an abbreviated commit SHA, use the full 40-character SHA."
    }

    // MARK: - Update

    /// Fetch the commit `ref` names (the remote's default branch when nil) without touching the
    /// working tree, so anything loading from the checkout keeps reading it while the caller decides.
    ///
    /// Fetching by name into `fetchedRef` is uniform for every ref type, including none; a plain
    /// `checkout <branch>` would not advance the local branch past what the clone captured.
    func fetchTarget(packPath: URL, ref: String?) throws -> String {
        try ensureGitAvailable()
        if let ref { try validateRef(ref) }

        let fetchArgs = ["fetch", "--depth", "1", "origin", Self.fetchRefspec(ref)]
        let fetchResult = shell.run(shell.environment.gitPath, arguments: fetchArgs, workingDirectory: packPath.path)
        guard fetchResult.succeeded else {
            throw PackFetchError.fetchFailed(path: packPath.path, stderr: fetchResult.stderr + Self.refHint(ref))
        }
        // Peeled: an annotated tag's fetched ref names the tag object, never equal to HEAD, so
        // every update of a tag-pinned pack would read as a change.
        return try resolveCommit("\(Self.fetchedRef)^{commit}", at: packPath)
    }

    /// Move the checkout back to `commitSHA`. A shallow fetch may have dropped it locally, so a
    /// failed reset fetches that exact commit before retrying.
    func reset(packPath: URL, to commitSHA: String) throws {
        let git = { (arguments: [String]) in
            shell.run(shell.environment.gitPath, arguments: arguments, workingDirectory: packPath.path)
        }
        if git(["reset", "--hard", commitSHA]).succeeded { return }
        let fetchResult = git(["fetch", "--depth", "1", "origin", commitSHA])
        guard fetchResult.succeeded else {
            throw PackFetchError.fetchFailed(path: packPath.path, stderr: fetchResult.stderr)
        }
        let resetResult = git(["reset", "--hard", commitSHA])
        guard resetResult.succeeded else {
            throw PackFetchError.updateFailed(path: packPath.path, stderr: resetResult.stderr)
        }
    }

    // MARK: - Current Commit

    /// Get the current commit SHA of a pack checkout.
    func currentCommit(at path: URL) throws -> String {
        try resolveCommit("HEAD", at: path)
    }

    private func resolveCommit(_ revision: String, at path: URL) throws -> String {
        let result = shell.run(
            shell.environment.gitPath, arguments: ["rev-parse", revision],
            workingDirectory: path.path
        )
        guard result.succeeded, !result.stdout.isEmpty else {
            throw PackFetchError.commitResolutionFailed(path: path.path, stderr: result.stderr)
        }
        return result.stdout
    }

    // MARK: - Remove

    /// Remove a pack's local checkout.
    func remove(packPath: URL) throws {
        let fm = FileManager.default

        // Validate path doesn't escape packs directory via traversal or symlinks
        guard PathContainment.isContained(url: packPath, within: packsDirectory) else {
            throw PackFetchError.pathEscapesPacksDirectory(path: packPath.path)
        }

        guard fm.fileExists(atPath: packPath.path) else { return }
        try fm.removeItem(at: packPath)
    }

    /// Same as `remove(packPath:)` but surfaces failure as a warning instead of
    /// propagating it. Used by cleanup paths where an orphan `~/.mcs/packs/…`
    /// directory is a nuisance, not a fatal error — but the failure must not
    /// be silent, or orphans accumulate invisibly.
    func removeQuietly(packPath: URL) {
        do {
            try remove(packPath: packPath)
        } catch {
            output.warn("Could not delete pack directory at \(packPath.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Validate that an identifier is safe for use as a path component.
    func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              !identifier.contains(".."),
              !identifier.contains("/"),
              !identifier.hasPrefix("-")
        else {
            throw PackFetchError.invalidIdentifier(identifier)
        }
    }

    /// Validate that a git ref is safe for use as a command argument.
    func validateRef(_ ref: String) throws {
        guard isValidGitRef(ref) else {
            throw PackFetchError.invalidRef(ref)
        }
    }

    private func ensureGitAvailable() throws {
        guard shell.commandExists("git") else {
            throw PackFetchError.gitNotInstalled
        }
    }

    private func ensurePacksDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: packsDirectory.path) {
            try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Ref validation

/// Predicate form of `PackFetcher.validateRef`. Returns `true` iff `ref` is safe to pass
/// directly as a positional argument to git: not a `-` option, no `..` range, and matches
/// a conservative subset of characters that git accepts (rejects e.g. `@`, which git allows
/// outside `@{}`). Used by callers that want to silently skip invalid refs — registry
/// corruption shouldn't surface as a git error.
func isValidGitRef(_ ref: String) -> Bool {
    !ref.hasPrefix("-")
        && !ref.contains("..")
        && ref.range(of: #"^[a-zA-Z0-9._/+-]+$"#, options: .regularExpression) != nil
}

// MARK: - Errors

/// Errors that can occur during pack fetch operations.
enum PackFetchError: Error, LocalizedError {
    case gitNotInstalled
    case cloneFailed(url: String, stderr: String)
    case fetchFailed(path: String, stderr: String)
    case updateFailed(path: String, stderr: String)
    case commitResolutionFailed(path: String, stderr: String)
    case invalidIdentifier(String)
    case invalidRef(String)
    case pathEscapesPacksDirectory(path: String)

    var errorDescription: String? {
        switch self {
        case .gitNotInstalled:
            "Git is not installed. Please install git to manage external packs."
        case let .cloneFailed(url, stderr):
            "Failed to clone '\(url)': \(stderr)"
        case let .fetchFailed(path, stderr):
            "Failed to fetch updates for '\(path)': \(stderr)"
        case let .updateFailed(path, stderr):
            "Failed to update '\(path)': \(stderr)"
        case let .commitResolutionFailed(path, stderr):
            "Failed to resolve commit at '\(path)': \(stderr)"
        case let .invalidIdentifier(id):
            "Invalid pack identifier '\(id)': must not contain '..', '/', or start with '-'"
        case let .invalidRef(ref):
            "Invalid git ref '\(ref)': contains unsafe characters"
        case let .pathEscapesPacksDirectory(path):
            "Path '\(path)' escapes packs directory"
        }
    }
}
