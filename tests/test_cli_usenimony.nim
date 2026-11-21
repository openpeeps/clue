## CLI tests for `--useNimony` — the compiler binary switch for
## `build`, `test`, `check` and `install --build`.
##
## A fake `nim`/`nimony` pair on PATH records every invocation to a log
## file and exits 0, so no real toolchain is needed: the tests assert
## which binary clue shells out to.

import std/[os, osproc, strutils, sequtils, unittest]
import cli_helpers

when not defined(windows):
  const fixtureNimble = """# Package

version       = "0.1.0"
author        = "Test"
description   = "usenimony fixture"
license       = "MIT"
srcDir        = "src"
bin           = @["demo"]

requires "nim >= 2.0.0"
"""

  proc shimFixture(name: string): tuple[dir, log: string] =
    ## Scratch project plus `nim`/`nimony` logging shims.
    let d = getTempDir() / ("clue_cli_nimony_" & name & "_" & $getCurrentProcessId())
    removeDir(d)
    createDir(d)
    let shimDir = d / "shims"
    createDir(shimDir)
    let log = d / "calls.log"
    writeFile(log, "")
    for tool in ["nim", "nimony"]:
      writeFile(shimDir / tool,
        "#!/bin/sh\necho \"" & tool & " $*\" >> " & log.quoteShell & "\nexit 0\n")
      inclFilePermissions(shimDir / tool, {fpUserExec, fpGroupExec, fpOthersExec})
    writeFile(d / "demo.nimble", fixtureNimble)
    createDir(d / "src")
    writeFile(d / "src" / "demo.nim", "echo \"hi\"\n")
    createDir(d / "tests")
    writeFile(d / "tests" / "t_demo.nim", "doAssert 1 + 1 == 2\n")
    (d, log)

  proc withShimPath(dir: string, body: proc()) =
    let prevPath = getEnv("PATH")
    putEnv("PATH", dir / "shims" & PathSep & prevPath)
    try:
      body()
    finally:
      putEnv("PATH", prevPath)

  proc calls(log: string): seq[string] =
    readFile(log).splitLines().filterIt(it.len > 0)

  suite "cli usenimony — compiler selection":
    test "build shells to nimony with the flag":
      let (d, log) = shimFixture("build")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("build", "--useNimony", dir = d)
          checkpoint outp
          check code == 0
          let cs = calls(log)
          check cs.anyIt(it.startsWith("nimony c "))
          check not cs.anyIt(it.startsWith("nim c "))

    test "build shells to nim without the flag":
      let (d, log) = shimFixture("buildnim")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("build", dir = d)
          checkpoint outp
          check code == 0
          let cs = calls(log)
          check cs.anyIt(it.startsWith("nim c "))
          check not cs.anyIt(it.startsWith("nimony "))

    test "build warns on a non-c backend with the flag":
      let (d, log) = shimFixture("backend")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("build", "--useNimony", "-b:cpp", dir = d)
          checkpoint outp
          check code == 0
          check stripAnsi(outp).contains("only 'c' maps cleanly")
          let cs = calls(log)
          check cs.anyIt(it.startsWith("nimony cpp "))

    test "build without the flag does not warn on a non-c backend":
      let (d, _) = shimFixture("backendnim")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("build", "-b:cpp", dir = d)
          checkpoint outp
          check code == 0
          check not stripAnsi(outp).contains("only 'c' maps cleanly")

    test "check shells to nimony check with the flag":
      let (d, log) = shimFixture("check")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("check", "--useNimony", dir = d)
          checkpoint outp
          check code == 0
          let cs = calls(log)
          check cs.anyIt(it.startsWith("nimony check "))
          check not cs.anyIt(it.startsWith("nim check "))

    test "test compiles modules with nimony and -r with the flag":
      let (d, log) = shimFixture("test")
      defer: removeDir(d)
      withShimPath(d):
        proc() =
          let (code, outp) = runClue("test", "--useNimony", dir = d)
          checkpoint outp
          check code == 0
          check stripAnsi(outp).contains("All 1 test(s) passed!")
          let cs = calls(log)
          check cs.anyIt(it.startsWith("nimony c ") and " -r " in it)
          check not cs.anyIt(it.startsWith("nim c "))
