# Stack Detection Rules

Maps repository file signals to tech stack detection and recommended pack components.

**Canonical sources:**
- Schema: https://github.com/mcs-cli/mcs/blob/main/docs/techpack-schema.md
- Guide: https://github.com/mcs-cli/mcs/blob/main/docs/creating-tech-packs.md

## Language Detection

| Signal Files | Language | Primary Runtime |
|-------------|----------|-----------------|
| `Package.swift` | Swift | swift (system) |
| `*.xcodeproj`, `*.xcworkspace` | Swift/ObjC | Xcode |
| `package.json` | JavaScript/TypeScript | node |
| `tsconfig.json` | TypeScript | node |
| `Cargo.toml` | Rust | rustup |
| `go.mod` | Go | go |
| `Gemfile` | Ruby | ruby |
| `requirements.txt`, `pyproject.toml`, `setup.py`, `Pipfile` | Python | python |
| `build.gradle`, `build.gradle.kts` | Java/Kotlin | java |
| `pom.xml` | Java | java |
| `composer.json` | PHP | php |
| `pubspec.yaml` | Dart/Flutter | dart |
| `CMakeLists.txt` | C/C++ | cmake |
| `*.csproj`, `*.sln` | C#/.NET | dotnet |

## Framework Detection

| Signal | Framework | Extra Components |
|--------|-----------|-----------------|
| `next.config.*` | Next.js | — |
| `remix.config.*` or `@remix-run` in package.json | Remix | — |
| `nuxt.config.*` | Nuxt.js | — |
| `vite.config.*` | Vite | — |
| `angular.json` | Angular | — |
| `svelte.config.*` | SvelteKit | — |
| `Fastfile` or `fastlane/` | Fastlane | brew: fastlane |
| `Podfile` | CocoaPods | brew: cocoapods |
| `django` in requirements | Django | — |
| `flask` in requirements | Flask | — |
| `rails` in Gemfile | Ruby on Rails | — |
| `actix-web` or `rocket` in Cargo.toml | Rust web framework | — |
| `gin` or `echo` in go.mod | Go web framework | — |

## Brew Component Recommendations

| Detection Signal | Brew Package | When to Include |
|-----------------|-------------|-----------------|
| Any `npx` MCP server | `node` | Always when npx is used |
| Any `uvx`/`python` MCP server | `python` | Always when python is used |
| `.swiftlint.yml` | `swiftlint` | Swift projects |
| `.swiftformat` | `swiftformat` | Swift projects |
| `gh` usage in hooks/scripts | `gh` | When GitHub CLI needed |
| `jq` usage in hooks/scripts | `jq` | When jq is used in hooks |
| `docker-compose.yml` | `docker` | When Docker detected |
| `Fastfile` | `fastlane` | iOS/Android projects |
| `Podfile` | `cocoapods` | iOS projects |

## MCP Server Recommendations

Only include servers with clear evidence of need. Do NOT add speculatively.

### By Language/Framework

| Stack | MCP Server | Command | Dep |
|-------|-----------|---------|-----|
| Xcode/iOS/macOS (`.xcodeproj` or `.xcworkspace`) | XcodeBuildMCP | `npx -y xcodebuildmcp@latest` | node |
| PostgreSQL (in docker-compose or deps) | postgres-mcp-server | `npx -y @anthropic/postgres-mcp-server` | node |
| SQLite (in deps) | sqlite-mcp-server | `npx -y @anthropic/sqlite-mcp-server` | node |
| GitHub (`.github/` directory, heavy GH usage) | github-mcp-server | `npx -y @anthropic/github-mcp-server` | node |
| Puppeteer/Playwright detected | puppeteer-mcp-server | `npx -y @anthropic/puppeteer-mcp-server` | node |

### MCP Scope Guide

| Scope | Use When |
|-------|----------|
| `local` (default) | Per-user, per-project isolation. Best for most cases |
| `project` | Team-shared servers (everyone on the project uses it) |
| `user` | Truly global tools (same server across all projects) |

## Hook Recommendations

| Detection Signal | Hook Event | Purpose | Example |
|-----------------|-----------|---------|---------|
| Any project | `SessionStart` | Git status summary, dep check | Show branch, uncommitted changes |
| `package.json` with scripts | `SessionStart` | npm/yarn outdated check | `npm outdated --json` |
| `.swiftlint.yml` | `PostToolUse` | Auto-lint after file edits (optional) | Run swiftlint on changed files |
| `.env.example` exists | `SessionStart` | Check .env configured | Verify required vars are set |
| CI config (`.github/workflows/`) | `SessionStart` | CI status check (optional) | Check last workflow run |

### Hook Script Best Practices

