import Foundation

// MARK: - Snapshot

/// A pack's declared surface plus the content hashes of the files it references, captured at a
/// single point in time.
///
/// Exists because `PackFetcher` clones and fetches with `--depth 1`: once `update()` runs
/// `reset --hard`, the previous commit is unreachable and survives only until git gc prunes it.
/// Reading the old manifest back out of the object store (`git show <oldSHA>:techpack.yaml`)
/// therefore works in testing and fails silently on long-lived installs. Capturing the working
/// tree *before* the reset sidesteps the object store entirely — at that moment the old manifest
/// and its files are ordinary files on disk.
struct PackSnapshot {
    let manifest: ExternalPackManifest
    /// Pack-relative path → SHA-256. Keys are normalized via `normalizedPackPath`.
    /// A referenced path that is absent or unreadable is simply missing from the map, which
    /// compares as a difference against a revision where it exists.
    let fileHashes: [String: String]

    /// Read the manifest and hash every file it references.
    ///
    /// - Parameter loader: must be called with the same arguments on both sides of a diff.
    ///   `validate(at:sanitizeOutput:)` only strips `ignore:` entries when `sanitizeOutput` is
    ///   passed, so an asymmetric call would manufacture differences that do not exist.
    static func capture(packPath: URL, loader: ExternalPackLoader) throws -> PackSnapshot {
        let manifest = try loader.validate(at: packPath)
        var hashes: [String: String] = [:]
        for path in manifest.referencedPaths {
            let fileURL = packPath.appendingPathComponent(path)
            do {
                hashes[path] = try FileHasher.sha256(of: fileURL)
            } catch {
                // Absent or unreadable: leave the key out. Its absence on one side and presence
                // on the other is exactly the "changed" signal we want, and a manifest that
                // references a missing file is a pack-validation problem, not a diff problem.
                continue
            }
        }
        return PackSnapshot(manifest: manifest, fileHashes: hashes)
    }
}

// MARK: - Diff

/// What changed in a pack between two revisions, at the granularity a pack author declares:
/// components, template sections, and supplementary doctor checks.
struct PackDiff: Equatable {
    /// One case per author-visible surface of `ExternalPackManifest`. Adding a surface to the
    /// manifest means adding a case here and a `diffKeyed` call in `between` — otherwise the
    /// new surface changes silently, which is the bug this whole type exists to remove.
    enum Kind {
        case component
        case template
        case prompt
        case doctorCheck
        case configureScript

        /// Label used in rendered output.
        var label: String {
            switch self {
            case .component: "component"
            case .template: "template"
            case .prompt: "prompt"
            case .doctorCheck: "doctor check"
            case .configureScript: "configure script"
            }
        }
    }

    enum Change: Equatable {
        case added
        case removed
        /// `path` names the referenced file whose content changed, or is `nil` when the YAML
        /// declaration itself changed. The two are distinguished because they tell the user
        /// different things: a changed script is new behavior, a changed declaration is new wiring.
        case modified(path: String?)

        /// Render order: additions, then modifications, then removals.
        var order: Int {
            switch self {
            case .added: 0
            case .modified: 1
            case .removed: 2
            }
        }

        var marker: String {
            switch self {
            case .added: "+"
            case .modified: "~"
            case .removed: "-"
            }
        }

        func color(style: ANSIStyle) -> String {
            switch self {
            case .added: style.green
            case .modified: style.yellow
            case .removed: style.red
            }
        }
    }

    struct Entry: Equatable {
        let kind: Kind
        let name: String
        let change: Change
    }

    let entries: [Entry]

    var isEmpty: Bool {
        entries.isEmpty
    }

    // MARK: Construction

