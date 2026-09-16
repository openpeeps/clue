# Clue deploy releases — unit tests for the GitHub release helpers:
# URL building, archive detection, shell quoting and archive extraction.
# No network is ever touched by these tests.

import std/[os, osproc, strutils, unittest]
import clue/deploy/releases

proc tmpBase(name: string): string =
  getTempDir() / "clue_deploy_releases" / $getCurrentProcessId() / name

suite "deploy releases — pure helpers":
  test "latestDownloadUrl follows the latest download redirect":
    check latestDownloadUrl("acme/myapp", "myapp_linux-x86_64.tar.gz") ==
      "https://github.com/acme/myapp/releases/latest/download/myapp_linux-x86_64.tar.gz"

  test "isArchiveAsset detects tar.gz, tgz and zip":
    check isArchiveAsset("myapp_linux-x86_64.tar.gz")
    check isArchiveAsset("myapp.tgz")
    check isArchiveAsset("myapp_windows-x86_64.zip")
    check not isArchiveAsset("myapp")
    check not isArchiveAsset("myapp.exe")

  test "shq single-quotes for sh":
    check shq("/srv/my app") == "'/srv/my app'"
    check shq("o'clock") == "'o'\\''clock'"

  test "findReleaseBinary walks recursively":
    let base = tmpBase("find")
    createDir(base / "pkg" / "nested")
    writeFile(base / "pkg" / "nested" / "myapp", "binary")
    defer: removeDir(base)
    check findReleaseBinary(base, "myapp") == base / "pkg" / "nested" / "myapp"
    check findReleaseBinary(base, "missing") == ""

suite "deploy releases — extractArchive":
  test "extracts tar.gz archives":
    let base = tmpBase("tgz")
    createDir(base / "pkg")
    writeFile(base / "pkg" / "myapp", "binary")
    let (_, tarCode) = execCmdEx("tar czf " & quoteShell(base / "pkg.tar.gz") &
      " -C " & quoteShell(base) & " pkg")
    if tarCode != 0:
      skip()
    createDir(base / "out")
    defer: removeDir(base)
    check extractArchive(base / "out", base / "pkg.tar.gz")
    check readFile(base / "out" / "pkg" / "myapp") == "binary"

  test "returns false for a missing archive":
    let base = tmpBase("missing")
    createDir(base)
    defer: removeDir(base)
    check not extractArchive(base, base / "nope.tar.gz")
