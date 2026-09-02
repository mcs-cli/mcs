---
name: techpack-creator
description: >-
  Scan a repository that already has Claude Code configuration (hooks, skills, CLAUDE.md, settings,
  MCP servers) and package it into a valid MCS techpack.yaml for distribution via mcs. Use this skill
  whenever the user wants to create a tech pack from an existing repo, convert a Claude Code setup
  into a shareable MCS pack, scaffold a techpack.yaml, or package their dev environment for
  distribution. Also use when the user asks to "pack" a project, wants to make their Claude Code
  config reusable, or needs to turn a repo with .claude/ config into an installable tech pack. Even
  if they don't say "tech pack" explicitly — if they want to distribute Claude Code configuration via
  MCS, this is the skill to use. Note: this is different from `mcs export` which captures a live
  running config — this skill analyzes a repo's existing files and structure.
---

# TechPack Creator

You analyze repositories that already have Claude Code configuration and package them into MCS tech
packs for distribution. A tech pack is a Git-distributable bundle of Claude Code configuration — MCP
servers, hooks, skills, commands, agents, templates, and settings — defined in a single
`techpack.yaml` manifest that the `mcs` CLI syncs and maintains.

**Two approaches** — choose based on what's available:

1. **`mcs export` first (recommended when MCS is installed)**: Run `mcs export ./pack-output` to
   capture the live Claude Code configuration as a starting point. Then review and improve the
   generated `techpack.yaml` — add dependencies between components, add prompts for env vars, add
   doctor checks, and wire up templates. This is the fastest path when the user already has a
   working Claude Code session.

2. **Direct scan (when no live config or MCS is not installed)**: Analyze the repo's files and
   directory structure directly — read hook scripts, skill directories, command files, settings JSON,
   CLAUDE.md content, and project manifests to understand what the repo provides. Generate the
   `techpack.yaml` and supporting files from scratch.

Both approaches produce the same output: a complete pack directory ready for `mcs pack add`.

**Bundled references** (read on demand, not upfront):
- `references/techpack-schema.md` — Complete field-by-field schema for `techpack.yaml`
- `references/stack-detection.md` — File-to-stack mapping and component recommendations
- `references/examples/` — Realistic example techpacks (swift-ios.yaml, node-web.yaml, python-ml.yaml)

**Remote documentation** — use these for the latest info and link them in generated READMEs:
- MCS CLI: https://github.com/mcs-cli/mcs
- Schema reference: https://github.com/mcs-cli/mcs/blob/main/docs/techpack-schema.md
- Creating tech packs guide: https://github.com/mcs-cli/mcs/blob/main/docs/creating-tech-packs.md
- Claude Code hooks: https://docs.anthropic.com/en/docs/claude-code/hooks
- MCS CLI reference: https://github.com/mcs-cli/mcs/blob/main/docs/cli.md
- MCS troubleshooting: https://github.com/mcs-cli/mcs/blob/main/docs/troubleshooting.md

If the bundled references are unavailable (skill installed without reference files), fetch the remote
documentation using WebFetch on the URLs above. The remote docs are the canonical source of truth.

## Workflow

First, determine which approach to use:

- If the user has MCS installed and a working Claude Code session → start with **`mcs export`**:
  ```bash
  mcs export ./pack-output          # project-scoped config
  mcs export ./pack-output --global # global-scoped config
  ```
  Then review the generated `techpack.yaml` and improve it (add dependencies, prompts, doctor
  checks, templates). Skip to Phase 3 (Propose) with the export output as your starting point.

- If no live config is available → follow the full 5-phase workflow below.

Follow these 5 phases in order. Never skip the Propose phase.

### Phase 1: Scan

Analyze the target directory. Read files in parallel when possible.

**Existing Claude Code config** — this is the PRIMARY source of truth. Scan first:
- `.claude/hooks/*` — existing hook scripts (read each one to understand its event and purpose)
- `.claude/skills/*/SKILL.md` — existing skills (read frontmatter for name, description)
- `.claude/commands/*.md` — existing slash commands
- `.claude/agents/*.md` — existing subagents
- `.claude/settings.json`, `.claude/settings.local.json` — existing settings (permissions, env vars, hooks config)
- `.claude.json` — existing MCP server registrations
- `CLAUDE.md`, `CLAUDE.local.md` — existing instructions (extract sections for templates)

