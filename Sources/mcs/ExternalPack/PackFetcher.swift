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
    /// If `ref` is specified, check out that ref (tag, branch, or commit).
    /// If the pack directory already exists, it is removed first for a clean state.
    func fetch(url: String, identifier: String, ref: String?) throws -> FetchResult {
        try ensureGitAvailable()
        try ensurePacksDirectory()
        try validateIdentifier(identifier)
        if let ref { try validateRef(ref) }

        guard let packPath = PathContainment.safePath(
            relativePath: identifier,
            within: packsDirectory
        ) else {
            throw PackFetchError.pathEscapesPacksDirectory(path: identifier)
        }

        // Clean state: remove existing checkout if present
        let fm = FileManager.default
        if fm.fileExists(atPath: packPath.path) {
            try fm.removeItem(at: packPath)
        }

        // Clone
        var args = ["clone", "--depth", "1"]
        if let ref {
            args += ["--branch", ref]
        }
        args += [url, packPath.path]

        let result = shell.run(shell.environment.gitPath, arguments: args)
        guard result.succeeded else {
            throw PackFetchError.cloneFailed(url: url, stderr: result.stderr)
        }

        let commitSHA = try currentCommit(at: packPath)

        return FetchResult(
            localPath: packPath,
            commitSHA: commitSHA,
            ref: ref
        )
    }

    // MARK: - Update

    /// Update an existing pack checkout.
    /// Returns a `FetchResult` if updated, or `nil` if already at the latest commit.
    ///
    /// When `ref` is set, fetches that ref explicitly and resets to `FETCH_HEAD` — uniform for
    /// any ref type. A plain `checkout <branch>` would not advance the local branch past
    /// whatever was captured at clone time, freezing branch-ref packs.
    func update(packPath: URL, ref: String?) throws -> FetchResult? {
        try ensureGitAvailable()
        if let ref { try validateRef(ref) }

        let beforeSHA = try currentCommit(at: packPath)
        let workDir = packPath.path

        let fetchArgs: [String]
        let resetTarget: String
        if let ref {
            fetchArgs = ["fetch", "--depth", "1", "origin", ref]
            resetTarget = "FETCH_HEAD"
        } else {
            fetchArgs = ["fetch", "--depth", "1", "origin"]
            resetTarget = "origin/HEAD"
        }

        let fetchResult = shell.run(
            shell.environment.gitPath, arguments: fetchArgs,
            workingDirectory: workDir
        )
        guard fetchResult.succeeded else {
            throw PackFetchError.fetchFailed(path: packPath.path, stderr: fetchResult.stderr)
        }

        let resetResult = shell.run(
            shell.environment.gitPath, arguments: ["reset", "--hard", resetTarget],
            workingDirectory: workDir
        )
        guard resetResult.succeeded else {
            throw PackFetchError.updateFailed(path: packPath.path, stderr: resetResult.stderr)
        }

        let afterSHA = try currentCommit(at: packPath)

        if afterSHA == beforeSHA {
            return nil // Already at latest
        }

        return FetchResult(
            localPath: packPath,
            commitSHA: afterSHA,
            ref: ref
        )
    }

    // MARK: - Current Commit

    /// Get the current commit SHA of a pack checkout.
    func currentCommit(at path: URL) throws -> String {
        let result = shell.run(
            shell.environment.gitPath, arguments: ["rev-parse", "HEAD"],
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
