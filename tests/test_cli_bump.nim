## CLI tests for `clue bump` — self-version modes and root-dependency
## constraint bumps (level-based and explicit), including error paths.

import std/[os, osproc, strutils, unittest]
import cli_helpers

const fixtureNimble = """# Package

version       = "0.1.0"
author        = "Test"
description   = "bump fixture"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "semver >= 1.2.3, flatty >= 0.4.0"
requires "exact == 1.0.0"
requires "caret ^1.5.2"
requires "tilde ~>0.9.1"
requires "gluedge >=2.0.0"
requires "bare"

feature "ssl":
  requires "openssl >= 1.0.0"

dev:
  requires "testutils"
"""

proc bumpFixture(name: string): string =
  ## Fresh scratch dir with the demo .nimble inside.
  let d = getTempDir() / ("clue_cli_bump_" & name & "_" & $getCurrentProcessId())
  removeDir(d)
  createDir(d)
  writeFile(d / "demo.nimble", fixtureNimble)
  d

suite "cli bump — dependency constraints":
  test "level bumps preserve the operator spelling":
    let d = bumpFixture("ops")
    defer: removeDir(d)
    block minorOnCaret:
      let (code, outp) = runClue("bump", "caret", "--level:minor", dir = d)
      checkpoint outp
      check code == 0
      check readNimble(d).contains("caret ^1.6.0")
    block patchOnTilde:
      let (code, outp) = runClue("bump", "tilde", dir = d)
      checkpoint outp
      check code == 0
      check readNimble(d).contains("tilde ~>0.9.2")

  test "explicit target version keeps the operator":
    let d = bumpFixture("explicit")
    defer: removeDir(d)
    block exactDoubleEquals:
      let (code, outp) = runClue("bump", "exact", "2.5.0", dir = d)
      checkpoint outp
      check code == 0
      check readNimble(d).contains("exact == 2.5.0")
    block gluedGteMajor:
      let (code, outp) = runClue("bump", "gluedge", "--level:major", dir = d)
      checkpoint outp
      check code == 0
      check readNimble(d).contains("gluedge >=3.0.0")

  test "multi-dep lines only touch the named package":
    let d = bumpFixture("multiline")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", "semver", "--level:minor", dir = d)
    checkpoint outp
    check code == 0
    let content = readNimble(d)
    check content.contains("semver >= 1.3.0")
    check content.contains("flatty >= 0.4.0")

  test "feature/dev blocks are never touched":
    let d = bumpFixture("blocks")
    defer: removeDir(d)
    let (code, _) = runClue("bump", "nim", "--level:major", dir = d)
    check code == 0
    let content = readNimble(d)
    check content.contains("openssl >= 1.0.0")
    check content.contains("testutils")

suite "cli bump — errors":
  test "bare dependency has no constraint to bump":
    let d = bumpFixture("bare")
    defer: removeDir(d)
    let before = readNimble(d)
    let (code, outp) = runClue("bump", "bare", dir = d)
    check code != 0
    check stripAnsi(outp).contains("no version constraint")
    check readNimble(d) == before

  test "feature-block-only dep is not a root dependency":
    let d = bumpFixture("featuring")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", "openssl", dir = d)
    check code != 0
    check stripAnsi(outp).contains("not a root dependency")

  test "unknown dep is not a root dependency":
    let d = bumpFixture("unknown")
    defer: removeDir(d)
    let (code, _) = runClue("bump", "nosuchpkg", dir = d)
    check code != 0

  test "semver first arg rejects a second argument":
    let d = bumpFixture("extra")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", "1.2.3", "extra", dir = d)
    check code != 0
    check stripAnsi(outp).contains("Unexpected second argument")

suite "cli bump — own package version":
  test "explicit semver sets the version field verbatim":
    let d = bumpFixture("selfexp")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", "9.9.9", dir = d)
    checkpoint outp
    check code == 0
    check readNimble(d).contains("version       = \"9.9.9\"")

  test "no arg defaults to a patch bump":
    let d = bumpFixture("selfpatch")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", dir = d)
    checkpoint outp
    check code == 0
    check readNimble(d).contains("version       = \"0.1.1\"")

  test "--level:major resets minor and patch":
    let d = bumpFixture("selfmajor")
    defer: removeDir(d)
    let (code, outp) = runClue("bump", "--level:major", dir = d)
    checkpoint outp
    check code == 0
    check readNimble(d).contains("version       = \"1.0.0\"")
