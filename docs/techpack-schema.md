# Tech Pack Schema Reference

Complete field-by-field reference for `techpack.yaml`. For a tutorial-style introduction, see [Creating Tech Packs](creating-tech-packs.md).

> **Tip**: Already have Claude Code configured? Run `mcs export ./my-pack` to auto-generate a `techpack.yaml` from your existing setup. See [Quick Start with `mcs export`](creating-tech-packs.md#quick-start-with-mcs-export).

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | `Integer` | Yes | Must be `1` |
| `identifier` | `String` | Yes | Unique pack ID. Lowercase alphanumeric + hyphens, e.g. `my-pack` |
| `displayName` | `String` | Yes | Human-readable name shown in CLI output |
| `description` | `String` | Yes | One-line description of what the pack provides |
| `author` | `String` | No | Pack author name (shown in `mcs pack list` and `mcs pack add`) |
| `minMCSVersion` | `String` | No | Minimum `mcs` version required, e.g. `"2.1.0"` |
| `components` | `[Component]` | No | Installable components (see below) |
| `templates` | `[Template]` | No | CLAUDE.local.md section contributions |
| `prompts` | `[Prompt]` | No | Interactive prompts for `mcs sync` |
| `configureProject` | `ConfigureProject` | No | Script to run after project configuration |
| `supplementaryDoctorChecks` | `[DoctorCheck]` | No | Pack-level health checks |
| `ignore` | `[String]` | No | POSIX-glob paths treated as non-material. See [The `ignore:` field](#the-ignore-field). |

## Components

Components are defined in the `components` array. Each component represents something `mcs` can install, verify, and uninstall.

### Common Fields

These fields are available on every component, regardless of which shorthand key is used:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `String` | Yes | Short identifier (no dots). Auto-prefixed with `<pack>.` |
| `description` | `String` | Yes | One-line description |
| `displayName` | `String` | No | Display name (defaults to `id`) |
| `dependencies` | `[String]` | No | Component IDs this depends on. Short form auto-prefixed |
| `isRequired` | `Boolean` | No | If `true`, cannot be deselected in `--customize` mode |
| `hookEvent` | `String` | No | Claude Code event for hook components |
| `hookMatcher` | `String` | No | Regex to filter when hook fires (e.g., tool name for `PreToolUse`). Requires `hookEvent` |
| `hookTimeout` | `Integer` | No | Seconds before canceling the hook (defaults: 600 command, 30 prompt, 60 agent) |
| `hookAsync` | `Boolean` | No | If `true`, runs the hook in the background without blocking |
| `hookStatusMessage` | `String` | No | Custom spinner message displayed while the hook runs |
| `hookInterpreter` | `String` | No | Command the hook script runs under, e.g. `node`. Defaults to the interpreter implied by the file extension, else `bash`. Requires `hookEvent` |
| `doctorChecks` | `[DoctorCheck]` | No | Custom health checks (see [Doctor Checks](#doctor-checks)) |

### Shorthand Keys

Use one of these keys to define a component's install action. Each key infers the component `type` automatically (except `shell:`).

#### `brew:` — Homebrew Package

```yaml
- id: node
  description: JavaScript runtime
  brew: node
```

| Field | Type | Description |
|-------|------|-------------|
| `brew` | `String` | Homebrew package name |

Infers: `type: brewPackage`, `installAction: brewInstall`

---

#### `mcp:` — MCP Server

```yaml
# Stdio transport
- id: my-server
  description: Code analysis
  mcp:
    command: npx
    args: ["-y", "my-server@latest"]
    env:
      API_KEY: "value"
    scope: local

# HTTP transport
- id: remote-server
  description: Cloud server
  mcp:
    url: https://example.com/mcp
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | `String` | No | Server name (defaults to component id) |
| `command` | `String` | Stdio only | Command to run (e.g. `npx`, `uvx`) |
| `args` | `[String]` | No | Command arguments |
| `env` | `{String: String}` | No | Environment variables. Supports `__KEY__` placeholders from prompts |
| `url` | `String` | HTTP only | Server URL |
| `scope` | `String` | No | `local` (default), `project`, or `user` |

Transport is inferred: if `url` is present, HTTP; otherwise stdio.

`__KEY__` placeholders in `env` values, `command`, and `args` are substituted with resolved prompt values during `mcs sync`. The server `name` is never substituted (it's used as an artifact tracking key).

Infers: `type: mcpServer`, `installAction: mcpServer`

---

#### `plugin:` — Claude Code Plugin

```yaml
- id: my-plugin
  description: Helpful plugin
  plugin: "my-plugin@my-org"
```

| Field | Type | Description |
|-------|------|-------------|
| `plugin` | `String` | Plugin full name (`name@org` or `name@user/repo`) |

Infers: `type: plugin`, `installAction: plugin`

---

#### `hook:` — Hook Script

```yaml
- id: session-hook
  description: Session start hook
  hookEvent: SessionStart
  hookMatcher: "startup"
  hookTimeout: 30
  hookAsync: true
  hookStatusMessage: "Initializing session..."
  hook:
    source: hooks/session_start.sh
    destination: session_start.sh
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to script in the pack repo |
| `destination` | `String` | Yes | Filename in `<project>/.claude/hooks/`. Any extension is valid — see [Hook interpreters](#hook-interpreters) |

Use with `hookEvent` to register the hook in `settings.local.json`. The optional `hookMatcher`, `hookTimeout`, `hookAsync`, and `hookStatusMessage` fields map directly to Claude Code's hook handler fields (`matcher`, `timeout`, `async`, `statusMessage`). `hookInterpreter` is different — it does not reach Claude Code at all; it changes the `command` string mcs composes.

Hook destinations are **always** namespaced with a `<pack-id>/` subdirectory prefix, whether or not another pack declares the same `destination`. That prevents a pack from overwriting a hook you wrote by hand at a flat path like `.claude/hooks/lint.sh`.

Infers: `type: hookFile`, `installAction: copyPackFile(fileType: hook)`

##### Hook interpreters

The registered command is `<interpreter> <path>`. The interpreter is resolved in three steps:

1. `hookInterpreter`, if you declare one.
2. The file extension of `destination` — falling back to `source` when `destination` has none.
3. `bash`.

| Extension | Interpreter |
|-----------|-------------|
| `.sh`, `.bash`, no extension | `bash` |
| `.zsh` | `zsh` |
| `.js`, `.mjs`, `.cjs` | `node` |
| `.py` | `python3` |
| `.rb` | `ruby` |
| `.pl` | `perl` |
| `.ts`, `.mts`, `.cts`, `.tsx` | **none** — declare `hookInterpreter` |

TypeScript is deliberately excluded: `node --experimental-strip-types`, `tsx`, `bun` and `deno` are
all reasonable, and guessing wrong produces a hook that fails at runtime. `mcs pack validate` warns
when a TypeScript hook declares no interpreter.

```yaml
- id: gate-hook
  description: Blocks risky tool calls
  hookEvent: PreToolUse
  hookInterpreter: node --experimental-strip-types --disable-warning=ExperimentalWarning
  hook:
    source: hooks/gate.ts
    destination: gate.ts
# → node --experimental-strip-types --disable-warning=ExperimentalWarning .claude/hooks/<pack-id>/gate.ts
```

`hookInterpreter` accepts a bare command name (`node`), an absolute path
(`/opt/homebrew/bin/bun`), and arguments (`uv run`, `python3 -u`). It rejects shell
metacharacters, relative paths, and quoted arguments containing spaces — wrap those in a script
instead. `mcs doctor` verifies the binary resolves, and warns when it resolves only through a
version manager such as nvm or pyenv, since Claude Code may not have that on `PATH` when it runs
your hook.

**When a wrapper script is still the right answer:** an interpreter that only exists inside a
version manager, a flag value containing spaces, or any setup that needs shell initialisation
first. A `.sh` wrapper that `exec`s the real interpreter remains fully supported.

---

#### `command:` — Slash Command

```yaml
- id: pr-command
  description: Create pull requests
  command:
    source: commands/pr.md
    destination: pr.md
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to command file in the pack repo |
| `destination` | `String` | Yes | Filename in `<project>/.claude/commands/` |

If two packs declare the same `destination`, both are automatically namespaced with a `<pack-id>/` subdirectory prefix to prevent collisions.

Infers: `type: command`, `installAction: copyPackFile(fileType: command)`

---

#### `skill:` — Skill

```yaml
- id: my-skill
  description: Domain knowledge
  skill:
    source: skills/my-skill
    destination: my-skill
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to skill directory in the pack repo |
| `destination` | `String` | Yes | Directory name in `<project>/.claude/skills/` |

If two packs declare the same `destination`, the first pack keeps the clean name and subsequent packs get `-<pack-id>` appended to the directory name (e.g., `my-skill-pack-b`). A warning is shown during sync. Skills cannot use subdirectory namespacing because Claude Code requires a flat one-level directory for skill discovery.

Infers: `type: skill`, `installAction: copyPackFile(fileType: skill)`

---

#### `agent:` — Subagent

```yaml
- id: code-reviewer
  description: Code review subagent
  agent:
    source: agents/code-reviewer.md
    destination: code-reviewer.md
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `source` | `String` | Yes | Path to agent Markdown file in the pack repo |
| `destination` | `String` | Yes | Filename in `<project>/.claude/agents/` |

If two packs declare the same `destination`, both are automatically namespaced with a `<pack-id>/` subdirectory prefix to prevent collisions.

Infers: `type: agent`, `installAction: copyPackFile(fileType: agent)`

---

#### `settingsFile:` — Settings

```yaml
- id: settings
  description: Claude Code configuration
  isRequired: true
  settingsFile: config/settings.json
```

| Field | Type | Description |
|-------|------|-------------|
| `settingsFile` | `String` | Path to settings JSON file in the pack repo |

The settings file is deep-merged into `<project>/.claude/settings.local.json`. `__KEY__` placeholders in JSON values are substituted with resolved prompt values before parsing.

Infers: `type: configuration`, `installAction: settingsFile`

---

#### `gitignore:` — Gitignore Entries

```yaml
- id: gitignore
  description: Global gitignore
  isRequired: true
  gitignore:
    - .claude/memories
    - .claude/settings.local.json
```

| Field | Type | Description |
|-------|------|-------------|
| `gitignore` | `[String]` | Patterns to add to the global gitignore |

Infers: `type: configuration`, `installAction: gitignoreEntries`

---

#### `shell:` — Shell Command

```yaml
- id: homebrew
  description: macOS package manager
  type: brewPackage           # Required — shell: doesn't infer type
  shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
```

| Field | Type | Description |
|-------|------|-------------|
| `shell` | `String` | Shell command to execute |
| `shellInteractive` | `Bool` | When `true`, allocates a PTY so commands like `sudo` can prompt for passwords securely. Default: `false` |

**Does not infer `type`** — you must provide `type:` explicitly. This is because a shell command could install anything (a brew package, a skill, a tool).

No auto-derived doctor check — add `doctorChecks` if verification is needed.

Use `shellInteractive: true` when the command may need terminal access (e.g. install scripts that use `sudo`):

```yaml
- id: ollama
  description: Local LLM runtime
  type: configuration
  shell: "curl -fsSL https://ollama.com/install.sh | sh"
  shellInteractive: true
  doctorChecks:
    - type: commandExists
      name: "Ollama installed"
      command: ollama
      args: ["--version"]
```

---

### Verbose Form

The explicit form with `type` + `installAction` is always supported:

```yaml
- id: node
  displayName: Node.js
  description: JavaScript runtime
  type: brewPackage
  installAction:
    type: brewInstall
    package: node
```

#### Install Action Types

| `type` | Fields | Description |
|--------|--------|-------------|
| `mcpServer` | `name`, `command`, `args`, `env`, `transport`, `url`, `scope` | Register MCP server |
| `plugin` | `name` | Install Claude Code plugin |
| `brewInstall` | `package` | Install Homebrew package |
| `shellCommand` | `command`, `interactive` | Run shell command (`interactive`: allocate PTY, default `false`) |
| `gitignoreEntries` | `entries` | Add to global gitignore |
| `settingsMerge` | *(none)* | Merge settings (internal) |
| `settingsFile` | `source` | Merge settings from file |
| `copyPackFile` | `source`, `destination`, `fileType` | Copy file from pack |

`fileType` values: `skill`, `hook`, `command`, `agent`, `generic`

---

## Templates

Templates contribute sections to `CLAUDE.local.md` during `mcs sync`.

```yaml
templates:
  - sectionIdentifier: instructions
    contentFile: templates/instructions.md
    placeholders:
      - __PROJECT__
      - __BRANCH_PREFIX__
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sectionIdentifier` | `String` | Yes | Short section ID (no dots). Auto-prefixed with `<pack>.` |
| `contentFile` | `String` | Yes | Path to markdown file in the pack repo |
| `placeholders` | `[String]` | No | `__PLACEHOLDER__` tokens used in the template |

### Built-in Placeholders

| Placeholder | Description |
|---|---|
| `__REPO_NAME__` | Repository name parsed from `git remote get-url origin` (strips path and `.git` suffix). Falls back to directory name if no remote is configured or the URL cannot be parsed. |
| `__PROJECT_DIR_NAME__` | The project directory name (from `git rev-parse --show-toplevel`, or the sync target path). |

### Section Markers

Templates are wrapped in HTML comment markers in `CLAUDE.local.md`:

```markdown
<!-- mcs:begin my-pack.instructions -->
(template content here)
<!-- mcs:end my-pack.instructions -->
```

Content outside markers is preserved. Re-running `mcs sync` updates only the managed sections.

---

## Prompts

Prompts gather values from the user during `mcs sync`.

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
| `key` | `String` | Yes | Unique key. Becomes `__KEY__` placeholder and `MCS_RESOLVED_KEY` env var |
| `type` | `String` | Yes | One of: `fileDetect`, `input`, `select`, `script` |
| `label` | `String` | No | Human-readable prompt label |
| `default` | `String` | No | Default value for `input` type |
| `detectPattern` | `String` or `[String]` | `fileDetect` | Glob pattern(s) to match files |
| `options` | `[{value, label}]` | `select` | Choices for select prompts |
| `scriptCommand` | `String` | `script` | Shell command whose stdout becomes the value |

### Prompt Types

| Type | Behavior |
|------|----------|
| `fileDetect` | Scans the project directory for files matching the glob pattern(s). If one match is found, it's used automatically. If multiple, the user picks one. |
| `input` | Free-text input with optional default value. |
| `select` | Choose from a predefined list of options. |
| `script` | Runs a shell command and uses its stdout as the value. |

### Cross-Pack Deduplication

When multiple packs declare prompts with the same `key`, `mcs` detects the overlap and asks the user **once** with a combined display showing each pack's label. The resolved value is shared across all packs.

Only `input` and `select` prompts are eligible for deduplication. `fileDetect` and `script` prompts are too pack-specific and always run per-pack.

For shared `select` prompts, options are merged across packs (deduplicated by value, first occurrence wins). If one pack uses `input` and another uses `select` for the same key, the prompt falls back to `input` with a warning.

---

## Doctor Checks

Doctor checks verify pack health. They can be defined at two levels:

1. **Per-component** — `doctorChecks` field on a component
2. **Pack-level** — `supplementaryDoctorChecks` at the top level

### Check Definition

```yaml
- type: shellScript
  name: Xcode CLI Tools
  section: Prerequisites
  command: "xcode-select -p >/dev/null 2>&1"
  fixCommand: "xcode-select --install"
  isOptional: false
```

### Common Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `String` | Yes | Check type (see table below) |
| `name` | `String` | Yes | Display name in doctor output |
| `section` | `String` | No | Grouping label in output |
| `fixCommand` | `String` | No | Shell command for `mcs doctor --fix` |
| `fixScript` | `String` | No | Path to fix script (for complex fixes) |
| `isOptional` | `Boolean` | No | If `true`, failure is a warning, not an error |

### Check Types

| Type | Required Fields | Description |
|------|----------------|-------------|
| `commandExists` | `command` | Without `args`: checks PATH presence. With `args`: runs the command and checks exit code |
| `fileExists` | `path` | Does a file exist? |
| `directoryExists` | `path` | Does a directory exist? |
| `fileContains` | `path`, `pattern` | Does a file match a regex pattern? |
| `fileNotContains` | `path`, `pattern` | Does a file NOT match a regex pattern? |
| `shellScript` | `command` | Run a command. Exit codes: `0`=pass, `1`=fail, `2`=warn, `3`=skip |
| `hookEventExists` | `event` | Is a hook event registered in settings? Optionally asserts `matcher` and `command` — see below |
| `settingsKeyEquals` | `keyPath`, `expectedValue` | Does a settings JSON key equal a specific value? |

### `matcher` and `command` — `hookEventExists` only

By default `hookEventExists` asks only whether the event key is present. A hook group whose
matcher matches nothing satisfies that, so the hook can be registered, green in doctor, and never
fire. Two optional fields tighten it:

```yaml
- type: hookEventExists
  name: "Gate hook registered"
  section: Hooks
  event: PreToolUse
  matcher: "Agent|Task"    # a hook group with exactly this matcher must exist
  command: kb-gate.sh      # that group must run a command containing this substring
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `matcher` | `String` | No | Exact matcher a hook group under `event` must carry |
| `command` | `String` | No | Substring a hook command must contain |

- `matcher` is compared as a **raw string**. The regex is not interpreted — Claude Code evaluates
  it at runtime, and mcs does not second-guess what it will match. A written `""` and an absent
  matcher are treated as the same thing; declaring `matcher: ""` is rejected at validation.
- When both are given they must be satisfied by the **same** group. Two unrelated groups
  satisfying one field each does not prove the registration belongs to your pack.
- A mismatch is a **warning**, not a failure — the registration exists, and a user who narrowed a
  matcher deliberately should not get a red doctor. An absent event still fails.
- `isOptional: true` downgrades both the mismatch and the absence to a skip.

**Use these for hooks you ship through a settings file.** A hook declared as a component
(`hook:` with `hookEvent`) already gets event and matcher verification automatically, derived from
the component itself — restating the matcher here just creates a second copy that can drift from
the first.

When you do match on `command`, match the script path rather than the interpreter: a check
asserting `bash .claude/hooks/…` stops matching the moment the component declares a
`hookInterpreter`. `mcs pack validate` warns about that specific inconsistency.

**What this does not prove:** that the matcher matches a tool Claude Code actually emits. It proves
the string you declared reached the settings file. Tool names are harness details that change
between releases — the sub-agent spawn tool is `Agent` in current Claude Code, and a matcher of
`Task` alone matches nothing. Only a real session transcript settles that.

### `scope` — path-based checks only

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `scope` | `String` | No | `global` (default) or `project` |

`scope` answers *"what is `path` relative to?"*, so it applies only to the four checks that take
a `path`: `fileExists`, `directoryExists`, `fileContains`, `fileNotContains`.

- `global` — the path is used as written, with `~` expanded.
- `project` — the path is resolved against the project root and confined to it. A path that
  escapes the project fails the check. Outside a project, the check is skipped.

The other check types ignore `scope`; `mcs pack validate` warns if you set it on them.

### Settings resolution

`hookEventExists` and `settingsKeyEquals` don't take a `path` — the settings file is implied. They
resolve it automatically, most specific first:

1. `<project>/.claude/settings.local.json` — where `mcs sync` writes project-scoped hooks and
   settings keys
2. `~/.claude/settings.json` — the global file

Globally-configured packs have no project root and read only the global file. The order mirrors
Claude Code's own precedence (project settings override global), so these checks report on the
configuration actually in effect. Doctor output names the file that answered — `registered in
settings.local.json` vs `registered in settings.json` — and a settings file that exists but can't
be parsed is always reported rather than skipped silently.

### Auto-Derived Checks

Most components get free doctor checks from their install action — no need to define them manually:

| Shorthand | Auto-derived check |
|-----------|-------------------|
| `brew: node` | `commandExists` for `node` |
| `mcp: {command: npx, ...}` | MCP server registered in `~/.claude.json` |
| `plugin: "name@org"` | Plugin enabled in settings |
| `hook: {source, dest}` | File exists at destination, plus the interpreter binary resolves (skipped for `bash`/`sh`/`zsh`) |
| `skill: {source, dest}` | Directory exists at destination |
| `command: {source, dest}` | File exists at destination |
| `agent: {source, dest}` | File exists at destination |
| `settingsFile: path` | Always re-applied (convergent) |
| `gitignore: [...]` | Always re-applied (convergent) |
| `shell: "..."` | **None** — add `doctorChecks` manually |

---

## Configure Project

```yaml
configureProject:
  script: scripts/configure.sh
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `script` | `String` | Yes | Path to shell script in the pack repo |

### Environment Variables

The script receives:

| Variable | Description |
|----------|-------------|
| `MCS_PROJECT_PATH` | Absolute path to the project root |
| `MCS_RESOLVED_<KEY>` | Resolved prompt values (uppercased key) |

---

## Validation Rules

The engine validates manifests on load. These rules are enforced:

- `schemaVersion` must be `1`
- `identifier` must be non-empty, lowercase alphanumeric with hyphens, not starting with a hyphen
- Component IDs must be short names without dots (auto-prefixed with `<pack>.`) and unique within the pack
- Intra-pack dependency references must resolve to existing component IDs in the same pack
- Template `sectionIdentifier` must be a short name without dots (auto-prefixed with `<pack>.`)
- `hookTimeout` must be a positive integer
- `hookMatcher`, `hookTimeout`, `hookAsync`, `hookStatusMessage` and `hookInterpreter` all require `hookEvent` to be set
- `hookInterpreter` must be a bare command name or absolute path, optionally followed by plain
  arguments — no shell metacharacters, no relative paths. `mcs pack validate` fails on a bad value;
  `mcs sync` drops it with a warning so one pack cannot block your sync
- Prompt `key` values must be unique
- Doctor check required fields must be present and non-empty

### Heuristic Checks

`mcs pack validate` runs additional best-practice checks beyond structural validation. Findings are categorized by severity:

**Errors** (block usage, exit code 1):

| Check | Description |
|-------|-------------|
| Empty pack | Pack has no components, templates, or configure script |
| Root source copy | `copyPackFile` source is `"."` or `"./"` — copies the entire pack root including `techpack.yaml`, LICENSE, and README |
| Missing settings file | `settingsFile:` references a file that does not exist in the pack |

**Warnings** (advisory, exit code 0):

| Check | Description |
|-------|-------------|
| Unreferenced subdirectory files | Files in non-infrastructure subdirectories not referenced by any component, template, or configure script |
| Unreferenced root-level files | Files at the pack root (excluding `techpack.yaml`, `README.md`, `LICENSE`, etc.) not referenced by any component |
| MCP dependency gap | MCP server uses `python`/`node` command but no brew component installs that runtime |
| Missing python module | MCP server uses `python -m <module>` but `<module>/` directory not found in the pack |

Infrastructure directories (`.git`, `.github`, `.gitlab`, `.vscode`, `node_modules`, `__pycache__`, `.build`) and common root-level files (`techpack.yaml`, `README.md`, `LICENSE`, `Makefile`, etc.) are excluded from unreferenced-file checks.

---

## The `ignore:` field

Pack authors can extend the engine's built-in deny-list of "non-material" paths via the top-level `ignore:` field. This serves two purposes from one declaration:

- `mcs check-updates` (and the SessionStart hook) treats matching paths as non-material — README/CI/docs-only commits in your pack repo no longer trigger downstream "pack update available" notifications.
- `mcs pack validate` no longer warns about matching paths as unreferenced files — authors can keep `docs/`, `examples/`, design assets, etc. in the pack repo without noise.

Example:

```yaml
identifier: my-pack
displayName: My Pack
description: Example
schemaVersion: 1
ignore:
  - docs/
  - examples/
  - diagrams/*.png
```

### Semantics

- **Extends the built-ins**, never replaces. The built-in deny-list (README, LICENSE, CHANGELOG, `.github/`, `node_modules/`, `.build/`, etc.) always applies; `ignore:` adds to it.
- **POSIX glob syntax** (via `fnmatch`):
  - `*` matches any sequence of non-`/` characters (does not cross directories).
  - `?` matches a single non-`/` character.
  - `[abc]` matches one character from the set.
  - **No `**` recursion** — POSIX globs only.
- **Trailing `/` silences the entire directory tree.** `docs/` matches `docs`, `docs/guide.md`, `docs/sub/deep.md`. Otherwise `docs/*` would only match one level deep.

### Forbidden entries

`ignore:` cannot silence load-bearing files. Both `mcs pack validate` (publish-time, hard error) and the runtime sync loader (warns and strips) reject:

- `techpack.yaml` — manifest edits change the install surface and must always surface (supply-chain invariant).
- Any path referenced by a component (`copyPackFile.source`, `settingsFile.source`), template (`contentFile`), or configure script — silencing a file the manifest claims to use would produce a broken pack.

Example error from `mcs pack validate`:

```
ignore: entry 'hooks/handler.sh' is not allowed: path is referenced by a component or template. Remove it from `ignore:` or remove the component.
```

If a malformed manifest reaches a user's machine (older mcs version, hand-edit), the sync loader silently strips the forbidden entries with a warning rather than failing the install — authors get loud feedback at publish time, users keep working.

---

## Complete Example

A minimal but realistic pack:

```yaml
schemaVersion: 1
identifier: web-dev
displayName: Web Development
description: Node.js development environment for Claude Code
author: "Your Name"

prompts:
  - key: FRAMEWORK
    type: select
    label: "Framework"
    options:
      - value: next
        label: Next.js
      - value: remix
        label: Remix

components:
  - id: node
    description: JavaScript runtime
    brew: node

  - id: prettier-server
    description: Code formatting MCP server
    dependencies: [node]
    mcp:
      command: npx
      args: ["-y", "prettier-mcp-server@latest"]

  - id: pr-review
    description: PR review toolkit
    plugin: "pr-review-toolkit@claude-plugins-official"

  - id: session-hook
    description: Shows npm outdated on session start
    hookEvent: SessionStart
    hookMatcher: "startup"
    hookTimeout: 15
    hookStatusMessage: "Checking outdated packages..."
    hook:
      source: hooks/session_start.sh
      destination: session_start.sh

  - id: settings
    description: Plan mode and thinking
    isRequired: true
    settingsFile: config/settings.json

  - id: gitignore
    description: Gitignore entries
    isRequired: true
    gitignore:
      - .claude/memories
      - .claude/settings.local.json

templates:
  - sectionIdentifier: instructions
    placeholders: [__FRAMEWORK__]
    contentFile: templates/instructions.md
```

---

**Next**: See [Architecture](architecture.md) for how the engine processes your manifest.

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
