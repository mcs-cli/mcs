# Troubleshooting

This guide covers common issues and how to resolve them. Start by running `mcs doctor` to get a diagnostic report -- most problems will show up there.

```bash
mcs doctor           # Diagnose (project + global packs)
mcs doctor --fix     # Diagnose and auto-fix what's possible
mcs doctor --global  # Check globally-configured packs only
```

## Dependencies

### Homebrew not installed

**Symptom**: `mcs sync` fails with "Homebrew is required but not installed."

**Fix**: Install Homebrew first:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Then re-run `mcs sync`.

### Xcode Command Line Tools missing

**Symptom**: `mcs sync` fails with "Xcode Command Line Tools not found."

**Fix**:
```bash
xcode-select --install
```

Follow the system dialog to complete installation, then re-run `mcs sync`.

### Node.js not found

**Symptom**: MCP servers that use `npx` fail to start or install.

**Fix**: Node.js is auto-resolved as a dependency if your pack declares it. Re-run:
```bash
mcs sync
```

If you manage Node.js through nvm or similar, make sure it's available in your PATH during installation.

### Claude Code CLI not found

**Symptom**: MCP servers and plugins can't be registered.

**Fix**: Install Claude Code:
```bash
brew install --cask claude-code
```

Verify:
```bash
claude --version
```

## MCP Servers

### MCP server not registered

**Symptom**: `mcs doctor` shows a server as "not registered" or `claude mcp list` doesn't show it.

**Fix**: Re-run sync for your project:
```bash
cd /path/to/project
mcs sync
```

Or for global-scope servers:
```bash
mcs sync --global
```

### MCP server registered with wrong scope

**Symptom**: Server works in one project but not another, or is unexpectedly shared.

MCP servers have three scopes:
- **`local`** (default): per-user, per-project — only active in the project where it was configured
- **`project`**: team-shared — active for anyone who clones the repo
- **`user`**: cross-project — active everywhere

**Fix**: Remove and re-register with the correct scope:
```bash
claude mcp remove <server-name>
cd /path/to/project
mcs sync
```

### Sosumi not responding

**Symptom**: Apple documentation search via Sosumi returns errors.

Sosumi uses HTTP transport (external service at `https://sosumi.ai/mcp`). Check your internet connection and verify the server is registered:
```bash
claude mcp list
```

If not registered, re-run sync:
```bash
cd /path/to/project
mcs sync
```

## Plugins

### Plugin not enabled

**Symptom**: `mcs doctor` shows a plugin as "not enabled."

**Fix**: Re-run sync:
```bash
mcs sync
```

You can also manually install a plugin:
```bash
claude plugin install <plugin-name>@<org>
```

## Project Configuration

### No packs registered

**Symptom**: `mcs sync` shows "No packs registered."

**Fix**: Add a pack first:
```bash
mcs pack add https://github.com/user/my-pack
mcs sync
```

### CLAUDE.local.md not found

**Symptom**: `mcs doctor` skips project checks or shows "CLAUDE.local.md not found."

**Fix**: Sync the project:
```bash
cd /path/to/your/project
mcs sync
```

### CLAUDE.local.md sections outdated

**Symptom**: `mcs doctor` shows "outdated sections."

**Fix**: Re-run sync to update sections:
```bash
cd /path/to/your/project
mcs sync
```

Managed sections (inside `<!-- mcs:begin/end -->` markers) are updated. Content you added outside markers is preserved.

### .mcs-project file missing

**Symptom**: `mcs doctor` warns "CLAUDE.local.md exists but .mcs-project missing."

**Fix**: `mcs doctor --fix` can create the state file by inferring packs from CLAUDE.local.md section markers. Or re-run sync:
```bash
mcs sync
```

### Per-project artifacts not appearing

**Symptom**: After `mcs sync`, expected files are missing from `<project>/.claude/`.

**Causes**:
1. The pack wasn't selected during multi-select
2. The pack's `techpack.yaml` doesn't define the expected components

**Fix**:
```bash
# Check what's configured
cat .claude/.mcs-project

# Re-run sync and ensure the pack is selected
mcs sync
```

### Components showing "excluded via --customize"

**Symptom**: `mcs doctor` shows dimmed `○ <component>: excluded via --customize` entries.

This is informational, not a failure. These components were explicitly deselected during `mcs sync --customize` and are intentionally skipped. If the component is installed globally, it will show as passing instead.

### Unpaired section markers

**Symptom**: `mcs sync` warns about "unpaired section markers."

This means a `<!-- mcs:begin X -->` marker exists without a matching `<!-- mcs:end X -->` (or vice versa) in CLAUDE.local.md.

**Fix**: Manually add the missing marker, then re-run sync:
```bash
mcs sync
```

## External Packs

### Pack add fails

**Symptom**: `mcs pack add` fails with a Git error or "path does not exist".

**Causes**:
1. The URL/shorthand is not a valid Git repository
2. No `techpack.yaml` exists in the repository or directory root
3. Network connectivity issues (for git packs)
4. The local path does not exist or is a file instead of a directory

**Fix**: Verify the source is correct and contains a `techpack.yaml`:
```bash
git ls-remote <url>            # Verify git repo exists
ls /path/to/pack/techpack.yaml # Verify local pack has manifest
```

### Pack update fails

**Symptom**: `mcs pack update` fails for a specific pack.

**Note**: Local packs don't need updating — changes are picked up automatically on next `mcs sync`.

**Fix**: For git packs, try removing and re-adding:
```bash
mcs pack remove <name>
mcs pack add <url>
```

## Global Gitignore

### Missing gitignore entries

**Symptom**: `mcs doctor` shows "missing entries" in the gitignore check.

**Fix**: `mcs doctor --fix` adds missing entries automatically:
```bash
mcs doctor --fix
```

## Backup Files

### Too many backup files

Over time, `mcs sync` creates timestamped backups of files it modifies.

**Fix**: Clean them up:
```bash
mcs cleanup          # Lists backups and asks before deleting
mcs cleanup --force  # Deletes without confirmation
```

## Getting More Help

If `mcs doctor` doesn't identify the problem:

1. Check that your PATH includes the necessary binaries (`brew`, `node`, `claude`)
2. Verify `~/.claude.json` is valid JSON: `python3 -m json.tool ~/.claude.json`
3. Verify `~/.claude/settings.json` is valid JSON: `python3 -m json.tool ~/.claude/settings.json`
4. Check `.claude/.mcs-project` in your project for state corruption
5. Open an issue at the project repository with the output of `mcs doctor`

---

**Back to**: [Documentation Home](README.md)

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
