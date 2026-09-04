# Package

version       = "0.2.7"
author        = "OpenPeeps"
description   = "A DFS package manager for Nim development"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

installDirs = @["clue"]

# Dependencies

requires "nim >= 1.0.0"
requires "semver >= 1.2.3"
requires "kapsis >= 0.4.7"
requires "malebolgia >= 1.3.0"
requires "threading >= 0.2.0"
requires "boogie >= 0.1.2"
requires "openparser >= 0.2.0"
requires "sweetsyntax >= 0.1.0"
requires "datpkgr >= 0.1.0"
requires "flysystem >= 0.1.1"
