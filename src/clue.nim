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
      build ?bool("--release"), ?bool("--debug"):
        ## Build the current Nim package from its nimble file

      dump string(pkg):
        ## Dump package info from registry

      install string(pkg):
        ## Install a package from remote source

      uninstall string(pkg):
        ## Uninstall a package from the system

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
          ## Generate documentation for a specific package

        open string(pkgname):
          ## Open specified pkg docs in the browser
      
      #
      # Build native extensions for other languages
      # from your Nim code
      #
      -- "Plugin Kits"
      plugins path(module), ?string("--ext"):
        ## Build a native extension for other languages from Nim code
      
      -- "Code generator"
      # capi:
      #   ## Generate Nim bindings for a C library
      #   header path(header):
      #     ## Generate bindings from a C header file
      #   package string(pkgname):
      #     ## Generate bindings for a C library as a Nim package
      
      openapi path(spec), ?string("--output"), ?string("--dir"):
        ## Generate a new API client library from OpenAPI spec file

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