**Settings cross-reference** — read `settings.json`/`settings.local.json` to map hooks to events:
```json
{"hooks": {"SessionStart": [{"command": "bash .claude/hooks/session_start.sh"}]}}
```
This tells you which hook file maps to which event — critical for the `hookEvent` field. The
command is `<interpreter> <path>`: everything before the path is the interpreter, so
`node --experimental-strip-types .claude/hooks/gate.ts` becomes
`hookInterpreter: node --experimental-strip-types`. Omit `hookInterpreter` when it is plain `bash`
or matches what the extension already implies.

**Project manifests** — detect language and dependencies:
`Package.swift`, `*.xcodeproj`, `*.xcworkspace`, `package.json`, `tsconfig.json`, `Cargo.toml`,
`go.mod`, `Gemfile`, `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile`, `build.gradle`,
`build.gradle.kts`, `pom.xml`, `composer.json`, `pubspec.yaml`, `CMakeLists.txt`, `*.csproj`, `*.sln`

**Configuration files** — detect tooling:
`.eslintrc*`, `.prettierrc*`, `biome.json`, `.swiftlint.yml`, `.swiftformat`, `rustfmt.toml`,
`.rubocop.yml`, `.flake8`, `ruff.toml`, `docker-compose.yml`, `Dockerfile`, `.github/workflows/*.yml`,
`Fastfile`, `.env`, `.env.example`

**Repository metadata**: `README.md`, `LICENSE`, git remote URL

Consult `references/stack-detection.md` for additional file-to-stack mapping recommendations.

### Phase 2: Detect

Build a detection report from scan results:

```
## Detection Report

**Repository**: {name}
**Primary language**: {language}
**Framework(s)**: {frameworks}
**Package manager(s)**: {managers}
**Build system**: {build system}
**Existing Claude Code config**: {yes/no, summary}

### Recommended Components
| Component | Type | Rationale |
|-----------|------|-----------|
| node      | brew | Required by MCP servers using npx |
| ...       | ...  | ... |

### Recommended Prompts
| Key | Type | Rationale |
|-----|------|-----------|
| API_KEY | input | Found in .env.example |
| ...     | ...   | ... |

### Recommended Templates
| Section | Content | Rationale |
|---------|---------|-----------|
| build-test | Build & test commands | Detected from package.json scripts |
| ...        | ...                   | ... |
```

### Phase 3: Propose

Present the detection report. Ask for confirmation before generating:

1. Show the detection report and ask if the user wants to proceed or modify
2. Ask for the pack **identifier** (suggest one based on repo name — lowercase, hyphens only)
3. Ask for the **display name** and **author** (suggest from git config)
4. Confirm the **output directory** (default: current directory)

Do NOT generate files without explicit user confirmation.

### Phase 4: Generate

Read `references/techpack-schema.md` now for the complete schema. If the bundled reference is
unavailable, fetch the remote version: https://github.com/mcs-cli/mcs/blob/main/docs/techpack-schema.md

Generate the pack directory:

```
{pack-name}/
  techpack.yaml          # Main manifest
  README.md              # Installation instructions
  hooks/                 # Hook scripts (if any)
  templates/             # Template markdown files (if any)
  config/                # Settings JSON (if any)
  commands/              # Slash command files (if any)
  skills/                # Skill directories (if any)
  agents/                # Agent files (if any)
  scripts/               # Configure scripts (if any)
```

#### YAML Generation Rules

1. **Always use shorthand syntax** — `brew: node` not verbose `type`/`installAction`
2. **schemaVersion must be 1**
3. **identifier**: lowercase alphanumeric + hyphens, no leading hyphen
4. **Component IDs**: short names, NO dots (MCS auto-prefixes with `<pack-id>.`)
5. **YAML field ordering**:
   - Root: schemaVersion → identifier → displayName → description → author → prompts → components → templates → supplementaryDoctorChecks → configureProject → ignore
   - Components grouped: brew first → MCP servers → hooks → skills → commands → agents → settings → gitignore
   - Each component: id → displayName → description → dependencies → isRequired → hookEvent/hookMatcher/hookTimeout/hookAsync/hookStatusMessage/hookInterpreter → shorthand key
