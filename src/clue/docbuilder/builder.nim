import std/[os, osproc, strutils, json, times, tables]

import pkg/semver
import pkg/kapsis/interactive/prompts

import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/nimbleparser

import ./configs
import ./overviewgen

proc splitPkgRef*(s: string): tuple[name, version: string] =
  ## Split `name@version` (version optional) into its parts.
  let at = s.rfind('@')
  if at > 0:
    result.name = s[0 ..< at]
    result.version = s[at + 1 .. ^1]
  else:
    result.name = s

proc resolveMainFile(pkgDir, name, srcDir: string): string =
  ## Locate the package's main module: the srcDir layout (develop-mode source
  ## trees), the flattened registry layout (srcDir contents at the root), or a
  ## `pkg/`-style subdir.
  for c in [pkgDir / srcDir / name & ".nim",
            pkgDir / name & ".nim",
            pkgDir / name / name & ".nim"]:
    if fileExists(c):
      return c
  ""

proc buildDocs*(pkgRef: string) =
  ## Build documentation for a clue-installed package.
  ## `pkgRef` is `name` or `name@version` (version omitted → latest installed).
  initDocsDB()
  let (pkgName, wantVersion) = splitPkgRef(pkgRef)
  let records = installedRecords(pkgName)
  if records.len == 0:
    displayError("Package not installed: " & pkgName &
      ". Run `clue install " & pkgName & "` first.", quitProcess = true)
    return

  var version = wantVersion
  var pkgDir = ""
  if version.len > 0:
    for r in records:
      if r.version == version:
        pkgDir = r.path
        break
    if pkgDir.len == 0:
      displayError("Version not installed: " & pkgName & "@" & version, quitProcess = true)
      return
  else:
    # latest semver installed version
    var best: tuple[v: Version, path: string]
    for r in records:
      try:
        let v = parseVersion(r.version)
        if best.path.len == 0 or v > best.v:
          best = (v, r.path)
          version = r.version
      except CatchableError:
        discard
    if best.path.len == 0:
      displayError("No installable version found for " & pkgName, quitProcess = true)
      return
    pkgDir = best.path

  let nimblePath = findNimbleFile(pkgDir, getClueCfg())
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir, quitProcess = true)
    return
  let nimble = parseNimbleFile(nimblePath)
  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"

  let mainFile = resolveMainFile(pkgDir, pkgName, srcDir)
  if mainFile.len == 0:
    displayError("Main source file not found in " & pkgDir, quitProcess = true)
    return

  let srcPath = if dirExists(pkgDir / srcDir): pkgDir / srcDir else: pkgDir
  let pkgDirDocs = clueDocsPath / pkgName
  let outputDir = pkgDirDocs / version
  discard existsOrCreateDir(pkgDirDocs)
  discard existsOrCreateDir(outputDir)

  let cmd = "nim doc --index:on --project --path:" & srcPath &
    " --out:" & outputDir & " " & mainFile
  displayInfo("Building docs for " & pkgName & " v" & version)
  let result = execCmdEx(cmd)
  if result.exitCode != 0:
    displayError("nim doc failed for " & pkgName & " v" & version & ":\n" & result.output, quitProcess = true)
    return

  withDocsDB do:
    let docsTable = getDocsTable()
    let existing = docsTable.where("name", newTextValue(pkgName))
    for (pk, row) in existing:
      if row.hasKey("version") and row["version"] == newTextValue(version):
        discard clueDocsDB.deleteRow("docs", pk)
        break

    let relPath = pkgName / version
    let nowStr = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    discard clueDocsDB.insertRow("docs", row({
      "name": newTextValue(pkgName),
      "version": newTextValue(version),
      "description": newTextValue(nimble.description),
      "built_at": newTextValue(nowStr),
      "path": newTextValue(relPath),
      "mainfile": newTextValue(mainFile),
    }))
    clueDocsDB.checkpoint()

  displaySuccess("Docs built for " & pkgName & " v" & version)
  generateOverview()

proc rebuildDocs*() =
  ## Rebuild docs for all packages currently in the docs database.
  withDocsDB do:
    let docsTable = getDocsTable()

    var names: seq[string] = @[]
    for (pk, row) in docsTable.allRows():
      if row.hasKey("name"):
        let n = row["name"].strVal
        if not names.contains(n):
          names.add(n)

    if names.len == 0:
      displayInfo("No documented packages to rebuild")
      return

    displayInfo("Rebuilding docs for " & $names.len & " packages")
    for n in names:
      buildDocs(n)
