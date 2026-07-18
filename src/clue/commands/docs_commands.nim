import std/[os, osproc, tables, sequtils, algorithm]

import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../features/docbuilder/[configs, builder, overviewgen]

proc docsGenCommand*(v: Values) =
  let pkgName = v.get("pkgname").getStr
  buildDocs(pkgName)

proc docsOpenCommand*(v: Values) =
  let pkgName = v.get("pkgname").getStr
  withDocsDB do:
    let docsTable = getDocsTable()
    let existing = docsTable.where("name", newTextValue(pkgName))
    if existing.len == 0:
      displayError("No documentation found for '" & pkgName & "'")
      return
    var latest = existing[0]
    for (pk, row) in existing:
      if row["built_at"].strVal > latest[1]["built_at"].strVal:
        latest = (pk, row)
    let relPath = latest[1]["path"].strVal
    let docDir = clueDocsPath / relPath
    let candidates = ["index.html", latest[1]["name"].strVal & ".html", "theindex.html"]
    var fullPath = ""
    for c in candidates:
      let p = docDir / c
      if fileExists(p):
        fullPath = p
        break
    if fullPath.len == 0:
      displayError("Documentation not found in " & docDir)
      return
    discard execCmdEx("open \"" & fullPath & "\"")

proc docsRebuildCommand*(v: Values) =
  rebuildDocs()

proc docsListCommand*(v: Values) =
  withDocsDB do:
    let docsTable = getDocsTable()
    var latestByName: Table[string, RowData]
    for (pk, row) in docsTable.allRows():
      let name = row["name"].strVal
      if not latestByName.hasKey(name) or row["built_at"].strVal > latestByName[name]["built_at"].strVal:
        latestByName[name] = row
    if latestByName.len == 0:
      displayInfo("No documented packages")
      return
    var names = toSeq(latestByName.keys)
    names.sort()
    displayInfo("Documented packages:")
    for name in names:
      let row = latestByName[name]
      echo "  " & name & " v" & row["version"].strVal & "  [" & row["built_at"].strVal & "]"

proc docsOverviewCommand*(v: Values) =
  generateOverview()
