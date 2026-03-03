import Foundation

/// Writes the exported pack directory: techpack.yaml + supporting files.
struct PackWriter {
    let output: CLIOutput

    /// Write a complete pack directory from a ManifestBuilder.BuildResult.
    /// Cleans up the partial directory if any step fails after creation.
    func write(result: ManifestBuilder.BuildResult, to outputDir: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: outputDir.path) {
            throw ExportError.outputDirectoryExists(outputDir.path)
        }

        do {
            try writeContents(result: result, to: outputDir, fm: fm)
        } catch {
            try? fm.removeItem(at: outputDir)
            throw error
        }
    }

    private func writeContents(result: ManifestBuilder.BuildResult, to outputDir: URL, fm: FileManager) throws {
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // 1. Write techpack.yaml
        let yamlPath = outputDir.appendingPathComponent(Constants.ExternalPacks.manifestFilename)
        try result.manifestYAML.write(to: yamlPath, atomically: true, encoding: String.Encoding.utf8)
        output.success("  Created techpack.yaml")

        // 2. Copy files (hooks, skills, commands)
        for file in result.filesToCopy {
            let destDir = outputDir.appendingPathComponent(file.destinationDir)
            if !fm.fileExists(atPath: destDir.path) {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            }
            let destPath = destDir.appendingPathComponent(file.filename)
            // Resolve symlinks so the exported pack gets actual content, not relative links
            let resolvedSource = file.source.resolvingSymlinksInPath()
            try fm.copyItem(at: resolvedSource, to: destPath)
            output.success("  Copied \(file.destinationDir)/\(file.filename)")
        }

        // 3. Write config/settings.json if needed
        if let settingsData = result.settingsToWrite {
            let configDir = outputDir.appendingPathComponent("config")
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            let settingsPath = configDir.appendingPathComponent("settings.json")
            try settingsData.write(to: settingsPath, options: .atomic)
            output.success("  Created config/settings.json")
        }

        // 4. Write template files
        if !result.templateFiles.isEmpty {
            let templatesDir = outputDir.appendingPathComponent("templates")
            try fm.createDirectory(at: templatesDir, withIntermediateDirectories: true)
            for template in result.templateFiles {
                let templatePath = templatesDir.appendingPathComponent(template.filename)
                try template.content.write(to: templatePath, atomically: true, encoding: String.Encoding.utf8)
                output.success("  Created templates/\(template.filename)")
            }
        }
    }

    /// Preview what would be written without actually writing.
    func preview(result: ManifestBuilder.BuildResult, outputDir: URL) {
        output.header("Export Preview")
        output.plain("  Output directory: \(outputDir.path)")
        output.plain("")

        output.sectionHeader("Files to generate:")
        output.plain("    techpack.yaml")

        for file in result.filesToCopy {
            output.plain("    \(file.destinationDir)/\(file.filename)")
        }

        if result.settingsToWrite != nil {
            output.plain("    config/settings.json")
        }

        for template in result.templateFiles {
            output.plain("    templates/\(template.filename)")
        }

        // Show manifest preview
        output.plain("")
        output.sectionHeader("Generated techpack.yaml:")
        output.plain(result.manifestYAML)
    }
}

// MARK: - Export Errors

enum ExportError: Error, LocalizedError {
    case outputDirectoryExists(String)
    case noConfigurationFound
    case noProjectFound

    var errorDescription: String? {
        switch self {
        case let .outputDirectoryExists(path):
            "Output directory already exists: \(path). Remove it first or choose a different path."
        case .noConfigurationFound:
            "No Claude Code configuration found to export."
        case .noProjectFound:
            "No project root found. Run from a project directory or use --global."
        }
    }
}
