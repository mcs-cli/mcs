# Creating Tech Packs

A tech pack is your Claude Code setup — packaged as a Git repo and shareable with anyone. It bundles MCP servers, plugins, hooks, skills, commands, agents, templates, and settings into a single `techpack.yaml` file that `mcs` knows how to sync and maintain.

Think of it like a dotfiles repo, but specifically for Claude Code.

## Quick Start with `mcs export`

Already have Claude Code configured the way you like it? Export your setup as a tech pack instead of writing one from scratch:

```bash
# Export your global setup (~/.claude/)
mcs export ./my-pack --global

# Export a project-specific setup
cd ~/Developer/my-project
mcs export ./my-pack

# Preview without writing
mcs export ./my-pack --global --dry-run
```

The export wizard discovers your MCP servers, hooks, skills, commands, agents, plugins, CLAUDE.md sections, gitignore entries (global export only), and settings — then generates a complete pack directory with `techpack.yaml` and all supporting files.

**What it handles automatically:**
- Sensitive env vars (API keys, tokens) are replaced with `__PLACEHOLDER__` tokens and corresponding `prompts:` entries are generated
- Hook files are matched to their Claude Code events via settings cross-reference
- CLAUDE.md managed sections are extracted as template files
- Brew dependency hints are added as TODO comments for MCP server commands

**What you should review after export:**
- Add `dependencies:` between components (e.g., MCP server depends on brew package)
- Add `brew:` components for runtime dependencies (node, uv, python3)
- Add `displayName:` where the auto-generated ID isn't descriptive enough
- Add `supplementaryDoctorChecks:` for health verification
- Move the `prompts:` section before `components:` for readability

The generated YAML includes a TODO checklist at the bottom to guide your review.

---

## Your First Tech Pack

Let's build a working tech pack in under 5 minutes.

### 1. Create the repo

```bash
mkdir my-first-pack && cd my-first-pack
git init
```

### 2. Write the manifest

Create `techpack.yaml`:

```yaml
schemaVersion: 1
identifier: my-first-pack
displayName: My First Pack
description: A simple pack that adds an MCP server
author: "Your Name"

components:
  - id: my-server
    description: My favorite MCP server
    mcp:
      command: npx
      args: ["-y", "my-mcp-server@latest"]
```

That's it. One file, 10 lines.

### 3. Install and test

```bash
# Commit it
git add -A && git commit -m "Initial tech pack"

# If using a local path:
mcs pack add /path/to/my-first-pack

# Or push to GitHub first:
git remote add origin https://github.com/you/my-first-pack.git
git push -u origin main
mcs pack add you/my-first-pack  # GitHub shorthand (or full URL)
```

### 4. Sync a project

```bash
cd ~/Developer/some-project
mcs sync          # Select your pack from the list
mcs doctor        # Verify everything installed correctly
```

You now have a working tech pack. Let's make it more useful.

---

## Adding Components

Components are the building blocks of a tech pack. Each one is something `mcs` can install, verify, and uninstall. The shorthand syntax lets you define most components in 2-4 lines.

### Brew Packages

Install CLI tools via Homebrew:

```yaml
components:
  - id: node
    description: JavaScript runtime
    brew: node

  - id: gh
    description: GitHub CLI
    brew: gh
```

When a user runs `mcs sync`, these get installed via `brew install`. The engine auto-verifies them with `mcs doctor` (checks if the command is on PATH).

Need to depend on Homebrew itself? That's a special case — Homebrew can't install itself, so use `shell:` with an explicit doctor check:

```yaml
  - id: homebrew
    displayName: Homebrew
    description: macOS package manager
    type: brewPackage
    shell: '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    doctorChecks:
      - type: commandExists
        name: Homebrew
        command: brew
```

### MCP Servers

Register MCP servers with the Claude CLI:

```yaml
  # Standard (stdio) transport
  - id: my-server
    description: Code analysis server
    dependencies: [node]
    mcp:
      command: npx
      args: ["-y", "my-server@latest"]
      env:
        API_KEY: "__MY_API_KEY__"    # Resolved from prompts

  # HTTP transport — just provide a url
  - id: remote-server
    description: Cloud-hosted MCP server
    mcp:
      url: https://example.com/mcp
```

`__KEY__` placeholders in `env` values, `command`, and `args` are substituted with resolved prompt values during `mcs sync`. The server `name` is never substituted.

