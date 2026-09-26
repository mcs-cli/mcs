import Foundation

/// Context provided to tech packs during project configuration
struct ProjectConfigContext {
    let projectPath: URL
    let repoName: String
    let output: CLIOutput
    /// Template values resolved by `templateValues(context:)`, available in `configureProject`.
    let resolvedValues: [String: String]
    /// Values resolved during a previous sync, used as defaults when re-prompting.
    /// Empty on first sync. Source: `ProjectState.resolvedValues`.
    let priorValues: [String: String]
    /// When `true`, project-scoped prompts (e.g. `fileDetect`) should be skipped.
    let isGlobalScope: Bool

    init(
        projectPath: URL,
        repoName: String,
        output: CLIOutput,
        resolvedValues: [String: String] = [:],
        priorValues: [String: String] = [:],
        isGlobalScope: Bool = false
    ) {
        self.projectPath = projectPath
        self.repoName = repoName
        self.output = output
        self.resolvedValues = resolvedValues
        self.priorValues = priorValues
        self.isGlobalScope = isGlobalScope
    }
}

/// Template contribution from a tech pack
struct TemplateContribution {
    let sectionIdentifier: String // e.g., "ios"
    let templateContent: String // The template content with placeholders
    let placeholders: [String] // Required placeholder names (e.g., ["__PROJECT__"])
}

/// Protocol that all tech packs must conform to.
/// Packs are applied to projects via `mcs sync`.
/// Doctor and configure only run pack-specific logic for installed packs.
protocol TechPack: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var description: String { get }
    var components: [ComponentDefinition] { get }
    var templates: [TemplateContribution] { get throws }
    /// Section identifiers for template contributions, available without reading
    /// content files from disk. Used for artifact tracking and display.
    var templateSectionIdentifiers: [String] { get }
    /// Doctor checks that cannot be auto-derived from components.
    /// For pack-level or project-level concerns (e.g. Xcode CLT, config files).
    func supplementaryDoctorChecks(projectRoot: URL?) -> [any DoctorCheck]
    func configureProject(at path: URL, context: ProjectConfigContext) throws

    /// Resolve pack-specific placeholder values for CLAUDE.local.md templates.
    /// Called before template substitution so packs can supply values like `__PROJECT__`.
    func templateValues(context: ProjectConfigContext) throws -> [String: String]

    /// Return prompt definitions without executing them.
    /// Used by `CrossPackPromptResolver` to detect duplicate keys across packs.
    func declaredPrompts(context: ProjectConfigContext) -> [PromptDefinition]
}

extension TechPack {
    /// NOTE: This default calls `try? templates` which performs disk I/O and silently
    /// drops errors. Concrete conformers with throwing `templates` should override this
    /// with a lightweight implementation (e.g., ExternalPackAdapter reads from manifest).
    var templateSectionIdentifiers: [String] {
        (try? templates)?.map(\.sectionIdentifier) ?? []
    }

    func templateValues(context _: ProjectConfigContext) -> [String: String] {
        [:]
    }

    func declaredPrompts(context _: ProjectConfigContext) -> [PromptDefinition] {
        []
    }
}

/// Protocol for doctor checks (used by both core and packs)
protocol DoctorCheck: Sendable {
    var section: String { get }
    var name: String { get }
    /// What `fix()` will do, shown in the `doctor --fix` confirmation prompt. Pack fixes show the
    /// verbatim command or script so a pack cannot hide one behind friendly text; built-in fixes
    /// describe their change.
    /// `nil` means the check has no fix of its own: `doctor --fix` then re-syncs its scope when
    /// sync can repair it, and otherwise shows the `.notFixable` hint `fix()` returns.
    var fixCommandPreview: String? { get }
    func check() -> CheckResult
    func fix() -> FixResult
}

extension DoctorCheck {
    var fixCommandPreview: String? {
        nil
    }
}

enum CheckResult {
    case pass(String)
    case fail(String)
    case warn(String)
    case skip(String)
}

enum FixResult {
    case fixed(String)
    case failed(String)
    case notFixable(String)
}
