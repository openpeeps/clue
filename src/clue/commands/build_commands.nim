# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue
import std/[os, osproc, strformat, strutils, algorithm]
import pkg/semver
import pkg/kapsis/[runtime, interactive/prompts]
import ../features/pkgmanager/nimbleparser
import ../features/pkgmanager/configs

proc resolveDepPath(depName: string): string =
  let clueInstall = cluePkgsPath / depName
  if dirExists(clueInstall):
    var versions: seq[Version]
    for entry in walkDir(clueInstall):
      if entry.kind == pcDir:
        try:
          versions.add(parseVersion(entry.path.extractFilename))
        except:
          discard
    if versions.len > 0:
      versions.sort(cmp)
      return clueInstall / $versions[^1]
  let nimblePkgDir = getHomeDir() / ".nimble" / "pkgs2"
  if dirExists(nimblePkgDir):
    for entry in walkDir(nimblePkgDir):
      if entry.kind == pcDir and entry.path.extractFilename.startsWith(depName):
        return entry.path
  ""

proc buildCommand*(v: Values) =
  let isRelease = v.has("--release")
  let isDebug = v.has("--debug")

  let pkgDir = getCurrentDir()
  let nimblePath = pkgDir / "clue.nimble"

  if not fileExists(nimblePath):
    displayError("No clue.nimble found in " & pkgDir)
    return

  let nimble = parseNimbleFile(nimblePath)

  if nimble.bin.len == 0:
    displayInfo("No binaries defined in " & nimblePath)
    return

  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"

  let binDir =
    if nimble.binDir.len > 0: nimble.binDir
    else: "bin"

  var pathFlags: seq[string]
  for dep in nimble.requires:
    if dep.isNim: continue
    let depPath = resolveDepPath(dep.name)
    if depPath.len > 0:
      pathFlags.add("--path:" & depPath)
      display("  dep " & dep.name & " → " & depPath)
    else:
      displayWarning("Dependency not found: " & dep.name)

  discard existsOrCreateDir(pkgDir / binDir)

  for bin in nimble.bin:
    let srcFile = pkgDir / srcDir / bin.addFileExt("nim")
    let outFile = pkgDir / binDir / bin
    var flags = " " & pathFlags.join(" ")
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")

    let cmd = &"nim c{flags} --out:{outFile} {srcFile}"
    display("  " & cyan(cmd))
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode == 0:
      displaySuccess("Built " & bin & " → " & outFile)
    else:
      displayError("Build failed for " & bin & ":\n" & output)
