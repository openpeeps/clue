<p align="center">
  An alternative package manager for Nim development
</p>

<p align="center">
  <code>nimble install clue</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/clue/">API reference</a><br>
  <img src="https://github.com/openpeeps/clue/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/clue/workflows/docs/badge.svg" alt="Github Actions">
</p>

### Why Clue?
Clue is an alternative to `nimble` — a friendly development tool for installing, building
and documenting Nim packages, resolving tricky dependencies, and managing
per-version toolchains with virtual environments when `nimble` just doesn't cut it.

## 😍 Key Features
- Package management: cached version discovery, transitive dependency resolution, feature flags, SSH installs and orphan pruning
- Build: the current package from its nimble file (`--release`, `--debug`, `--features`), or a bare module (`clue build foo.nim`) with every installed package on the import path
- Opt-in binary builds: `clue install <pkg> --build` compiles a package's binaries (and those of its dependencies) into `~/.clue/bin`; release by default, never done implicitly since building runs the package's code
- Develop mode: `clue develop` links the current package into `~/.clue/develop` for live library discovery (`import pkg/<name>` resolves against your working tree, never copied, never deleted)
- Local installs: `clue install` inside a package directory copies it into the local registry
- Install / uninstall / dump / versions / prune with a local package registry; `clue dump` also shows available versions and recent git activity
- Virtual environments (`venv`) for per-version Nim toolchains via choosenim
- Supports flags forwarding (`-d:xxx`, `--features`, `--mm:arc`, `--passL`, etc.) to Nim compiler
- Local documentation: build and browse versioned `nim doc` output right from the command line

