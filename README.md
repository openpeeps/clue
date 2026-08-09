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
Because sometimes I have no damn clue how to... 😂

Clue is an alternative to `nimble` — a friendly toolkit for installing, building
and documenting Nim packages, resolving tricky dependencies, and managing
per-version toolchains with virtual environments when `nimble` just doesn't cut it.

## 😍 Key Features
- [x] **Package management** — cached version discovery, transitive dependency resolution, feature flags, SSH installs & orphan pruning
- [x] **Build** the current package from its nimble file (`--release`, `--debug`, `--features`)
- [x] **Install / uninstall / dump / versions / prune** with a local package registry
- [x] **Virtual environments** (`venv`) for per-version Nim toolchains via choosenim
- [x] **Local documentation** — build & browse versioned `nim doc` output right from the command line

> [!NOTE]
> Clue used to be the home for generating native extensions, C wrappers and
> OpenAPI 3.x clients. That codebase now lives in
> [nimbase](https://github.com/openpeeps/nimbase) and ships as the `nimbase`
> package. Clue stays focused on making local package management a joy.

## Usage

### Package Management
```sh
# Build the current package from its nimble file
clue build
clue build --release
clue build --features:ssl,jwt

# Install / uninstall packages from the registry
clue install spry
clue install spry@1.2.0
clue install ssl#master
clue install https://github.com/user/repo
clue uninstall spry

# Inspect the registry
clue dump spry
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
# Build local documentation for a package
clue docs gen spry

# Open the built docs in your browser
clue docs open spry
```

## Documentation Builder
Clue offers a local documentation generator built on top of the built-in Nim
`doc` system. Because most of the time package authors focus on writing code and
don't provide an easy way to access documentation for their packages, Clue lets
you build & open docs for any local package right from the terminal.

- Versioned `nim doc` output stored under `~/.clue`
- Auto-generated overview page for everything you've documented
- `clue docs open <pkg>` gets you straight to the latest build

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