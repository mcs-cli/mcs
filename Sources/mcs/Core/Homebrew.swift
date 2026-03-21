import Foundation

/// Manages Homebrew package installation and service management.
struct Homebrew {
    /// Both Homebrew prefix paths — arm64 and x86_64.
    static let allPrefixes = ["/opt/homebrew", "/usr/local"]

    let shell: ShellRunner
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

    /// Detects the Homebrew formula that provides a command by reading the immediate
    /// symlink target in the Homebrew bin directory. Returns nil if the command isn't
    /// brew-installed.
    ///
    /// Uses single-hop symlink reading (`destinationOfSymbolicLink`) instead of full
    /// resolution because some commands chain through multiple symlinks where the final
    /// target leaves the Cellar path (e.g. npx → Cellar/node/.../npx → lib/node_modules/...).
    static func detectFormula(for command: String) -> String? {
        let fm = FileManager.default
        let basename = URL(fileURLWithPath: command).lastPathComponent
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
