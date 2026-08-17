# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[manager, build, docs, doctor, deploy, upgrade, bump]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      build ?string(file), ?bool("--release"), ?bool("--debug"),
            ?string("--features"), ?bool("--verbose"), ?string("--out"):
        ## Build the current package or a single module
      bump ?string(version), ?bool("--major"):
        ## Bump the version in the current .nimble file
      develop:
        ## Editable install for live library discovery
      dump string(pkg), ?bool("--refresh"):
        ## Dump package info and git activity
      fetch:
        ## Fetch a fresh packages.json and re-index available packages
      install ?string(pkg), ?bool("--refresh"), ?string("--features"),
              ?bool("--verbose"), ?bool("--build"), ?bool("--debug"):
        ## Install a package from the registry (or local)
      test ?string("--features"), ?bool("--threads"):
        ## Compile and run test modules in tests/
      update ?string(pkg), ?bool("--verbose"):
        ## Upgrade a package and its dependencies
      uninstall string(pkg):
        ## Uninstall a package
      versions string(pkg), ?bool("--refresh"):
        ## List available versions
      prune:
        ## Remove orphaned packages

      -- "Environment Management"
      venv string("--nim"):
        ## Manage virtual environments for Nim projects

      #
      # Deploy your project to production like a pro
      #
      -- "Deployment"
      deploy:
        ## Deploy the current project using clue.deploy.yaml (cli/desktop/web)
        init ?string("--type"), ?bool("--workflow"), ?bool("--yes"), ?bool("--force"):
          ## Scaffold clue.deploy.yaml
        web ?bool("--dry-run"), ?bool("--yes"), ?bool("--verbose"), ?string("--config"),
            ?string("--key"), ?string("--profile"), ?bool("--status"):
          ## Deploy the web target over rsync/ssh (systemd-managed)
      
      #
      # Manage local documentations like a pro
      #
      -- "Documentation"
      docs:
        ## Generate Nim docs for local packages
        gen string(pkg):
          ## Build documentation for an installed package
        open string(pkg), ?port("--port"):
          ## Serve local docs over HTTP (default port 11000)

      -- "Code Quality & Maintenance"
      doctor:
        ## Analyze code quality with nimalyzer
      upgrade:
        ## Self-update clue from GitHub releases