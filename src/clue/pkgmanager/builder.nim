# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Build binaries for installed packages into ~/.clue/bin.
##
## Used by `clue install --build`. Compiling a package executes its
## `{.compile.}` / `staticExec` code, so building is always opt-in — never
## done implicitly during an install.

import std/[os, osproc, strutils, sequtils, sets, tables, terminal]

import pkg/kapsis/interactive/prompts

import ./configs

import ../cli/live

import ./configs
import ./versions
import ./nimbleparser

proc buildFlags(release, debug: bool): string =
  result = " --colors:on"
  if release:
    result.add(" -d:release --opt:size")
  elif debug:
    result.add(" --debugger:native")

proc buildPackageBinaries(pkgName: string, flags: string,
    seenBins: var HashSet[string], outDir: string,
    progress: proc (msg: string), fail: proc (msg: string),
    preferRef = "", backend = "c"): bool =
  let pkgDir = resolveInstalledPath(pkgName, preferRef)
  if pkgDir.len == 0:
    fail("No installed package found for " & pkgName)
    return false
  let nimblePath = findNimbleFile(pkgDir)
  if nimblePath.len == 0:
    return true
  let nimble = parseNimbleFile(nimblePath)
  if nimble.bin.len == 0:
    return true
  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"
  progress("building " & pkgName & " binaries...")
  for bin in nimble.bin:
    # The declared `srcDir` may not exist in a raw repo copy (some packages
    # keep the binary module at the root despite declaring srcDir = "src") —
    # fall back to the package root, matching nimble's tolerance.
    let srcFile = block:
      var cand = pkgDir / srcDir / bin.addFileExt("nim")
      if fileExists(cand):
        cand
      else:
        let root = pkgDir / bin.addFileExt("nim")
        if fileExists(root): root else: cand
    let outFile = outDir / bin
    if bin in seenBins:
      displayWarning("binary name collision, overwriting: " & bin)
    seenBins.incl(bin)
    let cmd = resolveNimBin() & " " & backend & flags & " --out:" & outFile & " " & srcFile
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      fail("Build failed for " & bin)
      write(stdout, output)
      if not output.endsWith("\n"):
        write(stdout, "\n")
      return false
  true

proc buildInstalled*(name: string, release = true, debug = false,
    verbose = false, preferRef = "", nimFlags: seq[string] = @[],
    backend = "c"): bool =
  ## Build the binaries of `name` and every dependency in its closure that
  ## declares `bin` entries, into ~/.clue/bin. Deps are built before the root
  ## so a cascade of tool binaries is installed in dependency order.
  let rootDir = resolveInstalledPath(name, preferRef)
  if rootDir.len == 0:
    displayError("Not installed: " & name & ". Run `clue install " & name & "` first.", quitProcess = true)
    return false
  discard existsOrCreateDir(clueBinPath)

  let pathFlags = allInstalledPaths().mapIt("--path:" & it)
  var featureDefines = ""
  let featsMap = installedFeatures()
  for pkg, feats in featsMap:
    for f in feats:
      featureDefines.add(" -d:features." & pkg & "." & f)

  let flags = " " & pathFlags.join(" ") & featureDefines & buildFlags(release, debug) & " " & nimFlags.join(" ")

  var order = collectInstalledDepNames(@[name]).filterIt(it != name)
  order.add(name)  # deps first, root last

  let useLive = not verbose and isatty(stdout) and not debugEnabled
  var live: Live
  proc progress(msg: string) =
    if useLive: live.setMain(msg)
    elif verbose: displayInfo(msg)
  proc fail(msg: string) =
    if useLive: live.error(msg)
    else: displayError(msg, quitProcess = true)
  if useLive:
    live = newLive("building " & name & " binaries...")
    live.start()

  var seenBins = initHashSet[string]()
  for pkg in order:
    if not buildPackageBinaries(pkg, flags, seenBins, clueBinPath, progress, fail,
        preferRef = preferRef, backend = backend):
      return false

  if useLive:
    live.success("Built binaries to " & clueBinPath)
  elif verbose:
    displaySuccess("Built binaries to " & clueBinPath)
  true
