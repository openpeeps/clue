import std/[os, strutils, sequtils, re]

import pkg/semver
import pkg/boogie/stores/rdbms
import pkg/openparser/json

import pkg/kapsis/interactive/prompts

export rdbms

const
  nimboxPath* = getHomeDir() / ".nimbox"
  nimboxDBPath* = nimboxPath / "nimbox.db"
  nimboxPkgsPath* = nimboxPath / "packages"
  nimboxPkgsCachePath* = nimboxPkgsPath / "packages" / "_cache"
  nimbleLocalPackages* = getHomeDir() / ".nimble" / "packages_official.json"

type
  Package* = object
    name*: string
      ## The name of the package
    url*: string
      ## The URL where the package can be found, such as a
      ## GitHub repository or a package registry.
    `method`*: string
      ## The method to use for installation, such as "git", "http",
      ## "nimble", etc.
    tags*: seq[string]
      ## Additional metadata about the package, such as "web", "cli",
      ## "database", etc.
    description*: string
      ## A brief description of the package, its features, and use cases.
    license*: string
      ## The license under which the package is distributed, such as "MIT",
      ## "GPL", "Apache", etc.
    web*: string
      ## The URL of the package's website or documentation, if available.

var nimboxDB*: Store

proc initNimbox*() =
  ## Initializes the Nimbox environment by creating necessary directories and
  ## setting up the database if it doesn't already exist.
  discard existsOrCreateDir(nimboxPath)
  discard existsOrCreateDir(nimboxPkgsPath)

  var hasDatabase = fileExists(nimboxDBPath)
  nimboxDB = newStore(nimboxDBPath, StorageMode.smDisk,
                      enableWal = true, walFlushEveryOps = 100'u32)
  if not hasDatabase:
    displayInfo("Initializing Nimbox database...")
    nimboxDB.createTable(newTable(
      name = "packages",
      primaryKey = "id",
      columns = [
        newColumn("id", dtInt, false),
        newColumn("name", dtText, false),
        newColumn("url", dtText, false),
        newColumn("method", dtText, false),
        newColumn("tags", dtJson, false), # Storing tags as JSON array
        newColumn("description", dtText, false),
        newColumn("license", dtText, false),
        newColumn("web", dtText, false)
      ]
    ))

    # Load initial packages from nimbleLocalPackages JSON file
    let nimblePackages = fromJsonFile(nimbleLocalPackages)
    
    # Iterate over the packages and insert them into the database
    for localPkg in nimblePackages:
      if localPkg.hasKey("alias") or not localPkg.hasKey("web"):
        continue # TODO - handle aliases properly instead of skipping them
      let mthd = if localPkg.hasKey"method": localPkg["method"].getStr else: ""
      nimboxDB.insertRow("packages", row({
        "name": newTextValue(localPkg["name"].getStr),
        "url": newTextValue(localPkg["url"].getStr),
        "method": newTextValue(mthd),
        "tags": newJsonValue(localPkg["tags"]),
        "description": newTextValue(localPkg["description"].getStr),
        "license": newTextValue(localPkg["license"].getStr),
        "web": newTextValue(localPkg["web"].getStr)
      }))

    # flush the WAL to disk to ensure data integrity
    nimboxDB.checkpoint()

template withNimboxDB*(stmt) =
  ## A template that provides a convenient way to access the
  ## Nimbox database within a block of code.
  initNimbox()
  stmt

const nimbleMetaKeys = ["version", "author", "description", "license", "srcDir", "bin", "binDir"]

proc parseNimbleFile*(path: string): JsonNode =
  ## Parses a nimble file and returns its contents as a JsonNode.
  let lines = readFile(path).splitLines()
  var result = newJObject()
  var requires = newJArray()
  for line in lines:
    let l = line.strip()
    if l.len == 0 or l.startsWith('#'): continue
    if l.startsWith("requires "):
      let reqStr = l.split(" ", maxsplit=1)[1].strip(chars={'"', ' '})
      var dep = newJObject()

      # name#branch
      if reqStr.contains("#"):
        let parts = reqStr.split("#", maxsplit=1)
        dep["name"] = %parts[0].strip()
        dep["branch"] = %parts[1].strip()
      else:
        # name [op version] [op version] ...
        let toks = reqStr.splitWhitespace()
        if toks.len > 0:
          dep["name"] = %toks[0]
          var constraints = newJArray()
          var i = 1
          while i + 1 < toks.len:
            let op = toks[i]
            let ver = toks[i + 1].strip(chars={','})
            if op in ["<", "<=", ">", ">=", "==", "=", "!=", "^", "~>"]: # semver operators to support
              constraints.add(%*{
                "operator": op,
                "version": ver
              })
              i += 2
            else:
              inc i
          if constraints.len > 0:
            dep["constraints"] = constraints
      requires.add(dep)
    elif l.contains('='):
      let parts = l.split('=', maxsplit=1)
      if parts.len == 2:
        let k = parts[0].strip()
        if k notin nimbleMetaKeys:
          continue
        var v = parts[1].strip()
        if v.startsWith("@["):
          # Parse Nim array syntax: @[...]
          v = v.strip(chars={'@', '[', ']'})
          let arr = v.split(',').mapIt(it.strip(chars={'"', ' '}))
          result[k] = %arr
        else:
          v = v.strip(chars={'"'})
          result[k] = %v
  if requires.len > 0:
    result["requires"] = requires
  result