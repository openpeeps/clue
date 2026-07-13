# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[pkgmanager_commands, docs_commands, kits_commands]

  initKapsis do:
    commands:
      #
      # Manage local packages when nimble fails
      #
      -- "Package Management"
      install string(pkg):
        ## Install a package from remote source
      uninstall string(pkg):
        ## Uninstall a package from the system
      dump string(pkg):
        ## Dump package info from registry

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
      plugins:
        ## Commands for building native plugins
        py path(module):
          ## Generate a Python extension
        php path(module):
          ## Generate a PHP extension
        ruby path(module):
          ## Generate a Ruby extension
        lua path(module):
          ## Generate a Lua extension
      
      # we need to finish github.com/openpeeps/sweetsyntax
      # in order to create a C to Nim generator
      # -- "Bindings"
      # capi:
      #   ## Generate Nim bindings for a C library
      #   header path(header):
      #     ## Generate bindings from a C header file
      #   package string(pkgname):
      #     ## Generate bindings for a C library as a Nim package

      # -- "Bundlers"
      #   ## Commands for bundling plugins for different package managers
      #   npm path(module):
      #     ## Bundle a JavaScript N-API addon for publishing on npm
      #   pypi path(module):
      #     ## Bundle a Python extension for publishing on PyPI
      #   pie path(module):
      #     ## Bundle a PHP extension for publishing on PIE (PHP Installer for Extensions)

      # -- "OpenAPI Client Generation"
      # openapi path(spec):
      #   ## Generate a new API client library from OpenAPI spec file
else:
  error("Nothing to see here. Import submodules you need directly")