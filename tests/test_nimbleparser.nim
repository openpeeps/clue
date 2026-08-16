# Clue nimble parser — unit tests for requires-arg parsing, feature
# extraction and full .nimble file parsing (both the sweetsyntax AST path
# and the line-based fallback).

import std/[os, tables, unittest]
import clue/pkgmanager/resolver
import clue/pkgmanager/configs
import clue/pkgmanager/nimbleparser

suite "nimbleparser — parseRequiresArg":
  test "plain name becomes an any constraint":
    let d = parseRequiresArg("spry")
    check d.name == "spry"
    check $d.constraint == "*"
    check not d.isNim
    check d.features.len == 0

  test "name with semver constraint":
    let d = parseRequiresArg("spry >= 1.2.0")
    check d.name == "spry"
    check $d.constraint == ">= 1.2.0"

  test "name with == operator normalizes to =":
    let d = parseRequiresArg("spry == 1.2.0")
    check d.name == "spry"
    check $d.constraint == "= 1.2.0"

  test "short versions are padded to three components":
    let d = parseRequiresArg("spry >= 1.2")
    check $d.constraint == ">= 1.2.0"

  test "name with branch ref":
    let d = parseRequiresArg("spry#master")
    check d.name == "spry"
    check d.branch == "master"
    check $d.constraint == "*"

  test "nim is flagged":
    let d = parseRequiresArg("nim >= 2.0.0")
    check d.isNim

  test "feature activation is stripped and captured":
    var d = parseRequiresArg("jester[ssl, jwt]")
    check d.name == "jester"
    check d.features == @["ssl", "jwt"]

  test "feature list with spaces":
    var d = parseRequiresArg("jester[ssl, jwt, async]")
    check d.features == @["ssl", "jwt", "async"]

  test "https URL dep with ref":
    let d = parseRequiresArg("https://github.com/openpeeps/spry#master")
    check d.url == "https://github.com/openpeeps/spry"
    check d.tag == "master"

  test "https URL dep with constraint":
    let d = parseRequiresArg("https://github.com/openpeeps/spry >= 1.2.0")
    check d.url == "https://github.com/openpeeps/spry"
    check $d.constraint == ">= 1.2.0"

  test "bare URL dep":
    let d = parseRequiresArg("https://github.com/openpeeps/spry")
    check d.url == "https://github.com/openpeeps/spry"

suite "nimbleparser — parseNimbleString metadata":
  test "captures scalar metadata fields":
    let f = parseNimbleString("""
# Package
version       = "0.1.7"
author        = "OpenPeeps"
description   = "A cool toolkit"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
""")
    check f.version == "0.1.7"
    check f.author == "OpenPeeps"
    check f.description == "A cool toolkit"
    check f.license == "MIT"
    check f.srcDir == "src"
    check f.binDir == "bin"

  test "captures bin and installDirs arrays":
    let f = parseNimbleString("""
bin = @["clue"]
installDirs = @["clue"]
""")
    check f.bin == @["clue"]
    check f.installDirs == @["clue"]

  test "captures single-item bin (non-array form)":
    let f = parseNimbleString("bin = \"clue\"")
    check f.bin == @["clue"]

  test "requires line parses multiple comma-separated deps":
    let f = parseNimbleString("""
requires "semver >= 1.2.3, kapsis >= 0.4.2, nim >= 2.0.0"
""")
    check f.requires.len == 3
    check f.requires[0].name == "semver"
    check $f.requires[0].constraint == ">= 1.2.3"
    check f.requires[2].isNim

  test "requires with feature activation on a dependency":
    let f = parseNimbleString("""
requires "jester[ssl, jwt]"
""")
    check f.requires.len == 1
    check f.requires[0].name == "jester"
    check f.requires[0].features == @["ssl", "jwt"]

suite "nimbleparser — feature and dev blocks":
  test "feature blocks become conditional deps":
    let f = parseNimbleString("""
requires "core >= 1.0.0"

feature "ssl":
  requires "openssl >= 1.0.0"
  requires "raccoon"

feature "jwt":
  requires "jwtlib"
""")
    check f.requires.len == 1
    check f.features.hasKey("ssl")
    check f.features["ssl"].len == 2
    check f.features["ssl"][0].name == "openssl"
    check f.features.hasKey("jwt")
    check f.features["jwt"][0].name == "jwtlib"

  test "dev block is captured separately":
    let f = parseNimbleString("""
requires "core >= 1.0.0"

dev:
  requires "testutils >= 2.0.0"
""")
    check f.requires.len == 1
    check f.dev.len == 1
    check f.dev[0].name == "testutils"

  test "skipDirs and skipFiles are parsed":
    let f = parseNimbleString("""
skipDirs = @["tests", "docs"]
skipFiles = @["README.md"]
""")
    check f.skipDirs == @["tests", "docs"]
    check f.skipFiles == @["README.md"]

  test "full realistic nimble file":
    let f = parseNimbleString("""
version       = "0.1.7"
author        = "OpenPeeps"
description   = "Package manager for Nim"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["clue"]
installDirs   = @["clue"]

requires "nim >= 2.0.0"
requires "semver >= 1.2.3"
requires "kapsis >= 0.4.2"

feature "ssl":
  requires "openssl >= 1.0.0"

dev:
  requires "testutils"
""")
    check f.version == "0.1.7"
    check f.bin == @["clue"]
    check f.requires.len == 3
    check f.features.hasKey("ssl")
    check f.dev.len == 1

suite "nimbleparser — findNimbleFile":
  test "locates the nimble file in a directory":
    let dir = getTempDir() / "clue_nimbleparser_test" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "foo.nimble", "version = \"1.0.0\"\n")
    writeFile(dir / "ignored.txt", "x")
    let found = findNimbleFile(dir)
    check found.extractFilename == "foo.nimble"

  test "ignores nim.nimble in a directory":
    let dir = getTempDir() / "clue_nimbleparser_nim" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "nim.nimble", "version = \"1.0.0\"\n")
    check findNimbleFile(dir) == ""
