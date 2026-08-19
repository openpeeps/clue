# Package

version       = "0.2.0"
author        = "OpenPeeps"
description   = "Package manager for Nim development"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]

installDirs = @["clue"]

# Dependencies

echo version

requires "nim >= 1.0.0"
requires "semver <= 1.2.3"
requires "kapsis >= 0.4.2"
requires "malebolgia >= 1.3.0"
requires "threading >= 0.2.0"
requires "boogie >= 0.1.2"
requires "openparser >= 0.1.9"
requires "sweetsyntax >= 0.1.0"

task test, "run unit tests":
  exec "nim c -r --hints:off --out:/tmp/clue_resolver_test src/clue/pkgmanager/resolver.nim"
  exec "nim c -r --hints:off --out:/tmp/clue_scenarios tests/resolver_scenarios.nim"
  for f in [
      "test_resolver_dfs", "test_resolver_units", "test_nimbleparser",
      "test_versions", "test_configs", "test_manager",
      "test_deploy_configs", "test_deploy_init", "test_deploy_web"]:
    exec "nim c -r --hints:off --out:/tmp/clue_" & f & " tests/" & f & ".nim"