- Always start with `set -euo pipefail` (bash) or the equivalent fail-open guard in another language
- Check for required tools: `command -v jq >/dev/null 2>&1 || exit 0`
- Add `trap 'exit 0' ERR` for hooks that should never block
- Non-bash hooks: the extension picks the interpreter (`.js` → `node`, `.py` → `python3`); declare
  `hookInterpreter` for TypeScript or for arguments, and add a brew component for the runtime
- Keep hooks fast (< 5 seconds for SessionStart)
- Use `hookAsync: true` for slow, non-blocking checks
- Set `hookTimeout` to prevent hanging (30s is a good default)

## Template Content Recommendations

| Detection Signal | Section ID | Content |
|-----------------|-----------|---------|
| `Package.swift` | build-test | `swift build`, `swift test`, SPM conventions |
| `package.json` | build-test | npm/yarn/pnpm scripts from package.json |
| `Cargo.toml` | build-test | `cargo build`, `cargo test`, `cargo clippy` |
| `go.mod` | build-test | `go build`, `go test`, `go vet` |
| `Makefile` | build-test | Key make targets |
| Linter config (any) | conventions | Linting rules summary, tool-specific conventions |
| `tsconfig.json` | conventions | TypeScript strictness, module resolution |
| `.github/workflows` | ci | CI workflow summary, how to run checks locally |
| `docker-compose.yml` | infrastructure | Services, ports, how to start/stop |
| `README.md` with architecture info | architecture | Project structure, key modules |

### Template Writing Guidelines

- Keep sections concise (5-20 lines)
- Use actionable instructions Claude Code can follow
- Include exact commands, not vague descriptions
- Reference project-specific paths using `__PLACEHOLDER__` tokens
- Focus on things that vary per-project (don't repeat Claude Code's built-in knowledge)

## Prompt Recommendations

| Detection Signal | Key | Type | Purpose |
|-----------------|-----|------|---------|
| Multiple `*.xcodeproj` or `*.xcworkspace` | `PROJECT` | `fileDetect` | Select Xcode project |
| `.env.example` with `API_KEY` | `API_KEY` | `input` | API key collection |
| Multiple frameworks detected | `FRAMEWORK` | `select` | Framework selection |
| `Fastfile` with multiple lanes | `LANE` | `select` | Default Fastlane lane |
| Multiple package managers possible | `PACKAGE_MANAGER` | `select` | npm vs yarn vs pnpm |
| Branch naming conventions detected | `BRANCH_PREFIX` | `input` | Branch prefix (feature, bugfix) |

### When NOT to Add Prompts

- Values that can be auto-detected reliably (use `script` type instead)
- Values that never change per-project (hardcode them)
- Values only used internally by hooks (use env vars in the hook directly)

## Gitignore Recommendations

Standard entries for every pack:

```yaml
gitignore:
  - .claude/memories
  - .claude/settings.local.json
  - .claude/.mcs-project
```

Stack-specific additions:

| Stack | Extra Entries |
|-------|-------------|
| Xcode/iOS | `.xcodebuildmcp` |
| Python | `__pycache__`, `.venv` |
| Node.js | `node_modules` (usually already in .gitignore) |
| Rust | `target/` (usually already in .gitignore) |

Only add entries that aren't already in the project's `.gitignore`.

## Settings Recommendations

Baseline for every pack:

```json
{
  "permissions": {
    "defaultMode": "plan"
  }
}
```

Stack-specific additions:

| Detection Signal | Setting | Value |
|-----------------|---------|-------|
| `.env.example` with secrets | `env.KEY` | `"__KEY__"` with matching prompt |
| Large test suite | `env.CI` | `"1"` if tests need it |
| Monorepo | `env.PROJECT_ROOT` | `"__PROJECT_ROOT__"` |

## Common Patterns (full stack examples)

### iOS/macOS Swift Project
- brew: swiftformat, swiftlint, node (for MCP)
- mcp: XcodeBuildMCP (depends on node)
- hook: SessionStart for build env check
- template: build/test commands, Swift conventions
- prompt: fileDetect for .xcodeproj/.xcworkspace
- settings: plan mode
- gitignore: standard + .xcodebuildmcp
- doctor: xcode-select check

### Node.js Web Project
- brew: node
- mcp: based on detected DB
- hook: SessionStart for npm outdated
- template: build/test/lint commands, framework conventions
- prompt: select for package manager if ambiguous
- settings: plan mode
- gitignore: standard

### Python Project
- brew: python (if needed)
- mcp: based on detected DB
- hook: SessionStart for dependency check
- template: venv setup, test runner, linting
- settings: plan mode, env vars from .env.example
- gitignore: standard

### Rust Project
- template: cargo commands, clippy conventions
- settings: plan mode
- gitignore: standard

### Go Project
- template: go build/test/vet, module conventions
- settings: plan mode
- gitignore: standard

### Multi-Language Monorepo
- One brew component per detected runtime
- MCP servers for shared services (DB, API)
- Template with workspace-level instructions
- Prompt to select primary language/framework
