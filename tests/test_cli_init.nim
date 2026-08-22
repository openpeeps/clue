## CLI tests for `clue init` — non-interactive `-Y` mode and its guards.
## The initialized package lives at ./tests/tmp_package.

import std/[os, osproc, strutils, unittest]
import cli_helpers

const pkgDir = "tmp_package"

proc scratch(name: string): string =
  ## Fresh empty dir under the system temp area for guard tests.
  let d = getTempDir() / ("clue_cli_init_" & name & "_" & $getCurrentProcessId())
  removeDir(d)
  createDir(d)
  d

suite "cli init — -Y initializes a library package":
  test "bare `init -Y` expands into the current empty directory":
    removeDir(pkgDir)
    try:
      createDir(pkgDir)
      let (code, outp) = runClue("init", "-Y", dir = pkgDir)
      checkpoint outp
      check code == 0
      check fileExists(pkgDir / "tmp_package.nimble")
      check fileExists(pkgDir / "src" / "tmp_package.nim")
      check fileExists(pkgDir / "src" / "tmp_package" / "submodule.nim")
      check fileExists(pkgDir / "tests" / "config.nims")
      check fileExists(pkgDir / "tests" / "test1.nim")

      let nimble = readFile(pkgDir / "tmp_package.nimble")
      check nimble.contains("version       = \"0.1.0\"")
      check nimble.contains("license       = \"MIT\"")
      check nimble.contains("srcDir        = \"src\"")
      check nimble.contains("requires \"nim >=")
      check not nimble.contains("bin           = @[")

      let mainModule = readFile(pkgDir / "src" / "tmp_package.nim")
      check mainModule.contains("proc add*")
      check readFile(pkgDir / "src" / "tmp_package" / "submodule.nim")
        .contains("Submodule*")
      check readFile(pkgDir / "tests" / "test1.nim").contains("check add(5, 5) == 10")
    finally:
      removeDir(pkgDir)

  test "`init <name> -Y` creates a <name>/ subdirectory":
    removeDir(pkgDir)
    try:
      # make CWD non-empty so the name-mode subdir branch is exercised
      writeFile("seed.txt", "x")
      defer: removeFile("seed.txt")
      let (code, outp) = runClue("init", pkgDir, "-Y", dir = ".")
      checkpoint outp
      check code == 0
      check fileExists(pkgDir / "tmp_package.nimble")
      check fileExists(pkgDir / "src" / "tmp_package.nim")
    finally:
      removeDir(pkgDir)

suite "cli init — guards":
  test "non-TTY without -Y is refused":
    let d = scratch("notty")
    try:
      let (code, _) = runClue("init", "somepkg", dir = d)
      check code != 0
      check not fileExists(d / "somepkg.nimble")
    finally:
      removeDir(d)

  test "-Y with an invalid directory basename is refused":
    let d = getTempDir() / ("clue_cli_init_bad_" & $getCurrentProcessId())
    removeDir(d)
    createDir(d / "bad-name")
    try:
      let (code, _) = runClue("init", "-Y",
        dir = d / "bad-name")
      check code != 0
      check not fileExists(d / "bad-name" / "bad-name.nimble")
    finally:
      removeDir(d)

  test "plain `init -Y` in a non-empty directory is refused":
    let d = scratch("occupied")
    try:
      writeFile(d / "keep.txt", "x")
      let (code, outp) = runClue("init", "-Y", dir = d)
      check code != 0
      check stripAnsi(outp).contains("not empty")
    finally:
      removeDir(d)

  test "`init <name>` into an occupied existing directory is refused":
    let d = scratch("subdir")
    try:
      createDir(d / "occupied")
      writeFile(d / "occupied" / "keep.txt", "x")
      let (code, outp) = runClue("init", "occupied", "-Y", dir = d)
      check code != 0
      check stripAnsi(outp).contains("already exists and is not empty")
    finally:
      removeDir(d)
