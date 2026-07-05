# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "A cool toolkit for Nim developers"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

# Dependencies

requires "nim >= 2.0"
requires "semver"

requires "kapsis#head"
requires "openparser#head"