The server name defaults to the component id. If the server uses a different name (e.g. mixed case), override it:

```yaml
  - id: xcodebuildmcp
    displayName: XcodeBuildMCP
    description: Xcode build server
    mcp:
      name: XcodeBuildMCP    # Override — server registers as "XcodeBuildMCP"
      command: npx
      args: ["-y", "xcodebuildmcp@latest"]
```

### Plugins

Install Claude Code plugins:

```yaml
  - id: my-plugin
    description: Helpful plugin
    plugin: "my-plugin@my-org"
```

### Hooks

Hook scripts run at specific Claude Code lifecycle events:

```yaml
  - id: session-hook
    description: Shows git status on session start
    dependencies: [jq]
    hookEvent: SessionStart
    hook:
      source: hooks/session_start.sh
      destination: session_start.sh
```

This copies `hooks/session_start.sh` from your pack repo into `<project>/.claude/hooks/` and registers it in `settings.local.json` under the `SessionStart` event.

Available events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `Stop`, `TeammateIdle`, `TaskCompleted`, `ConfigChange`, `WorktreeCreate`, `WorktreeRemove`, `PreCompact`, `SessionEnd`.

### Skills

Skills are directories containing a `SKILL.md` file and optional reference files:

```yaml
  - id: my-skill
    description: Domain-specific knowledge
    skill:
      source: skills/my-skill          # Directory in your pack repo
      destination: my-skill            # Name under .claude/skills/
```

### Slash Commands

Custom `/command` prompts:

```yaml
  - id: pr-command
    displayName: /pr command
    description: Create pull requests
    command:
      source: commands/pr.md
      destination: pr.md
```

### Agents

Custom subagents — Markdown files with YAML frontmatter that Claude Code can invoke as specialized agents:

```yaml
  - id: code-reviewer
    description: Code review subagent
    agent:
      source: agents/code-reviewer.md
      destination: code-reviewer.md
```

This copies the agent Markdown file from your pack repo into `<project>/.claude/agents/`. Agent files follow Claude Code's subagent format (Markdown with `---` frontmatter containing the agent name and configuration).

### Settings

Merge Claude Code settings (plan mode, env vars, etc.):

```yaml
  - id: settings
    description: Claude Code configuration
    isRequired: true
    settingsFile: config/settings.json
```

Your `config/settings.json` might look like:

```json
{
  "permissions": {
    "defaultMode": "plan"
  },
  "alwaysThinkingEnabled": true,
  "env": {
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    "MY_API_KEY": "__MY_API_KEY__"
  }
}
```

`__KEY__` placeholders in JSON values are substituted with resolved prompt values before the file is parsed and merged. This lets pack authors use user-provided values in settings (e.g., API keys, paths).

### Gitignore Entries

Add patterns to the user's global gitignore:

```yaml
  - id: gitignore
    description: Gitignore entries
    isRequired: true
    gitignore:
      - .claude/memories
      - .claude/settings.local.json
      - .claude/.mcs-project
```

### Shell Commands

For anything that doesn't fit the other categories:

```yaml
  - id: special-tool
    description: Install via custom script
    type: skill                    # shell: requires explicit type
    shell: "npx -y skills add some-skill -g -a claude-code -y"
```

`shell:` is the only shorthand that doesn't infer the component type — you must provide `type:` explicitly.

---

## Dependencies

Components can depend on other components. Use short IDs — the engine auto-prefixes them with your pack identifier:

```yaml
identifier: my-pack

components:
  - id: homebrew
    description: Package manager
    type: brewPackage
    shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'

  - id: node
    description: JavaScript runtime
    dependencies: [homebrew]       # → my-pack.homebrew
    brew: node

  - id: my-server
    description: Code search
    dependencies: [node]           # → my-pack.node
    mcp:
      command: npx
      args: ["-y", "my-server@latest"]
```

Dependencies are installed in order (topological sort). Circular dependencies are detected and rejected.

For cross-pack dependencies, use the full `pack.component` form:

```yaml
  - id: my-tool
    dependencies: [other-pack.node]   # Different pack — not auto-prefixed
    brew: my-tool
```

---

## Templates

Templates inject instructions into each project's `CLAUDE.local.md`. This is how you give Claude project-specific context.

### Define the template

In `techpack.yaml`:

```yaml
templates:
  - sectionIdentifier: instructions
    contentFile: templates/instructions.md
    placeholders:
      - __PROJECT__
```

