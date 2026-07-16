# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/os

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
  NimbleDependency* = object
    name*: string
    url*: string
    constraint*: VersionConstraint
    branch*: string
    tag*: string
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
    requires*: seq[NimbleDependency]

var clueDB*: Store

proc initClue*() =
  discard existsOrCreateDir(cluePath)
  discard existsOrCreateDir(cluePkgsPath)

  var hasDatabase = fileExists(clueDBPath)
  clueDB = newStore(clueDBPath, StorageMode.smDisk,
                    enableWal = true, walFlushEveryOps = 100'u32)
  if not hasDatabase:
    displayInfo("Initializing Clue database...")
    clueDB.createTable(newTable(
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

    let nimblePackages = fromJsonFile(nimbleLocalPackages)
    for localPkg in nimblePackages:
      if localPkg.hasKey("alias") or not localPkg.hasKey("web"):
        continue
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

    clueDB.checkpoint()

template withClueDB*(stmt) =
  initClue()
  stmt

# parseNimbleFile is defined in nimbleparser.nim