    /// Compare two snapshots of the same pack.
    ///
    /// Components key on `id`, templates on `sectionIdentifier`, prompts on `key`, doctor checks
    /// on `name` — all post-`normalized()`, so ids read as `ios.lint-hook` rather than
    /// `lint-hook`. Per-component `doctorChecks` are part of a component's own equality, so the
    /// `doctorCheck` kind covers only the manifest-level `supplementaryDoctorChecks`.
    ///
    /// `configureProject` is a scalar, but keying the 0-or-1 element on its script path lets it
    /// use the same mechanism as everything else: repointing the script at a different file
    /// reads as a removal plus an addition, which is what actually happened, and an edit to the
    /// script body is the same key with a different content hash.
    static func between(old: PackSnapshot, new: PackSnapshot) -> PackDiff {
        var entries: [Entry] = []

        entries += diffKeyed(
            kind: .component,
            old: old.manifest.components ?? [],
            new: new.manifest.components ?? [],
            key: \.id,
            changedPath: { oldComponent, newComponent in
                changedPath(
                    newComponent.referencedSource ?? oldComponent.referencedSource,
                    old: old, new: new
                )
            }
        )

        entries += diffKeyed(
            kind: .template,
            old: old.manifest.templates ?? [],
            new: new.manifest.templates ?? [],
            key: \.sectionIdentifier,
            changedPath: { _, newTemplate in
                changedPath(newTemplate.referencedSource, old: old, new: new)
            }
        )

        entries += diffKeyed(
            kind: .prompt,
            old: old.manifest.prompts ?? [],
            new: new.manifest.prompts ?? [],
            key: \.key
        )

        entries += diffKeyed(
            kind: .doctorCheck,
            old: old.manifest.supplementaryDoctorChecks ?? [],
            new: new.manifest.supplementaryDoctorChecks ?? [],
            key: \.name
        )

        entries += diffKeyed(
            kind: .configureScript,
            old: old.manifest.configureProject.map { [$0] } ?? [],
            new: new.manifest.configureProject.map { [$0] } ?? [],
            key: \.referencedSource,
            changedPath: { _, newScript in
                changedPath(newScript.referencedSource, old: old, new: new)
            }
        )

        return PackDiff(entries: entries)
    }

    /// Three-way partition over a keyed collection. `changedPath` is consulted only for items
    /// present on both sides, and only decides *why* something is modified — an item whose
    /// declaration differs is modified regardless of what its files did. It defaults to "this
    /// kind references no files", which is the doctor-check case.
    private static func diffKeyed<T: Equatable>(
        kind: Kind,
        old: [T],
        new: [T],
        key: KeyPath<T, String>,
        changedPath: (T, T) -> String? = { _, _ in nil }
    ) -> [Entry] {
        let oldByKey = Dictionary(old.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { first, _ in first })
        let oldKeys = Set(oldByKey.keys)
        let newKeys = Set(newByKey.keys)

        var entries: [Entry] = []
        for name in newKeys.subtracting(oldKeys).sorted() {
            entries.append(Entry(kind: kind, name: name, change: .added))
        }
        for name in oldKeys.intersection(newKeys).sorted() {
            guard let oldItem = oldByKey[name], let newItem = newByKey[name] else { continue }
            if oldItem != newItem {
                entries.append(Entry(kind: kind, name: name, change: .modified(path: nil)))
            } else if let path = changedPath(oldItem, newItem) {
                entries.append(Entry(kind: kind, name: name, change: .modified(path: path)))
            }
        }
        for name in oldKeys.subtracting(newKeys).sorted() {
            entries.append(Entry(kind: kind, name: name, change: .removed))
        }
        return entries
    }

    /// The path back, when its content hash differs between snapshots; `nil` otherwise.
    private static func changedPath(_ path: String?, old: PackSnapshot, new: PackSnapshot) -> String? {
        guard let path, old.fileHashes[path] != new.fileHashes[path] else { return nil }
        return path
    }

    // MARK: Rendering

    /// Default number of change lines shown before truncating. A pack rewrite can touch dozens
    /// of components, and `mcs update` renders one of these per updated pack.
    static let defaultRenderLimit = 10

    /// Indented change lines, grouped added → modified → removed, for printing under the
    /// existing "updated" success line. Returns `""` when there is nothing to show.
    ///
    /// - Parameter indent: leading whitespace, so the block nests under its pack line in both
    ///   `mcs pack update` (flush-left pack lines) and `mcs update` (already indented).
    func render(style: ANSIStyle, indent: String = "  ", limit: Int = defaultRenderLimit) -> String {
        guard !isEmpty else { return "" }

        // Grouped rather than sorted: `sorted(by:)` is not stable, and the within-group order is
        // already alphabetical from `diffKeyed`. `Dictionary(grouping:)` preserves that order
        // inside each bucket, and deriving the ranks from the entries means nothing here has to
        // know how many `Change` cases exist.
        let byRank = Dictionary(grouping: entries, by: \.change.order)
        let ordered = byRank.keys.sorted().flatMap { byRank[$0] ?? [] }
        var lines = ordered.prefix(limit).map { entry -> String in
            let change = entry.change
            var line = "\(indent)\(change.color(style: style))\(change.marker)\(style.reset)"
                + " \(entry.kind.label): \(entry.name)"
            // Suppressed when the entry is already named by its path (the configure script),
            // where the suffix would just repeat the name back.
            if case let .modified(path) = change, let path, path != entry.name {
                line += " \(style.dim)(\(path) changed)\(style.reset)"
            }
            return line
        }

        let hidden = ordered.count - lines.count
        if hidden > 0 {
            lines.append("\(indent)\(style.dim)… and \(hidden) more change\(hidden == 1 ? "" : "s")\(style.reset)")
        }
        return lines.joined(separator: "\n")
    }
}
