import Foundation

/// Manages Homebrew package installation and service management.
struct Homebrew {
    /// Every prefix Homebrew installs itself at on this platform: both macOS architectures, or
    /// Linuxbrew's multi-user and single-user locations.
    static var allPrefixes: [String] {
        #if canImport(Darwin)
        ["/opt/homebrew", "/usr/local"]
        #else
        ["/home/linuxbrew/.linuxbrew", Environment.defaultHomeDirectory() + "/.linuxbrew"]
        #endif
    }

    let shell: any ShellRunning
    let environment: Environment

    /// Whether Homebrew is installed and accessible.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: environment.brewPath)
    }

    /// Check if a Homebrew package is installed.
    func isPackageInstalled(_ name: String) -> Bool {
        let result = shell.run(
            environment.brewPath,
            arguments: ["list", name]
        )
        return result.succeeded
    }

    /// A declared name with any tap qualifier stripped: `owner/tap/formula` → `formula`.
    ///
    /// Purely lexical — deliberately not named for the command a formula provides, because no
    /// such function can exist (see `provides`).
    static func bareName(of package: String) -> String {
        URL(fileURLWithPath: package).lastPathComponent
    }

    /// Whether `package` is available on this machine.
    ///
    /// A package name is not reliably a command name, so a PATH miss proves nothing and has to
    /// be settled by asking brew: `ripgrep` installs `rg`, `node@22` and casks install nothing
    /// matching at all. PATH stays the fast path because it costs no subprocess.
    ///
    /// The PATH probe is provenance-blind on purpose — the question is whether the tool is
    /// usable, not whether brew is what put it there. A version manager's `node` satisfies
    /// `brew: node`, and the system `git` satisfies `brew: acme/tools/git`.
    func provides(_ package: String) -> Bool {
        if shell.commandExists(Self.bareName(of: package)) { return true }
        return isPackageInstalled(package)
    }

    /// Install a Homebrew package.
    @discardableResult
    func install(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["install", name])
    }

    /// Uninstall a Homebrew package. May fail if other formulas depend on it.
    @discardableResult
    func uninstall(_ name: String) -> ShellResult {
        shell.run(environment.brewPath, arguments: ["uninstall", name])
    }

    /// What to tell the user about `package` when Homebrew is not installed.
    ///
    /// With no `brew` there is nothing `mcs sync` can do, so the advice must not point back at it
    /// — that loop has no exit. On Linux, Homebrew is the unusual case: the package almost
    /// certainly comes from the distribution's own package manager, so that is what is named.
    static func manualInstallAdvice(for package: String) -> String {
        #if canImport(Darwin)
        "Homebrew not found — install it from https://brew.sh, then re-run 'mcs sync' to get \(package)"
        #else
        "Homebrew not found — install \(package) with your system package manager"
            + " (apt, dnf, pacman, …) or install Homebrew from https://brew.sh"
        #endif
    }

    /// The counterpart of `manualInstallAdvice(for:)` for a package mcs wanted to remove.
    static func manualUninstallAdvice(for package: String) -> String {
        #if canImport(Darwin)
        "Homebrew not found — remove '\(package)' yourself if nothing else needs it"
        #else
        "Homebrew not found — remove '\(package)' with your system package manager if nothing else needs it"
        #endif
    }

    /// Detects the Homebrew formula that provides a command by reading the immediate
    /// symlink target in the Homebrew bin directory. Returns nil if the command isn't
    /// brew-installed.
    ///
    /// Uses single-hop symlink reading (`destinationOfSymbolicLink`) instead of full
    /// resolution because some commands chain through multiple symlinks where the final
    /// target leaves the Cellar path (e.g. npx → Cellar/node/.../npx → lib/node_modules/...).
    static func detectFormula(for command: String) -> String? {
        let fm = FileManager.default
        let basename = bareName(of: command)
        for prefix in allPrefixes {
            let binPath = "\(prefix)/bin/\(basename)"
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: binPath) else { continue }

            let resolved: String = if dest.hasPrefix("/") {
                dest
            } else {
                URL(fileURLWithPath: "\(prefix)/bin")
                    .appendingPathComponent(dest).standardized.path
            }

            let components = resolved.split(separator: "/").map(String.init)
            if let idx = components.firstIndex(of: "Cellar"), idx + 1 < components.count {
                return components[idx + 1]
            }
        }
        return nil
    }
}