6. **Dependencies**: Always declare them. `npx` MCP servers depend on `node`. `uvx`/`python` servers depend on `python`. Hooks using `jq` depend on `jq`.
7. **isRequired: true** for settings and gitignore components
8. **MCP scope**: default to `local` (per-user, per-project isolation)
9. **Prompts before components** in the YAML for readability
10. **Placeholders**: `__UPPER_SNAKE__` format. Every `__KEY__` used in templates/settings MUST have a matching prompt
11. **Populate `ignore:` for non-material paths**: When the source repo contains `docs/`, `examples/`, design assets, screenshots, or any directories not referenced by a component/template, add them to a top-level `ignore:` list (POSIX globs, trailing `/` silences the directory tree). This silences `mcs pack validate` unreferenced-file warnings AND stops downstream "pack update available" notifications from firing on doc/CI commits. Never put `techpack.yaml` or referenced paths in `ignore:` — `mcs pack validate` rejects those. Example: `ignore: [docs/, examples/, diagrams/*.png]`.

#### Hook Script Template

Hooks are not bash-only. The interpreter follows the file extension (`.js`/`.mjs` → `node`,
`.py` → `python3`, `.rb` → `ruby`, `.sh`/no extension → `bash`); declare `hookInterpreter` for
anything else, including arguments (`node --experimental-strip-types`, `uv run`). TypeScript
infers nothing — always declare it there. Prefer `bash` when the logic is simple: it is the one
runtime guaranteed to exist. Whatever the language, declare a brew component for the runtime and
fail open on every error path.

Every hook script must follow this defensive pattern (hooks must NEVER crash the session):

```bash
#!/bin/bash
set -euo pipefail
trap 'exit 0' ERR

# {description}
# Hook event: {event}

# Fail gracefully if dependencies are missing
command -v {tool} >/dev/null 2>&1 || exit 0

# Read and validate JSON input from stdin (required for most hooks)
input_data=$(cat) || exit 0
echo "$input_data" | jq '.' >/dev/null 2>&1 || exit 0

# ... hook logic ...
```

**SessionStart hooks that produce output** must emit the `hookSpecificOutput` JSON contract:

```bash
jq -n --arg ctx "$context" '{
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $ctx }
}'
```

**UserPromptSubmit hooks** can print plain text to stdout — it appears as a system reminder.

**Two hooks can share one source file** when they need the same logic for different events
(e.g., SessionStart + UserPromptSubmit both running a sync/reindex script).

#### Template Content

Templates should be concise, actionable CLAUDE.local.md instructions:

```markdown
## {Section Title}

{2-5 lines of project-specific context}

### Build & Test
- `{build command}` — build the project
- `{test command}` — run tests

### Conventions
- {convention from detected linter/formatter config}
```

#### Settings File

Always include baseline settings in `config/settings.json`:

```json
{
  "permissions": {
    "defaultMode": "plan"
  }
}
```

Add env vars only when detected from `.env.example` or similar — use `__KEY__` placeholders with matching prompts.

#### README.md

Generate a README with:
- Pack description
- Prerequisites (list brew dependencies)
- Installation: `mcs pack add <github-user>/<repo>` (or `mcs pack add /path/to/pack` for local)
- What it installs (component summary table)
- Configuration (prompt descriptions — what the user will be asked during `mcs sync`)
- Validation: `mcs pack validate <path>`
- Links to MCS documentation:
  - MCS CLI: https://github.com/mcs-cli/mcs
  - Schema: https://github.com/mcs-cli/mcs/blob/main/docs/techpack-schema.md
  - Guide: https://github.com/mcs-cli/mcs/blob/main/docs/creating-tech-packs.md
  - Troubleshooting: https://github.com/mcs-cli/mcs/blob/main/docs/troubleshooting.md

### Phase 5: Validate

After generating, perform a self-check:

