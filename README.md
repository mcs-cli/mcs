<div align="center">

# ⚡ Managed Claude Stack (`mcs`)

**Your Claude Code environment — packaged, portable, and reproducible.**

[![Swift 6.0+](https://img.shields.io/badge/Swift-6.0+-F05138.svg?logo=swift&logoColor=white)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13+-000000.svg?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Homebrew](https://img.shields.io/badge/Homebrew-tap-FBB040.svg?logo=homebrew&logoColor=white)](https://github.com/bguidolim/homebrew-tap)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-❤️-ea4aaa.svg?logo=github)](https://github.com/sponsors/bguidolim)

</div>

---
> [!WARNING]
> **This project is under active development.** Expect breaking changes, bugs, and incomplete features. Migrations between versions are not guaranteed. Use at your own risk.
---

## 🚀 Quick Start

### 1. Install

```bash
brew install bguidolim/tap/managed-claude-stack
```

### 2. Add tech packs

```bash
mcs pack add bguidolim/mcs-continuous-learning
```

### 3. Sync a project

```bash
cd ~/Developer/my-project
mcs sync
```

### 4. Verify everything

```bash
mcs doctor
```

That's it. Your MCP servers, plugins, hooks, skills, commands, agents, settings, and templates are all in place.

<details>
<summary><strong>📋 Prerequisites</strong></summary>

- macOS 13+ (Apple Silicon or Intel)
- Xcode Command Line Tools
  ```bash
  xcode-select --install
  ```
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude`)
- [Homebrew](https://brew.sh)

</details>

---

## The Problem

You've spent hours getting Claude Code just right — MCP servers, plugins, hooks, skills, custom commands, fine-tuned settings. Then:

- 🖥️ **New machine?** Start over from scratch.
- 👥 **Onboarding a teammate?** "Just follow this 47-step wiki page."
- 📂 **Different projects?** Copy-paste configs, hope nothing drifts.
- 🔄 **Something broke?** Good luck figuring out what changed.

## The Solution

`mcs` is a **configuration engine for Claude Code** — like Ansible for your AI development environment. Package everything into shareable **tech packs** (Git repos with a `techpack.yaml` manifest), then sync them across any project, any machine, in seconds.

| Without `mcs` | With `mcs` |
|---|---|
| Install MCP servers one by one | `mcs pack add` + `mcs sync` |
| Hand-edit `settings.json` per project | Managed settings composition |
| Copy hooks between projects manually | Auto-installed per-project from packs |
| Configuration drifts silently | `mcs doctor --fix` detects and repairs |
| Rebuild from memory on new machines | Fully reproducible in minutes |
| No way to share your setup | Push a pack, anyone can `mcs pack add` it |

---

## 🔍 Real-World Examples

Packs are modular — mix and match what you need instead of one monolith:

| Pack | Description | Highlights |
|------|-------------|------------|
| [**mcs-core-pack**](https://github.com/bguidolim/mcs-core-pack) | Foundational settings, plugins, git workflows, and code navigation | Serena (LSP), plan mode, `/commit`, PR review agents, session-start git status |
| [**mcs-continuous-learning**](https://github.com/bguidolim/mcs-continuous-learning) | Persistent memory and knowledge management across sessions | Ollama embeddings, semantic search via `docs-mcp-server`, auto-extracted learnings |
| [**mcs-ios-pack**](https://github.com/bguidolim/mcs-ios-pack) | Xcode integration, simulator management, and Apple documentation | XcodeBuildMCP, Sosumi docs, auto-detected project config, simulator hooks |

> 💡 Use these as a starting point — fork one to build your own, or combine all three with `mcs pack add` for a complete setup.

---

## ⚙️ How It Works

```
 Tech Packs          mcs sync          Your Project
 (Git repos)  -----> (engine)  -----> (configured)
                        |
                   .---------.
                   |         |
                   v         v
              Per-Project  Global
              artifacts    artifacts
```

1. **Select** which packs to apply (interactive multi-select or `--all`)
2. **Resolve** prompts (auto-detect project files, ask for config values)
3. **Install** artifacts to the right locations (skills, hooks, commands, agents, settings, MCP servers)
4. **Track** everything for convergence — re-running `mcs sync` adds what's missing, removes what's deselected, and updates what changed

Use `mcs sync --global` for global-scope components (Homebrew packages, plugins, global MCP servers). See [Architecture](docs/architecture.md) for artifact locations and the full sync flow.

---

## 📦 What's in a Tech Pack?

A tech pack is a Git repo with a `techpack.yaml` manifest. It can bundle MCP servers, plugins, hooks, skills, commands, agents, settings, templates, and doctor checks — anything `mcs` can install, verify, and uninstall.

📖 **Full guide:** [Creating Tech Packs](docs/creating-tech-packs.md) · **Schema reference:** [techpack-schema.md](docs/techpack-schema.md)

---

## 🎯 Use Cases

- **🧑‍💻 Solo Developer** — New Mac? One `mcs pack add` + `mcs sync` and your entire Claude Code environment is back. No wiki, no notes, no memory required.
- **👥 Teams** — Create a team pack with your org's MCP servers, approved plugins, and coding standards. Every developer gets the same setup with `mcs sync --all`.
- **🌐 Open Source** — Ship a tech pack with your repo. Contributors run `mcs sync` and get the right MCP servers, skills, and conventions automatically.
- **🧪 Experimentation** — Try a different set of MCP servers, swap packs, roll back. `mcs` converges cleanly — deselected packs are fully removed, no leftovers.

---

## 🛡️ Safety & Trust

`mcs` is designed to be non-destructive and transparent. Timestamped backups before modifying user content, `--dry-run` to preview changes, section markers to preserve your edits in `CLAUDE.local.md`, and SHA-256 trust verification for pack scripts. Lockfiles (`mcs.lock.yaml`) pin pack versions for reproducible environments.

📖 **Full details:** [Architecture > Safety & Trust](docs/architecture.md#safety--trust)

---

## 🔍 Verifying Your Setup with Poirot

After `mcs sync`, want to confirm everything landed correctly? [**Poirot**](https://github.com/leonardocardoso/poirot) is a native macOS companion that gives you a visual overview of your Claude Code configuration — MCP servers, settings, sessions, and more — all in one place.

The perfect complement to `mcs`: configure your environment with `mcs`, then use Poirot to see exactly what's installed and running.

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| 📖 [CLI Reference](docs/cli.md) | Complete command reference (`sync`, `pack`, `doctor`, `export`, `cleanup`) |
| 📖 [Creating Tech Packs](docs/creating-tech-packs.md) | Step-by-step guide to building your first pack |
| 📋 [Tech Pack Schema](docs/techpack-schema.md) | Complete `techpack.yaml` field reference |
| 🏗️ [Architecture](docs/architecture.md) | Internal design, sync flow, safety guarantees, and extension points |
| 🔧 [Troubleshooting](docs/troubleshooting.md) | Common issues and fixes |

---

## 🛠️ Development

```bash
swift build                                            # Build
swift test                                             # Run tests
swift build -c release --arch arm64 --arch x86_64      # Universal binary
```

See [Architecture](docs/architecture.md) for project structure and design decisions.

## 🤝 Contributing

Tech pack ideas and engine improvements are welcome!

1. Fork the repo
2. Create a feature branch
3. Run `swift test`
4. Open a PR

For building new packs, start with [Creating Tech Packs](docs/creating-tech-packs.md).

---

<div align="center">

## 💛 Support

If `mcs` saves you time, consider [sponsoring the project](https://github.com/sponsors/bguidolim).

**MIT License** · Made with ❤️ by [Bruno Guidolim](https://github.com/bguidolim)

</div>
