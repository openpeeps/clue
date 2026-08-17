import std/[os, net, tables]

import pkg/semver
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../docbuilder/[configs, builder, httpserver]

proc docsGenCommand*(v: Values) =
  let pkgName = v.get("pkg").getStr
  buildDocs(pkgName)

proc docsOpenCommand*(v: Values) =
  let pkgName = v.get("pkg").getStr
  let port =
    if v.has("--port"): v.get("--port").getPort
    else: Port(11000)
  let (name, wantVersion) = splitPkgRef(pkgName)

  var docDir = ""
  if wantVersion.len > 0:
    docDir = clueDocsPath / name / wantVersion
  else:
    # latest built docs (by build time), falling back to the max version dir
    var bestPath = ""
    var bestBuilt = ""
    withDocsDB do:
      let docsTable = getDocsTable()
      for (pk, row) in docsTable.where("name", newTextValue(name)):
        if row["built_at"].strVal > bestBuilt:
          bestBuilt = row["built_at"].strVal
          bestPath = row["path"].strVal
    if bestPath.len > 0:
      docDir = clueDocsPath / bestPath
    else:
      let base = clueDocsPath / name
      if dirExists(base):
        var best: tuple[v: Version, path: string]
        for entry in walkDir(base):
          if entry.kind != pcDir: continue
          let verName = entry.path.extractFilename
          try:
            let ver = parseVersion(verName)
            if best.path.len == 0 or ver > best.v:
              best = (ver, entry.path)
          except CatchableError:
            discard
        docDir = best.path

  if docDir.len == 0 or not dirExists(docDir):
    displayError("No documentation found for '" & name & "'. Run `clue docs.gen " & name & "` first.", quitProcess = true)
    return
  serveDocs(docDir, name, port)
