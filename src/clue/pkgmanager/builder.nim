# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Build binaries for installed packages into ~/.clue/bin.
##
## Used by `clue install --build`. Compiling a package executes its
## `{.compile.}` / `staticExec` code, so building is always opt-in — never
## done implicitly during an install.

import std/[os, osproc, strutils, sequtils, sets, tables, terminal]
import pkg/openparser/json

import pkg/kapsis/interactive/prompts

import ../cli/live

import ./configs
import ./versions
import ./nimbleparser

proc buildFlags(release, debug: bool, userNimFlags = ""): string =
  result = defaultColorsFlag(userNimFlags)
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
  let nimblePath = findNimbleFile(pkgDir, getClueCfg())
  if nimblePath.len == 0:
    return true
  let nimble = parseNimbleFile(nimblePath)
  if nimble.bin.len == 0:
    return true
  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"
  progress("Building " & pkgName & " binaries...")
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
      write(stdout, output)
      write(stdout, "\n")
      fail("Build failed for " & bin)
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

  # Use closure-scoped, develop-aware paths via resolveInstalledPath + pathForImports
  # (allInstalledPaths returns latest semver per name and ignores develop records
  # without semver, so it would use stale packages/datpkgr/0.1.0 instead of develop).
  let closure = collectInstalledDepNames(@[name]) & @[name]
  var seenClosure = initHashSet[string]()
  var dedupClosure: seq[string]
  for pkg in closure:
    if pkg notin seenClosure:
      seenClosure.incl(pkg)
      dedupClosure.add(pkg)

  var featureDefines = ""
  let featsMap = installedFeatures()
  for pkg, feats in featsMap:
    if pkg notin seenClosure: continue
    for f in feats:
      featureDefines.add(" -d:features." & pkg & "." & f)

  var pathFlags: seq[string]
  var seenPaths = initHashSet[string]()
  for pkg in dedupClosure:
    var p = ""
    # Prefer develop symlink if present (e.g. datpkgr -> ~/Development/toys/datpkgr)
    let devPath = getClueCfg().developPath() / pkg
    if symlinkExists(devPath) or dirExists(devPath):
      p = devPath
      try: p = expandSymlink(p) except: discard
    if p.len == 0:
      p =
        if pkg == name: resolveInstalledPath(pkg, preferRef)
        else: resolveInstalledPath(pkg, "")
    if p.len == 0: continue
    # If p is a develop symlink, resolve to real path and prefer src subdir if manifest says so
    var importPath = p
    # Use cfg.pathForImports logic: check manifest srcDir via findManifestInDir
    let mf = getClueCfg().findManifestInDir(p)
    if mf.len > 0:
      try:
        let content = readFile(mf)
        let m = getClueCfg().parseManifest(content, mf)
        if m.extra != nil and m.extra.hasKey("srcDir"):
          let sd = m.extra["srcDir"].getStr
          if sd.len > 0:
            let cand = p / sd
            if dirExists(cand):
              importPath = cand
      except: discard
    # Also handle legacy symlink expansion: if p is develop symlink not yet expanded, pathForImports already did
    let flag = "--path:" & importPath
    if flag notin seenPaths:
      seenPaths.incl(flag)
      pathFlags.add(flag)

  let flags = " " & pathFlags.join(" ") & featureDefines & buildFlags(release, debug, nimFlags.join(" ")) & " " & nimFlags.join(" ")

  var order: seq[string]
  var seenOrder = initHashSet[string]()
  for pkg in dedupClosure:
    if pkg == name: continue
    if pkg notin seenOrder:
      seenOrder.incl(pkg)
      order.add(pkg)
  if name notin seenOrder:
    order.add(name)

  let useLive = false # not verbose and isatty(stdout) and not debugEnabled
  var live: Live
  proc progress(msg: string) =
    if useLive: live.setMain(msg)
    else: displayInfo(msg)
  proc fail(msg: string) =
    if useLive: live.error(msg)
    else: displayError(msg, quitProcess = true)
  if useLive:
    live = newLive("Building " & name & " binaries...")
    live.start()

  var seenBins = initHashSet[string]()
  for pkg in order:
    if not buildPackageBinaries(pkg, flags, seenBins, clueBinPath,
            progress, fail, preferRef = preferRef, backend = backend):
      return false # a build failed, stopping now
  if useLive:
    live.success("Built binaries to " & clueBinPath)
  else:
    displaySuccess("Built binaries to " & clueBinPath)
  true
