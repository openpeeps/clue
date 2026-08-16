# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[manager, build, docs, doctor, deploy]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      build ?string(file), ?bool("--release"), ?bool("--debug"),
            ?string("--features"), ?bool("--verbose"), ?string("--out"):
        ## Build the current Nim package from its nimble file, or a single
        ## module (`clue build foo.nim`) with installed packages on the path
      install ?string(pkg), ?bool("--refresh"), ?string("--features"),
              ?bool("--verbose"), ?bool("--build"), ?bool("--debug"):
        ## Install a package from remote source into the clue registry (or the
        ## current nimble package). `--build` also compiles its binaries
        ## (release by default) to ~/.clue/bin — opt-in, since building executes
        ## the package's {.compile.}/staticExec code
      update ?string(pkg), ?bool("--verbose"):
        ## Fetch new tags from remote for a package (or every installed root
        ## package) and upgrade it and its dependencies to the newest
        ## satisfying versions
      test ?string("--features"), ?bool("--threads"):
        ## Compile and run the test modules in tests/ (files starting with
        ## `test`, with any tests/*.nims config picked up automatically)
        ## against clue-managed dependencies, printing nim's output.
        ## `--threads` compiles and runs them in parallel (one by one by default)
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
      registry:
        ## Manage the package registry index (nim-lang/packages)
        update:
          ## Fetch a fresh packages.json and re-index available packages

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
          ## Scaffold clue.deploy.yaml (+ optionally .github/workflows/release.yml)
        web ?bool("--dry-run"), ?bool("--yes"), ?bool("--verbose"), ?string("--config"),
            ?string("--key"), ?string("--profile"), ?bool("--status"):
          ## Deploy the web target over rsync/ssh (systemd-managed)
      
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
