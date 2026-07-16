# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements DSL interface for creating Node.js/Bun 
## extensions in Nim

import std/[macros, strutils]
import ./js/js_api