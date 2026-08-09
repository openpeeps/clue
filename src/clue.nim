# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[manager, build, docs, doctor]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      build ?string(file), ?bool("--release"), ?bool("--debug"), ?string("--features"), ?bool("--verbose"), ?string("--out"):
        ## Build the current Nim package from its nimble file, or a single
        ## module (`clue build foo.nim`) with installed packages on the path
      install ?string(pkg), ?bool("--refresh"), ?string("--features"), ?bool("--verbose"), ?bool("--build"), ?bool("--debug"):
        ## Install a package from remote source into the clue registry (or the
        ## current nimble package). `--build` also compiles its binaries
        ## (release by default) to ~/.clue/bin — opt-in, since building executes
        ## the package's {.compile.}/staticExec code
      develop:
        ## Develop-mode (editable) install of the current nimble package — no
        ## compilation, just makes the package importable by other packages via
        ## library discovery (its files are never copied nor deleted)
      uninstall string(pkg):
        ## Uninstall a package from the system
      dump string(pkg), ?bool("--refresh"):
        ## Dump package info from registry, available versions and git activity
      versions string(pkg), ?bool("--refresh"):
        ## List available versions for a package
      prune:
        ## Remove orphaned or out-of-range installed packages

      -- "Environment Management"
      venv string("--nim"):
        ## Manage virtual environments for Nim projects
      
      #
      # Manage local documentations like a pro
      #
      -- "Documentation"
      docs:
        ## Generate Nim docs for local packages
        gen string(pkgname):
          ## Build documentation for an installed package (`pkg` or `pkg@version`)
        open string(pkgname), ?port("--port"):
          ## Serve local docs over HTTP (default port 11000)
