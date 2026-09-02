# TechPack Schema Reference

Complete field-by-field reference for `techpack.yaml`. This file is self-contained — it has
everything needed to generate valid manifests without access to the MCS source code.

**Canonical sources:**
- Schema: https://github.com/mcs-cli/mcs/blob/main/docs/techpack-schema.md
- Guide: https://github.com/mcs-cli/mcs/blob/main/docs/creating-tech-packs.md
- Claude Code hooks: https://docs.anthropic.com/en/docs/claude-code/hooks

## Table of Contents

1. [Top-Level Fields](#top-level-fields)
2. [Components](#components)
3. [Shorthand Keys](#shorthand-keys)
4. [Verbose Install Actions](#verbose-install-actions)
5. [Templates](#templates)
6. [Prompts](#prompts)
7. [Doctor Checks](#doctor-checks)
8. [Configure Project](#configure-project)
9. [Validation Rules](#validation-rules)
10. [Heuristic Checks](#heuristic-checks)
11. [The `ignore:` field](#the-ignore-field)
12. [Pack Directory Convention](#pack-directory-convention)

---

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | Integer | Yes | Must be `1` |
| `identifier` | String | Yes | Unique pack ID. Lowercase alphanumeric + hyphens, cannot start with hyphen. Regex: `^[a-z0-9][a-z0-9-]*$` |
| `displayName` | String | Yes | Human-readable name shown in CLI output |
| `description` | String | Yes | One-line description of what the pack provides |
| `author` | String | No | Pack author name |
| `minMCSVersion` | String | No | Minimum `mcs` version required, e.g. `"2026.3.0"` |
| `components` | [Component] | No | Installable components |
| `templates` | [Template] | No | CLAUDE.local.md section contributions |
| `prompts` | [Prompt] | No | Interactive prompts for `mcs sync` |
| `configureProject` | Object | No | Script to run after project configuration |
| `supplementaryDoctorChecks` | [DoctorCheck] | No | Pack-level health checks |
| `ignore` | [String] | No | POSIX-glob paths the engine treats as non-material — silences `mcs pack validate` warnings AND prevents `mcs check-updates` from firing on commits limited to these paths. Cannot include `techpack.yaml` or any referenced component/template path. Trailing `/` silences the whole directory tree. Example: `["docs/", "examples/", "diagrams/*.png"]` |

---

## Components

Each component represents something MCS can install, verify, and uninstall.

### Common Fields (all component types)

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | String | Yes | Short name, NO dots. Auto-prefixed with `<pack-identifier>.` by MCS |
| `description` | String | Yes | One-line description |
| `displayName` | String | No | Display name (defaults to `id`) |
| `dependencies` | [String] | No | Component IDs. Short IDs auto-prefixed for intra-pack. Use `other-pack.id` for cross-pack |
| `isRequired` | Boolean | No | If `true`, cannot be deselected in `--customize` mode |
| `hookEvent` | String | No | Claude Code lifecycle event for hook registration |
| `hookMatcher` | String | No | Regex to filter when hook fires (e.g., tool name). Requires `hookEvent` |
| `hookTimeout` | Integer | No | Seconds before cancel. Requires `hookEvent` |
| `hookAsync` | Boolean | No | Run hook in background. Requires `hookEvent` |
| `hookStatusMessage` | String | No | Custom spinner message. Requires `hookEvent` |
| `hookInterpreter` | String | No | Command the script runs under (`node`, `python3`, `uv run`). Defaults to the extension's interpreter, else `bash`. Requires `hookEvent` |
| `doctorChecks` | [DoctorCheck] | No | Custom health checks for this component |

### Component Types

| YAML value | Meaning |
|------------|---------|
| `mcpServer` | MCP server |
| `plugin` | Claude Code plugin |
| `skill` | Skill directory |
| `hookFile` | Hook script file |
| `command` | Slash command file |
| `agent` | Subagent file |
| `brewPackage` | Homebrew package |
| `configuration` | Settings/gitignore/etc |

---

## Shorthand Keys

Always prefer shorthand over verbose form. Each key infers `type` and `installAction` automatically (except `shell:`).

### `brew: <package-name>`

Installs a Homebrew package. Infers `type: brewPackage`.

```yaml
- id: node
  description: JavaScript runtime
  brew: node
```

### `mcp:` — MCP Server

Infers `type: mcpServer`. Transport is auto-detected: `url` present = HTTP, otherwise stdio.

```yaml
# Stdio transport
- id: my-server
  description: Code analysis
  dependencies: [node]
  mcp:
    command: npx
    args: ["-y", "my-server@latest"]
    env:
      API_KEY: "__API_KEY__"
    scope: local

# HTTP transport
- id: remote-server
  description: Cloud server
  mcp:
    url: https://example.com/mcp
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | String | No | Server name (defaults to component id). Never substituted by placeholders |
| `command` | String | Stdio only | Command to run (e.g. `npx`, `uvx`) |
| `args` | [String] | No | Command arguments |
| `env` | {String: String} | No | Environment variables. Supports `__KEY__` placeholders |
| `url` | String | HTTP only | Server URL |
| `scope` | String | No | `local` (default), `project`, or `user` |

`__KEY__` placeholders in `env` values, `command`, and `args` are substituted with resolved prompt
values during `mcs sync`. The server `name` is never substituted.

### `plugin: "name@org"`

Installs a Claude Code plugin. Infers `type: plugin`.

```yaml
- id: my-plugin
  description: Helpful plugin
  plugin: "my-plugin@my-org"
```

### `hook: {source, destination}`

Copies a hook script file. Infers `type: hookFile`. Combine with `hookEvent` to register in settings.

```yaml
- id: session-hook
  description: Session start hook
  hookEvent: SessionStart
  hookMatcher: "startup"
  hookTimeout: 30
  hookAsync: true
  hookStatusMessage: "Initializing..."
  hook:
    source: hooks/session_start.sh
    destination: session_start.sh
```

- `source`: path to script in the pack repo
- `destination`: filename in `<project>/.claude/hooks/`, always namespaced under `<pack-id>/`
- MUST set `hookEvent` at component level to register the hook in settings
- `hookMatcher` is a regex that filters when the hook fires (e.g., tool name for `PreToolUse`)

**Interpreter.** The registered command is `<interpreter> <path>`. Resolution order:
`hookInterpreter` → the extension's interpreter → `bash`.

| Extension | Interpreter |
|-----------|-------------|
| `.sh`, `.bash`, none | `bash` |
| `.zsh` | `zsh` |
| `.js`, `.mjs`, `.cjs` | `node` |
| `.py` | `python3` |
| `.rb` | `ruby` |
| `.pl` | `perl` |
| `.ts`, `.mts`, `.cts`, `.tsx` | none — declare `hookInterpreter` |

```yaml
- id: gate-hook
  description: Blocks risky tool calls
  hookEvent: PreToolUse
  hookInterpreter: node --experimental-strip-types --disable-warning=ExperimentalWarning
  hook:
    source: hooks/gate.ts
    destination: gate.ts
```

Accepts a bare command, an absolute path, and plain arguments. Rejects shell metacharacters,
control characters and relative paths — use a wrapper script for anything more complex, or when the
interpreter only exists inside a version manager (nvm, pyenv, mise), since Claude Code may not see
that `PATH`. A non-default interpreter is part of the pack's trust prompt, and changing it in a
later version asks the user for renewed trust.

### `command: {source, destination}`

Copies a slash command file. Infers `type: command`.

```yaml
- id: pr-command
  description: Create pull requests
  command:
    source: commands/pr.md
    destination: pr.md
```

### `skill: {source, destination}`

Copies a skill directory. Infers `type: skill`.

```yaml
- id: my-skill
  description: Domain knowledge
  skill:
    source: skills/my-skill
    destination: my-skill
```

- `source`: path to skill directory (must contain `SKILL.md`)
- `destination`: directory name under `<project>/.claude/skills/`

### `agent: {source, destination}`

Copies a subagent markdown file. Infers `type: agent`.

```yaml
- id: code-reviewer
  description: Code review subagent
  agent:
    source: agents/code-reviewer.md
    destination: code-reviewer.md
```

### `settingsFile: <path>`

Merges a JSON settings file. Infers `type: configuration`.

```yaml
- id: settings
  description: Claude Code configuration
  isRequired: true
  settingsFile: config/settings.json
```

The settings file is deep-merged into `<project>/.claude/settings.local.json`.
`__KEY__` placeholders in JSON values are substituted before parsing.

### `gitignore: [entries]`

Adds patterns to the global gitignore. Infers `type: configuration`.

```yaml
- id: gitignore
  description: Global gitignore entries
  isRequired: true
  gitignore:
    - .claude/memories
    - .claude/settings.local.json
    - .claude/.mcs-project
```

### `shell: "command"` — REQUIRES explicit `type:`

Runs a shell command. This is the ONLY shorthand that does NOT infer `type`. You must provide `type:` explicitly. No auto-derived doctor check — add `doctorChecks` manually.

**Important**: Never use `shell:` to install Homebrew itself — it requires interactive `sudo`.
Only use `brew:` shorthand for Homebrew packages (assumes Homebrew is already installed).

```yaml
- id: ollama-model
  description: Pull embedding model
  type: configuration
  shell: "ollama pull nomic-embed-text"
  doctorChecks:
    - type: commandExists
      name: nomic-embed-text model
      section: AI Models
      command: ollama
      args: ["show", "nomic-embed-text"]
```

---

## Verbose Install Actions

The explicit form with `type` + `installAction` is always supported but rarely needed:

| `type` | Fields | Description |
|--------|--------|-------------|
| `mcpServer` | `name`, `command`, `args`, `env`, `transport`, `url`, `scope` | Register MCP server |
| `plugin` | `name` | Install Claude Code plugin |
| `brewInstall` | `package` | Install Homebrew package |
| `shellCommand` | `command` | Run shell command |
| `gitignoreEntries` | `entries` | Add to global gitignore |
| `settingsMerge` | *(none)* | Merge settings (internal) |
| `settingsFile` | `source` | Merge settings from file |
| `copyPackFile` | `source`, `destination`, `fileType` | Copy file from pack |

`fileType` values: `skill`, `hook`, `command`, `agent`, `generic`

---

## Templates

Templates inject content into `CLAUDE.local.md` sections using `<!-- mcs:begin/end -->` markers.

```yaml
templates:
  - sectionIdentifier: instructions
    contentFile: templates/instructions.md
    placeholders:
      - __PROJECT__
      - __FRAMEWORK__
    dependencies: [my-server]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sectionIdentifier` | String | Yes | Short name, NO dots. Auto-prefixed with `<pack>.` |
| `contentFile` | String | Yes | Path to markdown file in the pack repo |
| `placeholders` | [String] | No | `__PLACEHOLDER__` tokens used in the template |
| `dependencies` | [String] | No | Component IDs — section only injected when these are installed |

### Built-in Placeholders (always available)

| Placeholder | Description |
|---|---|
| `__REPO_NAME__` | Repo name from `git remote get-url origin` (fallback: directory name) |
| `__PROJECT_DIR_NAME__` | Project directory name |

### Section Markers

Templates are wrapped in HTML comments in `CLAUDE.local.md`:

```markdown
<!-- mcs:begin my-pack.instructions -->
(template content here)
<!-- mcs:end my-pack.instructions -->
```

Content outside markers is preserved. Re-running `mcs sync` updates only managed sections.

---

## Prompts

Prompts gather values during `mcs sync`. Values become `__KEY__` placeholders in templates, settings,
and MCP env vars, and `MCS_RESOLVED_KEY` environment variables in scripts.

```yaml
prompts:
  - key: PROJECT
    type: fileDetect
    label: "Xcode project"
    detectPattern:
      - "*.xcodeproj"
      - "*.xcworkspace"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `key` | String | Yes | Unique key. Becomes `__KEY__` placeholder |
| `type` | String | Yes | `fileDetect`, `input`, `select`, or `script` |
| `label` | String | No | Human-readable prompt label |
| `default` | String | No | Default value for `input` type |
| `detectPattern` | String or [String] | fileDetect | Glob pattern(s) to match files |
| `options` | [{value, label}] | select | Choices for select prompts |
| `scriptCommand` | String | script | Shell command whose stdout becomes the value |

### Prompt Types

| Type | Behavior |
|------|----------|
| `fileDetect` | Scans project for files matching glob. Auto-selects if 1 match, picker if multiple. Filtered out in global scope. |
| `input` | Free-text input with optional default |
| `select` | Choose from predefined options |
| `script` | Runs shell command, stdout = value |

### Cross-Pack Deduplication

When multiple packs declare prompts with the same `key`, MCS asks the user once. Only `input` and
`select` prompts are deduplicated. `fileDetect` and `script` always run per-pack.

---

## Doctor Checks

Doctor checks verify pack health. Two levels:
1. **Per-component**: `doctorChecks` field on a component
2. **Pack-level**: `supplementaryDoctorChecks` at root

### Common Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | String | Yes | Check type (see below) |
| `name` | String | Yes | Display name in doctor output |
| `section` | String | No | Grouping label |
| `fixCommand` | String | No | Shell command for `mcs doctor --fix` |
| `fixScript` | String | No | Path to fix script |
| `scope` | String | No | `global` or `project` |
| `isOptional` | Boolean | No | If `true`, failure = warning not error |

### Check Types

| Type | Required Fields | Description |
|------|----------------|-------------|
| `commandExists` | `command`, optional `args` | Without `args`: PATH check. With `args`: runs command, checks exit code |
| `fileExists` | `path` | File exists? |
| `directoryExists` | `path` | Directory exists? |
| `fileContains` | `path`, `pattern` | Regex match in file |
| `fileNotContains` | `path`, `pattern` | Regex NOT in file |
| `shellScript` | `command` | Exit: 0=pass, 1=fail, 2=warn, 3=skip |
| `hookEventExists` | `event` | Hook event registered in settings? |
| `settingsKeyEquals` | `keyPath`, `expectedValue` | Settings JSON key check |

### Auto-Derived Checks (do NOT duplicate)

| Shorthand | Auto check |
|-----------|-----------|
| `brew: X` | `commandExists` for X |
| `mcp: {...}` | MCP server registered |
| `plugin: "..."` | Plugin enabled |
| `hook: {...}` | Hook file exists + interpreter binary resolves (not for bash/sh/zsh) |
| `skill: {...}` | Skill directory exists |
| `command: {...}` | Command file exists |
| `agent: {...}` | Agent file exists |
| `settingsFile: path` | Always re-applied (convergent) |
| `gitignore: [...]` | Always re-applied (convergent) |
| `shell: "..."` | **NONE** — add `doctorChecks` manually |

---

## Configure Project

```yaml
configureProject:
  script: scripts/configure.sh
```

The script receives environment variables:

| Variable | Description |
|----------|-------------|
| `MCS_PROJECT_PATH` | Absolute path to the project root |
| `MCS_RESOLVED_<KEY>` | Resolved prompt values (uppercased key) |

---

## Validation Rules

### Structural (enforced on load)

- `schemaVersion` must be `1`
- `identifier` must match `^[a-z0-9][a-z0-9-]*$`
- Component `id`: NO dots (auto-prefixed), must be unique within the pack
- Template `sectionIdentifier`: NO dots (auto-prefixed)
- Intra-pack dependency references must resolve to existing component IDs
- Prompt `key` values must be unique
- Doctor check required fields must be present and non-empty
- `hookTimeout` must be a positive integer
- `hookMatcher`, `hookTimeout`, `hookAsync`, `hookStatusMessage`, `hookInterpreter` all require `hookEvent` to be set
- `hookInterpreter` must be a bare command or absolute path plus plain arguments — no shell
  metacharacters, no relative paths
- `shell:` shorthand requires explicit `type:` field

### File References

- Template `contentFile` must exist in pack directory, no `../` traversal
- `copyPackFile` `source` must exist, no `../` traversal, no `"."` root copy
- `settingsFile` source must exist in pack directory
- `configureProject` script must exist in pack directory

---

## Heuristic Checks

`mcs pack validate` runs these after structural validation:

### Errors (exit code 1)

| Check | Trigger |
|-------|---------|
| Empty pack | No components, templates, or configureProject |
| Root source copy | `copyPackFile` source is `"."` or `"./"` |
| Missing settings file | `settingsFile:` references non-existent file |

### Warnings (exit code 0)

| Check | Trigger |
|-------|---------|
| Unreferenced subdirectory files | Files in subdirs not referenced by any component/template |
| Unreferenced root-level files | Non-infrastructure root files not referenced |
| MCP dependency gap | MCP uses python/node command but no matching brew component |
| Missing python module | `python -m <module>` but no `<module>/` directory |

Infrastructure files never flagged: `techpack.yaml`, `README.md`, `README`, `LICENSE`, `LICENSE.md`,
`CHANGELOG.md`, `CONTRIBUTING.md`, `.gitignore`, `.editorconfig`, `package.json`, `package-lock.json`,
`requirements.txt`, `Makefile`, `Dockerfile`, `.dockerignore`

Ignored directories: `.git`, `.github`, `.gitlab`, `.vscode`, `node_modules`, `__pycache__`, `.build`

---

## The `ignore:` field

Top-level optional list that extends the engine's built-in deny-list of "non-material" paths. One declaration drives two behaviors:

- `mcs check-updates` (and the SessionStart hook) treats matching paths as non-material, so README/CI/docs-only commits don't trigger downstream "pack update available" notifications.
- `mcs pack validate` no longer warns about matching paths as unreferenced files.

```yaml
ignore:
  - docs/
  - examples/
  - diagrams/*.png
```

### Semantics

- **Extends the built-ins**, never replaces. Built-in deny-list (README, LICENSE, CHANGELOG, `.github/`, `node_modules/`, `.build/`, etc.) always applies.
- **POSIX glob syntax** via `fnmatch`: `*` (no `/` crossing), `?`, `[abc]`. **No `**` recursion** — POSIX globs only.
- **Trailing `/` silences the entire directory tree.** `docs/` matches `docs`, `docs/guide.md`, `docs/sub/deep.md`. Without the trailing slash, `docs/*` only matches one level deep.

### Forbidden entries (rejected glob-aware)

`mcs pack validate` rejects with a hard error; the runtime sync loader strips with a warning. Both checks are glob-aware — `*.yaml`, `hooks/*`, or `hooks/` are rejected when they would silence load-bearing files:

- `techpack.yaml` — manifest edits change the install surface and must always surface (supply-chain invariant).
- Any path referenced by a component (`copyPackFile.source`, `settingsFile.source`), template (`contentFile`), or configure script.

When generating manifests for repos with non-material directories (`docs/`, `examples/`, asset folders), populate `ignore:` so authors don't hit validation warnings or noisy update notifications.

---

## Pack Directory Convention

```
my-pack/
  techpack.yaml            # Manifest (required)
  README.md                # Documentation
  hooks/                   # Hook scripts
  skills/                  # Skill directories (each with SKILL.md)
  commands/                # Slash command .md files
  agents/                  # Subagent .md files
  templates/               # CLAUDE.local.md section content
  config/                  # Settings JSON
  scripts/                 # Configure scripts
```

---

## Hook Events

All valid Claude Code hook events:

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`,
`PostToolUseFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `StopFailure`,
`TeammateIdle`, `TaskCompleted`, `ConfigChange`, `InstructionsLoaded`, `WorktreeCreate`,
`WorktreeRemove`, `PreCompact`, `PostCompact`, `SessionEnd`, `Elicitation`, `ElicitationResult`
