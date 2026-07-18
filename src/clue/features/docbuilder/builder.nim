import std/[os, osproc, json, times, tables]

import pkg/kapsis/interactive/prompts

import ./configs
import ./overviewgen

proc buildDocs*(pkgName: string) =
  ## Build documentation for a Nim package by name.
  ## Uses `nimble dump` to locate the package, then runs `nim doc`.
  initDocsDB()
  let nimbleOutput = execCmdEx("nimble dump " & pkgName & " --json")
  if nimbleOutput.exitCode != 0:
    displayError("Package not found via nimble: " & pkgName)
    return

  let info = parseJson(nimbleOutput.output)
  let name = info["name"].getStr
  let version = info["version"].getStr
  let description = info["desc"].getStr
  let nimblePath = info["nimblePath"].getStr
  let srcDir = info["srcDir"].getStr

  let pkgRoot = nimblePath.parentDir()

  var mainFile: string
  if info.hasKey("entryPoints") and info["entryPoints"].len > 0:
    mainFile = pkgRoot / info["entryPoints"][0].getStr
  else:
    mainFile = pkgRoot / srcDir / name & ".nim"

  if not fileExists(mainFile):
    let altMain = pkgRoot / name & ".nim"
    if fileExists(altMain):
      mainFile = altMain
    else:
      displayError("Main source file not found: " & mainFile)
      return

  let srcPath = if dirExists(pkgRoot / srcDir): pkgRoot / srcDir else: pkgRoot
  let pkgDir = clueDocsPath / name
  let outputDir = pkgDir / version
  discard existsOrCreateDir(pkgDir)
  discard existsOrCreateDir(outputDir)

  let cmd = "nim doc --index:on --project --path:" & srcPath & " --out:" & outputDir & " " & mainFile
  displayInfo("Building docs for " & name & " v" & version)
  let result = execCmdEx(cmd)
  if result.exitCode != 0:
    displayError("nim doc failed for " & name & " v" & version & ":\n" & result.output)
    return

  withDocsDB do:
    let docsTable = getDocsTable()
    let existing = docsTable.where("name", newTextValue(name))
    for (pk, row) in existing:
      if row.hasKey("version") and row["version"] == newTextValue(version):
        discard clueDocsDB.deleteRow("docs", pk)
        break

    let relPath = name / version
    let nowStr = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    discard clueDocsDB.insertRow("docs", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "description": newTextValue(description),
      "built_at": newTextValue(nowStr),
      "path": newTextValue(relPath),
      "mainfile": newTextValue(mainFile),
    }))
    clueDocsDB.checkpoint()

  displaySuccess("Docs built for " & name & " v" & version)
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
