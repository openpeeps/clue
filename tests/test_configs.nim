# Clue configs — unit tests for the package-registry path safety layer:
# isInsidePkgs boundaries and the safeRemove* guards (refusal paths only,
# so tests never touch the real ~/.clue registry).

import std/[os, unittest]
when defined(windows):
  import std/osproc
import clue/pkgmanager/configs

when defined(windows):
  proc makeDirLink(target, link: string) =
    ## Fixture dir link without privilege: real symlink when allowed,
    ## otherwise an NTFS junction (`mklink /J` needs none). Both report
    ## `symlinkExists` (any reparse point), which is all these tests need.
    try:
      createSymlink(target, link)
      return
    except OSError:
      discard
    let (_, code) = execCmdEx("cmd /c mklink /J " & quoteShell(link) &
      " " & quoteShell(target))
    doAssert code == 0, "could not create fixture link: " & link

  proc removeDirLink(link: string) =
    ## Unlink a fixture dir link (symlink or junction) without touching
    ## its target — `removeDir` would recurse through junctions.
    if symlinkExists(link) and dirExists(link):
      let (_, code) = execCmdEx("cmd /c rmdir " & quoteShell(link))
      if code == 0:
        return
    try:
      removeFile(link)
    except OSError:
      try: removeDir(link)
      except OSError: discard

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
      when defined(windows):
        removeDirLink(link)
      else:
        # Windows can only remove a directory symlink via RemoveDirectory, not
        # DeleteFile, so try both and ignore cleanup failures.
        if symlinkExists(link):
          try:
            removeFile(link)
          except OSError:
            try: removeDir(link)
            except OSError: discard
      removeDir(target)
    when defined(windows):
      makeDirLink(target, link)
    else:
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
      when defined(windows):
        removeDirLink(link)
      else:
        if symlinkExists(link):
          try:
            removeFile(link)
          except OSError:
            try: removeDir(link)
            except OSError: discard
      removeDir(target)
    when defined(windows):
      makeDirLink(target, link)
    else:
      createSymlink(target, link)
    safeRemoveSymlink(link)
    check symlinkExists(link)

  test "no crash on a missing path":
    safeRemoveSymlink(getTempDir() / "clue_configs_nonexistent")

when not defined(windows):
  import std/osproc

  proc withShimOnPath(shimBody: string, body: proc(shim: string)) =
    ## Put a fake `nimony` executable first on PATH for `body`, then restore.
    let shimDir = getTempDir() / ("clue_nimony_shim_" & $getCurrentProcessId())
    removeDir(shimDir)
    createDir(shimDir)
    let shim = shimDir / "nimony"
    writeFile(shim, "#!/bin/sh\n" & shimBody & "\n")
    inclFilePermissions(shim, {fpUserExec, fpGroupExec, fpOthersExec})
    let prevPath = getEnv("PATH")
    putEnv("PATH", shimDir & PathSep & prevPath)
    try:
      body(shim)
    finally:
      putEnv("PATH", prevPath)
      removeDir(shimDir)

  suite "configs — useNimony resolution":
    test "useNimony resolves nimony from PATH, ignoring the nim toolchain":
      withShimOnPath("exit 0"):
        proc(shim: string) =
          check resolveNimBin(true) == shim

    test "useNimony falls back to the literal when none is installed":
      let prevPath = getEnv("PATH")
      let emptyDir = getTempDir() / ("clue_nimony_empty_" & $getCurrentProcessId())
      removeDir(emptyDir)
      createDir(emptyDir)
      putEnv("PATH", emptyDir)
      try:
        check resolveNimBin(true) == "nimony"
      finally:
        putEnv("PATH", prevPath)
        removeDir(emptyDir)

    test "detectNimVersion parses nimony --version output":
      withShimOnPath("echo '0.9.1 [macosx; amd64]'"):
        proc(shim: string) =
          check detectNimVersion(shim) == "0.9.1"

    test "detectNimVersion parses the long nimony version line":
      withShimOnPath("echo 'Nimony Compiler. Version 0.6.3'"):
        proc(shim: string) =
          check detectNimVersion(shim) == "0.6.3"

    test "detectNimVersion falls back for a missing compiler":
      check detectNimVersion(getTempDir() / "clue_nimony_nope_nimxyz") == "2.2.10"

    test "nim --version parsing is unchanged":
      let nim = findExe("nim")
      if nim.len > 0:
        let v = detectNimVersion(nim)
        check v.len > 0 and v[0] in {'0'..'9'} and '.' in v
