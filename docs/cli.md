# CLI Reference

Complete command reference for `mcs`. For a quick introduction, see the [README](../README.md#-quick-start).

## `mcs sync`

The primary command. Configures a project by selecting packs and installing their artifacts. Running without flags opens interactive multi-select.

```bash
mcs sync [path]                  # Interactive project sync (default command)
mcs sync --pack <name>           # Non-interactive: apply specific pack(s) (repeatable)
mcs sync --all                   # Apply all registered packs without prompts
mcs sync --dry-run               # Preview what would change
mcs sync --customize             # Per-pack component selection
mcs sync --global                # Install to global scope (~/.claude/)
mcs sync --lock                  # Checkout locked versions from mcs.lock.yaml
mcs sync --update                # Fetch latest and update mcs.lock.yaml
```

| Flag | Description |
|------|-------------|
| `[path]` | Project directory (defaults to current directory) |
| `--pack <name>` | Apply a specific pack non-interactively. Repeatable for multiple packs. |
| `--all` | Apply all registered packs without interactive selection. |
| `--dry-run` | Preview changes without writing any files. |
| `--customize` | Per-pack component selection (deselect individual components). |
| `--global` | Sync global-scope components (brew packages, plugins, MCP servers to `~/.claude/`). |
| `--lock` | Check out the commits pinned in `mcs.lock.yaml`. |
| `--update` | Fetch latest pack versions and update `mcs.lock.yaml`. |

`mcs sync` is also the default command — running `mcs` alone is equivalent to `mcs sync`.

## `mcs pack`

Manage registered tech packs.

### `mcs pack add <source>`

Add a tech pack from a git URL, GitHub shorthand, or local path.

```bash
mcs pack add <source>            # Git URL, GitHub shorthand, or local path
mcs pack add user/repo           # GitHub shorthand → https://github.com/user/repo.git
mcs pack add /path/to/pack       # Local pack (read in-place, no clone)
mcs pack add <url> --ref <tag>   # Pin to a specific tag, branch, or commit
mcs pack add <url> --preview     # Preview pack contents without installing
```

| Flag | Description |
|------|-------------|
| `--ref <tag>` | Pin to a specific git tag, branch, or commit (git packs only). |
| `--preview` | Preview the pack's contents without installing. |

Source resolution order: URL schemes → filesystem paths → GitHub shorthand.

### `mcs pack remove <name>`

Remove a registered pack.

```bash
mcs pack remove <name>           # Remove with confirmation
mcs pack remove <name> --force   # Remove without confirmation
```

Removal is federated: `mcs` discovers all projects using the pack (via the project index) and runs convergence cleanup for each scope.

### `mcs pack list`

```bash
mcs pack list                    # List registered packs with status
```

### `mcs pack update [name]`

```bash
mcs pack update [name]           # Update pack(s) to latest version
```

Fetches the latest commits from the remote and updates the local checkout. Local packs are skipped (they are read in-place and pick up changes automatically).

## `mcs doctor`

Diagnose installation health with multi-layer checks.

```bash
mcs doctor                       # Diagnose all packs (project + global)
mcs doctor --fix                 # Diagnose and auto-fix issues
mcs doctor --pack <name>         # Check a specific pack only
mcs doctor --global              # Check globally-configured packs only
```

| Flag | Description |
|------|-------------|
| `--fix` | Auto-fix issues where possible (re-add gitignore entries, create missing state files, etc.). |
| `--pack <name>` | Only check a specific pack. |
| `--global` | Only check globally-configured packs. |

Doctor resolves packs from: explicit `--pack` flag → project `.mcs-project` state → `CLAUDE.local.md` section markers → global manifest.

## `mcs cleanup`

Find and delete timestamped backup files created during sync.

```bash
mcs cleanup                      # List backups and confirm before deleting
mcs cleanup --force              # Delete backups without confirmation
```

## `mcs export`

Export your current Claude Code configuration as a reusable tech pack.

```bash
mcs export <dir>                 # Export current config as a tech pack
mcs export <dir> --global        # Export global scope (~/.claude/)
mcs export <dir> --identifier id # Set pack identifier (prompted if omitted)
mcs export <dir> --non-interactive  # Include everything without prompts
mcs export <dir> --dry-run       # Preview what would be exported
```

| Flag | Description |
|------|-------------|
| `<dir>` | Output directory for the generated pack. |
| `--global` | Export global scope (`~/.claude/`) instead of the current project. |
| `--identifier id` | Set the pack identifier (prompted interactively if omitted). |
| `--non-interactive` | Include all discovered artifacts without prompting for selection. |
| `--dry-run` | Preview what would be exported without writing files. |

The export wizard discovers MCP servers, hooks, skills, commands, agents, plugins, `CLAUDE.md` sections, gitignore entries (global only), and settings. Sensitive env vars are replaced with `__PLACEHOLDER__` tokens and corresponding `prompts:` entries are generated.

---

**Next**: Learn to build packs from scratch in [Creating Tech Packs](creating-tech-packs.md).

---

[Home](README.md) | [CLI Reference](cli.md) | [Creating Tech Packs](creating-tech-packs.md) | [Schema](techpack-schema.md) | [Architecture](architecture.md) | [Troubleshooting](troubleshooting.md)
