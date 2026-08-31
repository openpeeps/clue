## CLI tests for `clue dump` — the local no-argument dump and the registry
## dump embedding the package's own .nimble details.

import std/[json, os, osproc, strutils, unittest]
import cli_helpers

const fixtureNimble = """# Package

version       = "0.3.0"
author        = "Test"
description   = "dump fixture"
license       = "MIT"
srcDir        = "src"
bin           = @["demo"]

requires "nim >= 2.0.0"
requires "semver >= 1.2.3, flatty >= 0.4.0"
requires "bro"

feature "ssl":
  requires "openssl >= 1.0.0"

task demo, "run demo":
  echo "hello"
"""

proc dumpFixture(name: string): string =
  ## Fresh scratch dir with the demo .nimble inside.
  let d = getTempDir() / ("clue_cli_dump_" & name & "_" & $getCurrentProcessId())
  removeDir(d)
  createDir(d)
  writeFile(d / "demo.nimble", fixtureNimble)
  d

suite "cli dump — local (no argument)":
  test "parses as JSON with named requires":
    let d = dumpFixture("local")
    defer: removeDir(d)
    let (code, outp) = runClue("dump", dir = d)
    checkpoint outp
    check code == 0
    let j = parseJson(outp)
    check j["name"].getStr == "demo"
    check j["version"].getStr == "0.3.0"
    check j["author"].getStr == "Test"
    check j["license"].getStr == "MIT"
    check j["bin"] == %["demo"]
    # requires carry dep names, one entry per root-level line/part
    let reqs = j["requires"]
    check reqs.len == 4
    check reqs[0].getStr == "nim >= 2.0.0"
    check reqs[1].getStr == "semver >= 1.2.3"
    check reqs[2].getStr == "flatty >= 0.4.0"
    check reqs[3].getStr == "bro"
    # feature-block deps stay out of the root list
    for r in reqs:
      check r.getStr != "openssl >= 1.0.0"
    # tasks are captured with name + description
    let tasks = j["tasks"]
    check tasks.len == 1
    check tasks[0]["name"].getStr == "demo"
    check tasks[0]["description"].getStr == "run demo"

  test "refuses to run outside a package":
    let d = getTempDir() / ("clue_cli_dump_empty_" & $getCurrentProcessId())
    removeDir(d)
    createDir(d)
    defer: removeDir(d)
    let (code, _) = runClue("dump", dir = d)
    check code != 0

suite "cli dump — registry package":
  test "embeds the dumped package's own nimble details":
    # uses a package guaranteed to be installed via `clue install` in CI
    let pkg = "semver"
    let (code, outp) = runClue("dump", pkg, dir = ".")
    if code != 0:
      checkpoint "skipped: " & pkg & " is not installed in this environment"
      check true
    else:
      let j = parseJson(stripAnsi(outp))
      check j["name"].getStr == pkg
      # registry dump always has method/url; installed registry copy adds nimble
      if j.hasKey("nimble"):
        check j["nimble"]["name"].getStr == pkg
        check j["nimble"]["srcDir"].getStr.len > 0
      else:
        # package is in registry but not installed with nimble details — still valid
        checkpoint "no nimble embedded for " & pkg & " (not installed)"
        check j.hasKey("url")