### Write the content

Create `templates/instructions.md`:

```markdown
## Build & Test

Always use __PROJECT__ as the project file.
Never run `xcodebuild` directly — use XcodeBuildMCP tools instead.
```

### How it works

When a user runs `mcs sync`, the template content is inserted into `CLAUDE.local.md` between section markers:

```markdown
<!-- mcs:begin my-pack.instructions -->
## Build & Test

Always use MyApp.xcworkspace as the project file.
Never run `xcodebuild` directly — use XcodeBuildMCP tools instead.
<!-- mcs:end my-pack.instructions -->
```

Users can add their own content outside these markers — `mcs` only manages the sections it owns.

### Placeholders

- `__REPO_NAME__` — always available (repo name from `git remote get-url origin`; falls back to directory name)
- `__PROJECT_DIR_NAME__` — always available (project directory name)
- Custom placeholders are resolved from `prompts` (see below)

Placeholder substitution works in **templates**, **settings files** (`settingsFile:`), **MCP server configs** (`env`, `command`, `args`), and **copyPackFile** artifacts (hooks, commands, skills).

---

## Prompts

Prompts gather values from the user during `mcs sync`. These values are available as `__KEY__` placeholders in templates, settings files, MCP server configs, and copyPackFile artifacts — and as `MCS_RESOLVED_KEY` environment variables in scripts.

When multiple packs declare prompts with the same `key` (e.g., both a core pack and an iOS pack want `BRANCH_PREFIX`), the user is asked **once** with a combined display. Only `input` and `select` types are deduplicated — `fileDetect` and `script` always run per-pack.

```yaml
prompts:
  # Auto-detect files matching a pattern
  - key: PROJECT
    type: fileDetect
    label: "Xcode project / workspace"
    detectPattern:
      - "*.xcodeproj"
      - "*.xcworkspace"

  # Free-text input
  - key: BRANCH_PREFIX
    type: input
    label: "Branch prefix (e.g. feature)"
    default: "feature"

  # Choose from options
  - key: PLATFORM
    type: select
    label: "Target platform"
    options:
      - value: ios
        label: iOS
      - value: macos
        label: macOS

  # Dynamic value from a script
  - key: SDK_VERSION
    type: script
    label: "SDK version"
    scriptCommand: "xcrun --show-sdk-version"
```

---

## Doctor Checks

`mcs doctor` verifies your pack is healthy. Most checks are **auto-derived** — you don't need to write them:

| Install action | Auto-derived check |
|---|---|
| `brew: node` | Is `node` on PATH? |
| `mcp: {command: npx, ...}` | Is the MCP server registered? |
| `plugin: "name@org"` | Is the plugin enabled? |
| `hook: {source, destination}` | Does the hook file exist? |
| `skill: {source, destination}` | Does the skill directory exist? |
| `command: {source, destination}` | Does the command file exist? |
| `agent: {source, destination}` | Does the agent file exist? |

### When you need custom checks

Use `doctorChecks` on a component when the auto-derived check isn't enough:

```yaml
  - id: homebrew
    type: brewPackage
    shell: '/bin/bash -c "$(curl -fsSL https://brew.sh)"'
    doctorChecks:
      - type: commandExists
        name: Homebrew
        section: Dependencies
        command: brew
```

This is needed because `shell:` commands have no auto-derived check — the engine can't guess what a shell command installs.

With `args`, `commandExists` goes beyond PATH presence — it actually runs the command and checks the exit code. This is useful for verifying that a specific resource exists:

```yaml
  - id: ollama-model
    type: configuration
    shell: "ollama pull nomic-embed-text"
    doctorChecks:
      - type: commandExists
        name: nomic-embed-text model
        section: AI Models
        command: ollama
        args: ["show", "nomic-embed-text"]
```

### Pack-level checks

For verifying things that aren't tied to a specific component:

```yaml
supplementaryDoctorChecks:
  - type: shellScript
    name: Xcode Command Line Tools
    section: Prerequisites
    command: "xcode-select -p >/dev/null 2>&1"
    fixCommand: "xcode-select --install"

  - type: settingsKeyEquals
    name: Plan mode enabled
    section: Settings
    keyPath: permissions.defaultMode
    expectedValue: plan
```

The `fixCommand` is run automatically when the user runs `mcs doctor --fix`.

