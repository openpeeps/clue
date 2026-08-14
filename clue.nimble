# Package

version       = "0.1.6"
author        = "OpenPeeps"
description   = "Package manager for Nim development"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

installDirs = @["clue"]

# Dependencies

requires "nim >= 2.0.0"
requires "semver >= 1.2.3"
requires "kapsis >= 0.4.2"
requires "malebolgia >= 1.3.0"
requires "boogie >= 0.1.0"
requires "openparser >= 0.1.4"
requires "sweetsyntax >= 0.1.0"

task test, "run unit tests":
  exec "nim c -r --hints:off --out:/tmp/clue_resolver_test src/clue/pkgmanager/resolver.nim"
  exec "nim c -r --hints:off --out:/tmp/clue_scenarios tests/resolver_scenarios.nim"
