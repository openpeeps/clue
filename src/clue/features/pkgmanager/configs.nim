# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[os, osproc, strutils, options, sequtils, tables]

import pkg/boogie/stores/rdbms
import pkg/openparser/json

import pkg/kapsis/interactive/prompts

import ./resolver

export rdbms

const
  cluePath* = getHomeDir() / ".clue"
  clueDBPath* = cluePath / "clue.db"
  cluePkgsPath* = cluePath / "packages"
  cluePkgsCachePath* = cluePkgsPath / "_cache"
  nimbleLocalPackages* = getHomeDir() / ".nimble" / "packages_official.json"
  nimblePackagesUrl* = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

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

type
  PkgRef* = object
    name*: string
    refStr*: string  # explicit branch/tag only — "" = default branch
    url*: string

  NimbleDependency* = object
    name*: string
    url*: string
    constraint*: VersionConstraint
    branch*: string
    tag*: string
    features*: seq[string]
      ## Feature activations from `pkg[feat1, feat2]` (nimble --features).
    isNim*: bool

  NimbleFile* = object
    path*: string
    version*: string
    author*: string
    description*: string
    license*: string
    srcDir*: string
    binDir*: string
    bin*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    requires*: seq[NimbleDependency]
      ## Hard (always-active) dependencies.
    features*: Table[string, seq[NimbleDependency]]
      ## `feature "name":` blocks → conditional dependencies.

var clueDB*: Store

proc initClue*() =
  discard existsOrCreateDir(cluePath)
  discard existsOrCreateDir(cluePkgsPath)
  discard existsOrCreateDir(cluePkgsCachePath)

  var hasDatabase = fileExists(clueDBPath)
  clueDB = newStore(clueDBPath, StorageMode.smDisk,
                    enableWal = true, walFlushEveryOps = 100'u32)

  clueDB.createTableIfNotExist(newTable(
    name = "packages",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("url", dtText, false),
      newColumn("method", dtText, false),
      newColumn("tags", dtJson, false),
      newColumn("description", dtText, false),
      newColumn("license", dtText, false),
      newColumn("web", dtText, false)
    ]
  ))
  clueDB.createTableIfNotExist(newTable(
    name = "versions",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("tag", dtText, false),
      newColumn("deps", dtJson, false),
      newColumn("discovered_at", dtText, false)
    ]
  ))
  # migrate: the installed table predating the `features` column is rebuilt
  # (its data is only the install graph, reconstructed on next install).
  if clueDB.hasTable("installed"):
    let installedTbl = clueDB.getTable("installed").get()
    var hasFeatures = false
    for c in installedTbl.columns:
      if c.name == "features":
        hasFeatures = true
        break
    if not hasFeatures:
      clueDB.dropTable("installed")

  clueDB.createTableIfNotExist(newTable(
    name = "installed",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("root", dtBool, false),
      newColumn("features", dtJson, false),
      newColumn("deps", dtJson, false),
      newColumn("installed_at", dtText, false)
    ]
  ))

  if not hasDatabase:
    displayInfo("Initializing Clue database...")
    var nimblePackages: JsonNode
    if fileExists(nimbleLocalPackages):
      try:
        nimblePackages = fromJsonFile(nimbleLocalPackages)
      except CatchableError:
        displayWarning("Failed to read " & nimbleLocalPackages & ": " & getCurrentExceptionMsg())
        nimblePackages = newJArray()
    else:
      displayInfo("Package registry not found, downloading...")
      try:
        let nimbleDir = nimbleLocalPackages.parentDir()
        discard existsOrCreateDir(nimbleDir)
        let tmpFile = nimbleLocalPackages & ".tmp"
        let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " & tmpFile & " " & nimblePackagesUrl)
        if exitCode != 0:
          raise newException(IOError, "curl failed: " & output)
        nimblePackages = fromJsonFile(tmpFile)
        moveFile(tmpFile, nimbleLocalPackages)
        displaySuccess("Downloaded package registry from nim-lang/packages")
      except CatchableError as e:
        displayWarning("Could not download package registry: " & e.msg)
        nimblePackages = newJArray()

    for localPkg in nimblePackages:
      if localPkg.hasKey("alias") or not localPkg.hasKey("web"):
        continue
      try:
        let mthd = if localPkg.hasKey"method": localPkg["method"].getStr else: ""
        clueDB.insertRow("packages", row({
          "name": newTextValue(localPkg["name"].getStr),
          "url": newTextValue(localPkg["url"].getStr),
          "method": newTextValue(mthd),
          "tags": newJsonValue(localPkg["tags"]),
          "description": newTextValue(localPkg["description"].getStr),
          "license": newTextValue(localPkg["license"].getStr),
          "web": newTextValue(localPkg["web"].getStr)
        }))
      except CatchableError:
        discard

    clueDB.checkpoint()

template withClueDB*(stmt) =
  initClue()
  stmt

proc fetchPkgMeta*(pkgName: string): Option[PkgRef] =
  ## Look up a package URL from the registry DB.
  withClueDB do:
    let res = clueDB.getTable("packages").get().where("name", newTextValue(pkgName)).toSeq()
    if res.len == 0:
      return none(PkgRef)
    return some(PkgRef(name: pkgName, url: res[0][1]["url"].strVal, refStr: ""))
  none(PkgRef)

# parseNimbleFile is defined in nimbleparser.nim