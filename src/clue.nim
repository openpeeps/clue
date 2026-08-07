# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[pkgmanager_commands, docs_commands,
          kits_commands, build_commands, oapi_commands]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      build ?bool("--release"), ?bool("--debug"), ?string("--features"),
            ?bool("--verbose"):
        ## Build the current Nim package from its nimble file
      install string(pkg), ?bool("--refresh"), ?string("--features"):
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
      
      #
      # Build native extensions for other languages
      # from your Nim code
      #
      -- "Native Extensions"
      extension path(module), ?string("--ext"):
        ## Build a native extension for other languages from Nim code
      
      -- "Code generator"
      openapi:
        ## OpenAPI 3.x utilities
        init:
          ## Initialize a default clue.openapi.config.yaml file
        gen path(spec), string("output"), ?string("--config"), ?bool("-y"):
          ## Generate a new API client library from OpenAPI 3.x spec file
        mock path(spec), ?string("--host"), ?string("--port"):
          ## Spin up a local mock server from OpenAPI 3.x spec file

      # -- "Bundlers"
      #   ## Commands for bundling plugins for different package managers
      #   npm path(module):
      #     ## Bundle a JavaScript N-API addon for publishing on npm
      #   pypi path(module):
      #     ## Bundle a Python extension for publishing on PyPI
      #   pie path(module):
      #     ## Bundle a PHP extension for publishing on PIE (PHP Installer for Extensions)
else:
  error("Nothing to see here. Import submodules you need directly")