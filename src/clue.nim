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
      install string(pkg), ?bool("--refresh"), ?string("--features"), ?bool("--verbose"):
        ## Install a package from remote source
      uninstall string(pkg):
        ## Uninstall a package from the system
      dump string(pkg):
        ## Dump package info from registry
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
          ## Build documentation for a Nim package
        open string(pkgname):
          ## Open built docs in the browser
