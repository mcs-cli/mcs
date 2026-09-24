import ArgumentParser
import Foundation

struct ValidatePack: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a tech pack for structural correctness and best practices"
    )

    @Argument(help: "Path to pack directory, or installed pack identifier (default: current directory)")
    var source: String?

    func run() throws {
        let ctx = PackCommandContext()
        let packPath = try resolvePackPath(ctx: ctx)

        ctx.output.info("Validating pack at \(packPath.path)...")
        ctx.output.plain("")

        let manifest: ExternalPackManifest
        let loader = ExternalPackLoader(environment: ctx.env, registry: ctx.registry)
        do {
            manifest = try loader.validate(at: packPath)
        } catch {
            ctx.output.error("Invalid pack: \(error.localizedDescription)")
            ctx.output.plain("")
            ctx.output.doctorSummary(passed: 0, fixed: 0, warnings: 0, issues: 1)
            throw ExitCode.failure
        }

        let findings = PackHeuristics.check(manifest: manifest, packPath: packPath)
        let errors = findings.filter { $0.severity == .error }
        let warnings = findings.filter { $0.severity == .warning }

        if findings.isEmpty {
            ctx.output.success("\(manifest.identifier) — all checks passed")
        } else {
            ctx.output.sectionHeader(manifest.identifier)
            ctx.output.plain("")
            for finding in errors {
                ctx.output.error(finding.message)
            }
            for finding in warnings {
                ctx.output.warn(finding.message)
            }
            ctx.output.plain("")
            let passed = errors.isEmpty ? 1 : 0
            ctx.output.doctorSummary(passed: passed, fixed: 0, warnings: warnings.count, issues: errors.count)
        }

        if !errors.isEmpty {
            throw ExitCode.failure
        }
    }

    // MARK: - Source Resolution

    private func resolvePackPath(ctx: PackCommandContext) throws -> URL {
        guard let source else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        // Check filesystem first — URL(fileURLWithPath:) resolves relative paths against CWD
        let resolved = URL(fileURLWithPath: source)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            return resolved
        }

        // Try as installed pack identifier (only if source doesn't look like a path)
        if !source.contains("/") {
            let registryData = try ctx.loadRegistry()
            if let entry = ctx.registry.pack(identifier: source, in: registryData) {
                if let packPath = entry.resolvedPath(packsDirectory: ctx.env.packsDirectory) {
                    return packPath
                }
                ctx.output.error("Pack '\(source)' is registered but its local path is invalid")
                ctx.output.info("Try removing and re-adding the pack: mcs pack remove \(source) && mcs pack add \(entry.sourceURL)")
                throw ExitCode.failure
            }
        }

        ctx.output.error("No pack found at '\(source)'")
        ctx.output.info("Provide a directory path containing techpack.yaml, or an installed pack identifier.")
        throw ExitCode.failure
    }
}