See the [Schema Reference](techpack-schema.md#doctor-checks) for all 8 check types.

---

## Configure Scripts

For project setup that goes beyond file copying, use a configure script:

```yaml
configureProject:
  script: scripts/configure.sh
```

The script receives environment variables:
- `MCS_PROJECT_PATH` — absolute path to the project root
- `MCS_RESOLVED_<KEY>` — resolved prompt values (e.g. `MCS_RESOLVED_PROJECT`)

Example `scripts/configure.sh`:

```bash
#!/bin/bash
set -euo pipefail

project_path="${MCS_PROJECT_PATH:?}"
project_file="${MCS_RESOLVED_PROJECT:-}"

[ -z "$project_file" ] && exit 0

mkdir -p "$project_path/.xcodebuildmcp"
cat > "$project_path/.xcodebuildmcp/config.yaml" << EOF
schemaVersion: 1
sessionDefaults:
  projectPath: ./$project_file
  platform: iOS
EOF

echo "Created .xcodebuildmcp/config.yaml for $project_file"
```

---

## How Convergence Works

`mcs sync` is **idempotent** — safe to run repeatedly. The engine tracks what each pack installed and converges to the desired state:

- **Add a pack** → installs all its components (MCP servers, files, templates, settings)
- **Remove a pack** → cleans up everything it installed (removes MCP servers, deletes files, removes template sections)
- **Re-run unchanged** → updates idempotently (re-copies files, re-composes settings)

This tracking lives in `<project>/.claude/.mcs-project`. You don't need to manage it.

### Where artifacts go

| Artifact | Location |
|----------|----------|
| MCP servers | `~/.claude.json` (keyed by project path) |
| Skills | `<project>/.claude/skills/` |
| Hooks | `<project>/.claude/hooks/` |
| Commands | `<project>/.claude/commands/` |
| Agents | `<project>/.claude/agents/` |
| Settings | `<project>/.claude/settings.local.json` |
| Templates | `<project>/CLAUDE.local.md` |
| Brew packages | Global (`brew install`) |
| Plugins | Global (`claude plugin install`) |

---

## Testing Your Pack

```bash
# Add your pack (local path or GitHub URL)
mcs pack add /path/to/my-pack

# Sync a test project
cd ~/Developer/test-project
mcs sync                  # Select your pack

# Verify
mcs doctor                # All checks should pass
ls -la .claude/           # Inspect installed artifacts
cat CLAUDE.local.md       # Check template sections

# Test removal — deselect your pack
mcs sync                  # Deselect it
ls -la .claude/           # Artifacts should be gone
cat CLAUDE.local.md       # Template sections removed

# Test updates — make a change to your pack, then
mcs sync                  # Local packs pick up changes automatically
# For git packs: mcs pack update my-pack && mcs sync
```

---

## Design Tips

**Keep it focused.** A pack for iOS development shouldn't also install Python linters. Multiple small packs compose better than one giant one.

**Use short IDs.** Write `id: node`, not `id: my-pack.node`. Dots in IDs are rejected — the engine always auto-prefixes with the pack identifier.

**Default to `local` scope for MCP servers.** This gives per-user, per-project isolation. Only use `project` scope for team-shared servers, and `user` scope for truly global tools.

**Make hooks resilient.** Always start with `set -euo pipefail` and `trap 'exit 0' ERR`. Check for required tools before using them (`command -v jq >/dev/null 2>&1 || exit 0`). A crashing hook blocks Claude Code.

**Use `isRequired: true`** for components that should always be installed (settings, gitignore). Required components can't be deselected during `mcs sync --customize`.

**Add `fixCommand`** to doctor checks when auto-repair is possible. Users love `mcs doctor --fix`.

**Name collisions are handled automatically.** When two packs define the same destination filename for commands, hooks, or agents, `mcs` silently namespaces them with the pack identifier as a subdirectory (e.g., `.claude/commands/pack-a/pr.md`). For skills, which require a flat directory structure, collisions are resolved by appending `-<pack-id>` to the directory name (e.g., `my-skill-pack-b`) — the first pack keeps the clean name. A warning is shown so the user knows about the rename.

---

## Further Reading

- [Schema Reference](techpack-schema.md) — complete field-by-field reference for `techpack.yaml`
- [Troubleshooting](troubleshooting.md) — common issues and solutions

---

**Next**: See the [Schema Reference](techpack-schema.md) for complete field documentation.

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
