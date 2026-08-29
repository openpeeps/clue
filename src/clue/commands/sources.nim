# Clue - source registry management
#
# (c) 2026 George Lemon | MIT License

import std/[os, strutils, sequtils, options, terminal, tables]

import pkg/kapsis/[runtime, interactive/prompts]
import pkg/openparser/json

import ../pkgmanager/configs
import ../pkgmanager/versions

proc sourceAddCommand*(v: Values) =
  let name = v.get("name").getStr
  let url = v.get("url").getStr
  if not isValidSourceName(name):
    displayError("Invalid source name '" & name & "': use [a-z0-9_-]+", quitProcess = true)
    return
  if url.len == 0 or not (url.startsWith("http://") or url.startsWith("https://") or url.startsWith("file://")):
    displayError("Invalid URL: " & url, quitProcess = true)
    return
  var sources = loadSources()
  for s in sources:
    if s.name == name:
      displayError("Source '" & name & "' already exists. Remove it first.", quitProcess = true)
      return
    if s.url == url:
      displayError("URL already registered as source '" & s.name & "'", quitProcess = true)
      return
  sources.add(Source(name: name, url: url))
  saveSources(sources)
  displaySuccess("Added source " & name & " -> " & url)
  discard refreshSource(name)

proc sourceFetchCommand*(v: Values) =
  if v.has("name"):
    let name = v.get("name").getStr
    if not refreshSource(name):
      quit(1)
  else:
    if not refreshAllSources():
      quit(1)

proc sourceListCommand*(v: Values) =
  let sources = loadSources()
  if sources.len == 0:
    displayInfo("No sources configured")
    return
  for src in sources:
    let cacheFile = sourceCachePath(src.name)
    let cached = if fileExists(cacheFile): "cached" else: "not cached"
    display(cyan(src.name) & "  " & src.url)

proc sourceRemoveCommand*(v: Values) =
  let name = v.get("name").getStr
  if name == defaultSourceName:
    displayError("Cannot remove default source '" & defaultSourceName & "'", quitProcess = true)
    return
  var sources = loadSources()
  var idx = -1
  for i, s in sources:
    if s.name == name:
      idx = i
      break
  if idx < 0:
    displayError("Unknown source: " & name, quitProcess = true)
    return
  sources.delete(idx)
  saveSources(sources)
  # purge its rows
  withClueDB do:
    let tbl = clueDB.getTable("packages").get()
    var toDelete: seq[string]
    for (pk, row) in tbl.allRows():
      if row["source"].strVal == name:
        toDelete.add(pk)
    for pk in toDelete:
      discard clueDB.deleteRow("packages", pk)
    clueDB.checkpoint()
  let cacheFile = sourceCachePath(name)
  if fileExists(cacheFile):
    removeFile(cacheFile)
  displaySuccess("Removed source " & name)
