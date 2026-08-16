# Clue configs — unit tests for the package-registry path safety layer:
# isInsidePkgs boundaries and the safeRemove* guards (refusal paths only,
# so tests never touch the real ~/.clue registry).

import std/[os, unittest]
import clue/pkgmanager/configs

suite "configs — isInsidePkgs":
  test "the registry root itself is inside":
    check isInsidePkgs(cluePkgsPath)

  test "a child of the registry is inside":
    check isInsidePkgs(cluePkgsPath / "spry" / "1.2.0")

  test "a sibling with a name prefix is outside":
    check not isInsidePkgs(cluePkgsPath & "X")
    check not isInsidePkgs(cluePkgsPath & "_cache")

  test "the parent directory is outside":
    check not isInsidePkgs(cluePkgsPath.parentDir())

  test "unrelated paths are outside":
    check not isInsidePkgs(getTempDir())
    check not isInsidePkgs(getHomeDir())

suite "configs — safeRemoveDir refuses outside the registry":
  test "leaves an outside temp dir untouched":
    let dir = getTempDir() / "clue_configs_outside" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    safeRemoveDir(dir)
    check dirExists(dir)

  test "leaves a symlinked outside target untouched":
    let target = getTempDir() / "clue_configs_target" / $getCurrentProcessId()
    let link = getTempDir() / "clue_configs_link" / $getCurrentProcessId()
    createDir(target)
    createDir(link.parentDir())
    defer:
      removeDir(target)
      # Windows can only remove a directory symlink via RemoveDirectory, not
      # DeleteFile, so try both and ignore cleanup failures.
      if symlinkExists(link):
        try:
          removeFile(link)
        except OSError:
          try: removeDir(link)
          except OSError: discard
    createSymlink(target, link)
    safeRemoveDir(link)
    check symlinkExists(link)

suite "configs — safeRemoveSymlink refuses outside develop":
  test "leaves a symlink outside ~/.clue/develop untouched":
    let target = getTempDir() / "clue_configs_symtarget" / $getCurrentProcessId()
    let link = getTempDir() / "clue_configs_symlink" / $getCurrentProcessId()
    createDir(target)
    createDir(link.parentDir())
    defer:
      removeDir(target)
      if symlinkExists(link):
        try:
          removeFile(link)
        except OSError:
          try: removeDir(link)
          except OSError: discard
    createSymlink(target, link)
    safeRemoveSymlink(link)
    check symlinkExists(link)

  test "no crash on a missing path":
    safeRemoveSymlink(getTempDir() / "clue_configs_nonexistent")