1. **Schema**: Does the YAML match the schema in `references/techpack-schema.md`?
2. **File references**: Every `source` path points to a file that was actually created
3. **Dependencies**: Every ID in `dependencies` exists as a component
4. **Placeholders**: Every `__KEY__` in templates/settings has a corresponding prompt
5. **ID uniqueness**: No duplicate component IDs or prompt keys
6. **Hook metadata**: `hookMatcher`/`hookTimeout`/`hookAsync`/`hookStatusMessage`/`hookInterpreter` require `hookEvent`
7. **Shell shorthand**: Any `shell:` component has an explicit `type:` field
8. **No dots in IDs**: Component IDs and template sectionIdentifiers contain no dots

Report any issues found. Then suggest:
```bash
mcs pack validate {path}
```

## Audit Mode

When the target directory already has a `techpack.yaml`:

1. Parse the existing manifest
2. Run the same scan as Phase 1
3. Compare detected components against existing ones
4. Report:
   - **Missing**: Detected in repo but absent from pack
   - **Stale**: In pack but no longer detected
   - **Improvements**: Missing dependencies, missing doctor checks, env vars without prompts
   - **Schema**: Verbose syntax that could use shorthand
5. Offer to generate an updated manifest preserving existing structure

## Real-World Patterns

These patterns come from production tech packs and should be followed:

### Homebrew Packages (Never Install Homebrew Itself)
Packs should only install Homebrew *packages* via `brew: <name>`. Never include a component that
installs Homebrew itself — it requires interactive `sudo` and will fail in non-interactive `mcs sync`.
Assume Homebrew is already installed. If you want to verify it, add a supplementary doctor check:
```yaml
supplementaryDoctorChecks:
  - type: commandExists
    name: Homebrew
    section: Prerequisites
    command: brew
    fixCommand: '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
```
This way `mcs doctor` will detect the missing Homebrew and show the fix command, but won't try to
run it automatically during sync.

### External Skills via Shell
Skills from a registry (not bundled in the pack) use `type: skill` + `shell:`:
```yaml
- id: skill-xcodebuildmcp
  description: XcodeBuildMCP skill for Xcode integration
  type: skill
  dependencies: [xcodebuildmcp]
  shell: "npx -y skills add cameroncooke/xcodebuildmcp -g -a claude-code -y"
```

### Doctor Check for Running Services
Use `commandExists` with `args` to verify HTTP services:
```yaml
doctorChecks:
  - type: commandExists
    name: "Ollama service running"
    section: AI Models
    command: curl
    args: ["-sf", "http://localhost:11434/api/tags"]
    fixCommand: "brew services start ollama"
```

### Command-to-Plugin Dependencies
Slash commands that rely on plugins should declare the dependency:
```yaml
- id: command-review-pr
  description: PR review command
  dependencies: [gh, plugin-pr-review-toolkit]
  command:
    source: commands/review-pr.md
    destination: review-pr.md
```

### Placeholders in Commands and Templates
`__KEY__` placeholders work in copyPackFile artifacts too (hooks, commands, skills) — not just
templates and settings. Use this for branch prefixes, project paths, etc.

## Common Mistakes to Avoid

- Adding dots to component IDs (MCS auto-prefixes — write `node`, not `my-pack.node`)
- Forgetting `hookEvent` on hook components (the hook won't register in settings)
- Using `shell:` without an explicit `type:` field
- Adding MCP servers speculatively — only include servers with clear evidence of need
- Duplicating auto-derived doctor checks (brew, mcp, plugin, hook, skill, command, agent all get free checks)
- Using `source: "."` in copyPackFile (copies entire repo root — always an error)
- Forgetting `isRequired: true` on settings/gitignore components
- Writing hooks that can crash — always use `set -euo pipefail` + `trap 'exit 0' ERR`
- Forgetting to validate JSON stdin in hooks (`cat` + `jq` validation pattern)

## MCP Server Selection

Only add MCP servers when the repo clearly needs them. Consult `references/stack-detection.md`
for the mapping. When in doubt, ask the user rather than guessing.

Do NOT add MCP servers speculatively. The user can always add more later via `mcs sync --customize`.
