# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[manager, build, docs, doctor,
        deploy, upgrade, bump, nimscript, init, sources, dbcheck]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      build ?string(file), ?bool("--release"), ?bool("--debug"),
            ?string("--features"), ?bool("--verbose"), ?string("--out"),
            ?string("-o"), ?any("-b" = ["c", "cpp", "objc", "js"]):
        ## Build the current package or a single module
      bump ?string(pkgOrVersion), ?string(version), ?string("--level"):
        ## Bump the version in the current .nimble file, or a root dependency's
        ## version constraint (`clue bump nim 2.2.0`)
      check ?string(file), ?string("--features"):
        ## Checks the project for syntax and semantics
      develop:
        ## Editable install for live library discovery
      dump ?string(pkg), ?bool("--refresh"):
        ## Dump package info in JSON format
      init ?string(name), ?bool("-Y"):
        ## Initialize a new nimble project in the current directory
      install ?string(pkg), ?bool("--refresh"), ?string("--features"),
              ?bool("--verbose"), ?bool("--build"), ?bool("--debug"),
              ?string("--source"), ?any("-b" = ["c", "cpp", "objc", "js"]):
        ## Install a package from the registry (or local)
      test ?any("-b" = ["c", "cpp", "objc", "js"]):
        ## Compile and run test modules in tests/
      update ?string(pkg), ?bool("--verbose"):
        ## Upgrade a package and its dependencies
      uninstall string(pkg):
        ## Uninstall a package
      versions string(pkg), ?bool("--refresh"):
        ## List available versions
      prune:
        ## Remove orphaned packages
      
      -- "Directories"
      source:
        ## Manage package registry sources
        add string(name), string(url):
          ## Add a registry source
        fetch ?string(name):
          ## Fetch packages.json for a source (or all)
        list:
          ## List configured sources
        remove string(name):
          ## Remove a registry source

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
      task ?string(taskName):
        ## List or run nimscript tasks from the current .nimble file
      dbcheck ?string(query), ?bool("--json"):
        ## Enter REPL for clue database (read-only SELECT)
      dbcheck:
        ## Inspect boogie databases with read-only SQL
        versions ?string(query), ?bool("--json"):
          ## Enter REPL for versions database (read-only SELECT)
      upgrade:
        ## Self-update clue from GitHub releases