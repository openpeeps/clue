# Package

version       = "0.1.3"
author        = "George Lemon"
description   = "A cool toolkit for Nim developers"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

installDirs = @["clue"]

# Dependencies

requires "nim >= 2.0"
requires "semver >= 1.2.3"
requires "kapsis >= 0.3.4"
requires "openparser >= 0.1.4"
requires "boogie >= 0.1.0"
