# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

when isMainModule:
  # Build the CLI with Kapsis
  import pkg/kapsis
  import ./clue/commands/[docs, pkits, bindgen]

  # proc docsGenCommand*(v: Values) =
  #   ## Kapsis command for deploying a project to a hosting platform
  #   discard

  # proc docsOpenCommand*(v: Values) =
  #   ## Kapsis command for deploying a project to a hosting platform
  #   discard

  initKapsis do:
    commands:
      -- "Documentation"
      docs:
        ## Generate Nim docs for local packages
        gen string(pkgname):
          ## Generate documentation for a specific package

        open string(pkgname):
          ## Open specified pkg docs in the browser

      -- "Plugin Kits"
      plugins:
        ## Commands for building native plugins
        # js path(module):
        #   ## Generate a JavaScript N-API addon
        py path(module):
          ## Generate a Python extension
        php path(module):
          ## Generate a PHP extension
        ruby path(module):
          ## Generate a Ruby extension
        lua path(module):
          ## Generate a Lua extension
      -- "Bindings"
      capi:
        ## Generate Nim bindings for a C library
        header path(header):
          ## Generate bindings from a C header file
        package string(pkgname):
          ## Generate bindings for a C library as a Nim package

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