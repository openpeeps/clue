# Package

version       = "0.3.2"
author        = "OpenPeeps"
description   = "A DFS package manager for Nim development"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

installDirs = @["clue"]

# Dependencies

requires "nim >= 2.2.10"
requires "semver >= 1.2.3"
requires "kapsis >= 0.4.10"
requires "threading >= 0.2.0"
requires "boogie >= 0.2.1"
requires "openparser >= 0.3.6"
requires "sweetsyntax >= 0.2.1"
requires "datpkgr >= 0.1.6"
requires "flysystem >= 0.2.0"
