<p align="center">
  A cool toolkit for Nim developers!
</p>

<p align="center">
  <code>nimble install clue</code>
</p>

<p align="center">
  <a href="https://github.com/">API reference</a><br>
  <img src="https://github.com/openpeeps/clue/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/clue/workflows/docs/badge.svg" alt="Github Actions">
</p>

### Why Clue?
Clue is an alternative to `nimble` — a friendly toolkit for installing, building
and documenting Nim packages, resolving tricky dependencies, and managing
per-version toolchains with virtual environments when `nimble` just doesn't cut it.

> [!NOTE]
> **Version resolution** — Clue resolves dependencies with a lazy, depth-first
> search (no SAT solver): constraints declared closest to the root are *hard*,
> deeper ones are *soft* tie-breakers ("nearest wins"), dependencies are only
> expanded for versions actually explored, and failed choices backtrack
> chronologically (bounded by a probe limit) until a satisfiable set is found —
> or a clear conflict error is raised.

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

> [!WARNING]
> `=<` is **not valid** — use `<=` instead. Invalid operators are silently
> treated as `*` (any version), which will not enforce the intended constraint.

## 😍 Key Features
- Package management: cached version discovery, transitive dependency resolution, feature flags, SSH installs and orphan pruning
- Build: the current package from its nimble file (`--release`, `--debug`, `--features`), or a bare module (`clue build foo.nim`) with every installed package on the import path
- Opt-in binary builds: `clue install <pkg> --build` compiles a package's binaries (and those of its dependencies) into `~/.clue/bin`; release by default, never done implicitly since building runs the package's code
- Develop mode: `clue develop` links the current package into `~/.clue/develop` for live library discovery (`import pkg/<name>` resolves against your working tree, never copied, never deleted)
- Local installs: `clue install` inside a package directory copies it into the local registry
- Install / uninstall / dump / versions / prune with a local package registry; `clue dump` also shows available versions and recent git activity
- Virtual environments (`venv`) for per-version Nim toolchains via choosenim
- Local documentation: build and browse versioned `nim doc` output right from the command line

> [!NOTE]
> Clue used to be the home for generating native extensions, C wrappers and
> OpenAPI 3.x clients. That codebase now lives in
> [nimbase](https://github.com/nimbase/nimbase) and ships as the `nimbase`
> package. Clue stays focused on making local package management a joy.

## Usage

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

Installed binaries land in `~/.clue/bin` (add it to your `PATH` once). Develop-mode
packages live as symlinks under `~/.clue/develop`; clue will never delete anything
outside `~/.clue/packages`.

Command reference (`clue -h`):
```text
A cool toolkit for Nim developers
  (c) OpenPeeps | MIT License  
  Build Version: 0.1.5

Package Management
  build <?file:string>                Build the current Nim package from its nimble file, or a
                                      single module (`clue build foo.nim`) with installed packages
                                      on the path
             --release:bool
               --debug:bool
          --features:string
             --verbose:bool
               --out:string
  install <?pkg:string>               Install a package from remote source into the clue registry
                                      (or the current nimble package). `--build` also compiles its
                                      binaries (release by default) to ~/.clue/bin — opt-in, since
                                      building executes the package's {.compile.}/staticExec code
             --refresh:bool
          --features:string
             --verbose:bool
               --build:bool
               --debug:bool
  develop                             Develop-mode (editable) install of the current nimble
                                      package — no compilation, just makes the package importable
                                      by other packages via library discovery (its files are never
                                      copied nor deleted)
  uninstall <pkg:string>              Uninstall a package from the system
  dump <pkg:string>                   Dump package info from registry, available versions and git
                                      activity
          --refresh:bool
  versions <pkg:string>               List available versions for a package
          --refresh:bool
  prune                               Remove orphaned or out-of-range installed packages
Environment Management
  venv                                Manage virtual environments for Nim projects
          --nim:string
Documentation
  docs.gen <pkgname:string>           Build documentation for an installed package (`pkg` or
                                      `pkg@version`)
  docs.open <pkgname:string>          Serve local docs over HTTP (default port 11000)
          --port:port
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