> [!NOTE]
> Clue used to be the home for generating native extensions, C wrappers and
> OpenAPI 3.x clients. That codebase now lives in
> [nimbase](https://github.com/nimbase/nimbase) and ships as the `nimbase`
> package. Clue stays focused on making local package management a joy.

## Usage

Installed binaries land in `~/.clue/bin` (add it to your `PATH` once). Develop-mode
packages live as symlinks under `~/.clue/develop`; clue will never delete anything
outside `~/.clue/packages`.

Command reference (`clue -h`):
```text
A DFS package manager for Nim development
  (c) OpenPeeps | MIT License  
  Build Version: 0.2.5

Package Management
  build <?file:string>                        Build the current package or a single module
                 --release:bool
                   --debug:bool
              --features:string
                 --verbose:bool
                   --out:string
                      -o:string
          -b:any[c,cpp,objc,js]
  bump <?pkgOrVersion:string> <?version:string> Bump the version in the current .nimble file, or a root
                                                dependency's version constraint (`clue bump nim 2.2.0`)
          --level:string
  check <?file:string>                        Checks the project for syntax and semantics
          --features:string
  develop                                     Editable install for live library discovery
  dump <?pkg:string>                          Dump package info and git activity
          --refresh:bool
  init <?name:string>                         Initialize a new nimble project in the current directory
          -Y:bool
  install <?pkg:string>                       Install a package from the registry (or local)
                 --refresh:bool
              --features:string
                 --verbose:bool
                   --build:bool
                   --debug:bool
                --source:string
          -b:any[c,cpp,objc,js]
  test                                        Compile and run test modules in tests/
          -b:any[c,cpp,objc,js]
  update <?pkg:string>                        Upgrade a package and its dependencies
          --verbose:bool
  uninstall <pkg:string>                      Uninstall a package
  versions <pkg:string>                       List available versions
          --refresh:bool
  prune                                       Remove orphaned packages
Directories
  source.add <name:string> <url:string>       Add a registry source
  source.fetch <?name:string>                 Fetch packages.json for a source (or all)
  source.list                                 List configured sources
  source.remove <name:string>                 Remove a registry source
Environment Management
  venv                                        Manage virtual environments for Nim projects
          --nim:string
Deployment
  deploy.init                                 Scaffold clue.deploy.yaml
            --type:string
          --workflow:bool
               --yes:bool
             --force:bool
  deploy.web                                  Deploy the web target over rsync/ssh (systemd-managed)
            --dry-run:bool
                --yes:bool
            --verbose:bool
           --config:string
              --key:string
          --profile:string
             --status:bool
Documentation
  docs.gen <pkg:string>                       Build documentation for an installed package
  docs.open <pkg:string>                      Serve local docs over HTTP (default port 11000)
          --port:port
Code Quality & Maintenance
  doctor                                      Analyze code quality with nimalyzer
  task <?taskName:string>                     List or run nimscript tasks from the current .nimble file
  upgrade                                     Self-update clue from GitHub releases
```

### Package Management

```sh
# Build the current package from its nimble file
clue build
clue build --release
clue build --features:ssl,jwt

# Build a single module with all installed packages on the import path
clue build mymodule.nim

# Install / uninstall packages from the registry
clue install spry
clue install spry@1.2.0
clue install ssl#master
clue install https://github.com/user/repo
clue install --build        # build the current dir's package into the registry
clue install spry --build   # install, then compile its binaries to ~/.clue/bin
clue uninstall spry

# Develop mode: link the current package for live library discovery
# (never copies source; uninstalling only removes the entry, never your files)
clue develop

# Inspect the registry
clue dump spry
clue dump spry --refresh    # also re-read versions + git activity from remote
clue versions spry --refresh
clue prune
```

### Environment Management
```sh
# Create a virtual environment pinned to a specific Nim version
clue venv --nim:2.2.0

source .env/activate     # or: source .env/deactivate
```

### Documentation
```sh
# Build documentation for an installed package (latest version by default)
clue docs.gen spry
clue docs.gen spry@1.2.0

# Serve local docs over HTTP (default port 11000, opens the browser)
clue docs.open spry
clue docs.open spry --port:8080
```

### Supported Constraint Operators

| Operator | Meaning | Example |
|----------|---------|---------|
| `*` | any version | `requires "pkg *"` |
| `=` or `==` | exact match | `requires "pkg = 1.2.3"` |
| `>=` | greater or equal | `requires "pkg >= 1.2.0"` |
| `>` | strictly greater | `requires "pkg > 1.2.0"` |
| `<=` | less or equal | `requires "pkg <= 2.0.0"` |
| `<` | strictly less | `requires "pkg < 2.0.0"` |
| `^` | caret (compatible) | `requires "pkg ^ 1.2.0"` → `>=1.2.0 <2.0.0` |
| `~` or `~>` | tilde (approx) | `requires "pkg ~> 1.2.0"` → `>=1.2.0 <1.3.0` |

> [!NOTE]
> **Version resolution** — Clue resolves dependencies with a lazy, depth-first
> search (no SAT solver): constraints declared closest to the root are *hard*,
> deeper ones are *soft* tie-breakers ("nearest wins"), dependencies are only
> expanded for versions actually explored, and failed choices backtrack
> chronologically (bounded by a probe limit) until a satisfiable set is found,
> or a clear conflict error is raised.

## Documentation Builder
Clue offers a local documentation generator built on top of the built-in Nim
`doc` system. Because most of the time package authors focus on writing code and
don't provide an easy way to access documentation for their packages, Clue lets
you build & serve docs for any clue-installed package right from the terminal.

- Versioned `nim doc` output stored under `~/.clue/docs/<pkg>/<version>`
- Auto-generated overview page for everything you've documented
- `clue docs.open <pkg>` serves the latest build over a minimal in-memory HTTP
  server (stdlib only) at `http://127.0.0.1:11000/`, opening it in your browser
- Optional `--port` to override the default port


### Tell your LLM about Clue

Save the block below as a skill file — e.g. `~/.config/opencode/skills/nim-clue/SKILL.md`
for OpenCode, `CLAUDE.md` or `.cursor/rules/clue.mdc` for other agents, and
your LLM assistant will automatically prefer `clue build`, `clue test`, and
`clue install` over raw `nim c` / `nimble` commands when working on Nim projects.

```md
---
name: nim-clue
description: Use when working on Nim projects (.nim files, .nimble files) — build, test, install packages, and manage the environment with the `clue` package manager instead of nimble or raw `nim c`.
---

# Nim development with clue

## Core rule

In Nim projects, use `clue` as the primary toolchain wrapper. Do NOT use raw
`nim c`, `nimble build`, or `nimble install` unless the user explicitly asks.

Why: clue's depth-first search resolves per-package compiler configuration,
including native C dependencies and header paths (e.g., a package shipping
`spf.h`), which plain `nim c` misses outside the package's own build context.
A build that fails with `fatal error: 'xyz.h' file not found` under `nim c`
usually succeeds under `clue build`.

## Command reference

Full reference (`clue -h`): build 0.2.5. Every flag below mirrors that output.

### Package management
- `clue build <?file:string>` — Build the current package or a single module.
  Default way to compile. Binary lands in project root; redirect with
  `--out:<path>` / `-o:<path>`.
  - `--release:bool` / `--debug:bool` — optimization mode
  - `--features:string` — enable nimble features
  - `--verbose:bool` — verbose output
  - `-b:c|cpp|objc|js` — target backend
  - Example: `clue build src/meowmail.nim --out:bin/meowmail`
- `clue bump <?pkgOrVersion:string> <?version:string>` — Bump version in the
  current `.nimble` file, or a root dependency's constraint
  (`clue bump 1.3.0`, `clue bump nim 2.2.0` with `--level:major|minor|patch`).
- `clue check <?file:string>` — Check project for syntax and semantics
  (`--features:string`).
- `clue develop` — Editable install for live library discovery (symlink under
  `~/.clue/develop`, never copied).
- `clue dump <?pkg:string>` — Dump package info and git activity
  (`--refresh:bool` re-reads versions and git log).
- `clue init <?name:string> -Y:bool` — Initialize a new nimble project in the
  current directory (`-Y` non-interactive defaults).
- `clue install <?pkg:string>` — Install from registry or local path/URL
  (`pkg@version`, `pkg#branch`, `https://...`). Flags: `--refresh:bool`,
  `--features:string`, `--verbose:bool`, `--build:bool`, `--debug:bool`,
  `--source:string`, `-b:c|cpp|objc|js`.
- `clue test` — Compile and run test modules in `tests/` (`-b:c|cpp|objc|js`).
- `clue update <?pkg:string>` — Upgrade a package and its dependencies
  (`--verbose:bool`).
- `clue uninstall <pkg:string>` — Remove a package.
- `clue versions <pkg:string>` — List available versions (`--refresh:bool`).
- `clue prune` — Remove orphaned packages.

### Directories (registry sources)
- `clue source.add <name:string> <url:string>` — Add a registry source.
- `clue source.fetch <?name:string>` — Fetch `packages.json` for a source (or all).
- `clue source.list` — List configured sources.
- `clue source.remove <name:string>` — Remove a registry source.

### Environment
- `clue venv --nim:<version>` — Manage virtual environments for Nim projects
  (isolated Nim toolchains per project via choosenim).

### Code quality & maintenance
- `clue doctor` — Analyze code quality with nimalyzer (lint-style checks).
- `clue task <?taskName:string>` — List or run nimscript tasks declared in the
  current `.nimble` file (no arg = list tasks).
- `clue upgrade` — Self-update clue from GitHub releases.

### Documentation
- `clue docs.gen <pkg:string>` — Build documentation for an installed package.
- `clue docs.open <pkg:string>` — Serve local docs over HTTP (default port
  11000, override with `--port:port`).

### Deployment
- `clue deploy.init` — Scaffold `clue.deploy.yaml` (`--type:string`,
  `--workflow:bool`, `--yes:bool`, `--force:bool`).
- `clue deploy.web` — Deploy web target over rsync/ssh (systemd-managed);
  supports `--dry-run:bool`, `--yes:bool`, `--verbose:bool`, `--config:string`,
  `--key:string`, `--profile:string`, `--status:bool`.

## Agent recipes

- Build a binary: `clue build src/<main>.nim` (add `--release` for production)
- Run the test suite: `clue test`
- Add a dependency: `clue install <pkg>` (then `import pkg/<name>` in code)
- Editable dev: `clue develop` then `import pkg/<name>` resolves to working tree
- Registry source: `clue source.add myfork https://.../packages.json` then
  `clue install pkg --source:myfork` or `clue source.fetch`
- Build failure mentioning a missing `.h` file: retry with `clue build` before
  touching include paths manually

### Official repo
When the user asks for more details about Clue (e.g., features, usage, contributing), fetch and read the full README before answering:
https://raw.githubusercontent.com/openpeeps/clue/refs/heads/main/README.md
```

## Roadmap
- [ ] Docs — LLM integration for RAG over your local documentation
- [ ] Docs — generate a local search index for command-line discovery

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/clue/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/clue/fork)

|  |  |
|---|---|
| <a href="https://opencode.ai/go?ref=BHMEEK48QX"><img src="https://github.com/openpeeps/pistachio/blob/main/.github/opencode.png" alt="OpenCode"></a> | Switch to **Open-Source LLMs** via OpenCode GO, choosing from a variety of powerful models such as DeepSeek, Qwen, Kimi, GLM-5, MiniMax, MiMo. 🍕 [Use our referral link to get started!](https://opencode.ai/go?ref=BHMEEK48QX)|

### 🎩 License
Clue | MIT license. [Made by humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
