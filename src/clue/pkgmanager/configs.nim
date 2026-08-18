# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[os, osproc, strutils, options, sequtils, tables, times]

import pkg/boogie/stores/rdbms
import pkg/openparser/json
import pkg/semver

import pkg/kapsis/interactive/prompts

import ./resolver

export rdbms

## Permanent debug tracing: enable with `CLUE_DEBUG=1` (or `-d:clueDebug`).
var debugEnabled*: bool = getEnv("CLUE_DEBUG") == "1" or defined(clueDebug)

proc debugLog*(msg: string) =
  ## Echo a debug trace line to stderr (never interferes with the spinner on
  ## stdout). Kept intentionally — it's how we diagnose hangs/timeouts.
  if debugEnabled:
    stderr.writeLine("[clue] " & msg)

let
  cluePath* = getHomeDir() / ".clue"
  clueDBPath* = cluePath / "clue.db"
  versionsDBPath* = cluePath / "versions.db"
  cluePkgsPath* = cluePath / "packages"
  cluePkgsCachePath* = cluePkgsPath / "_cache"
  clueBinPath* = cluePath / "bin"
  clueDevelopPath* = cluePath / "develop"
  nimbleLocalPackages* = getHomeDir() / ".nimble" / "packages_official.json"
  nimblePackagesUrl* = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

proc isInsidePkgs*(dir: string): bool =
  ## True when `dir` lives inside the clue package registry (~/.clue/packages).
  ## Everything clue manages lives here; anything outside it must never be
  ## deleted (e.g. develop-mode installs that point at the user's source tree).
  dir == cluePkgsPath or dir.startsWith(cluePkgsPath & DirSep)

proc safeRemoveDir*(dir: string) =
  ## Remove a directory, refusing anything outside the package registry. This
  ## is the only deletion layer clue uses — it guarantees develop-mode installs
  ## and arbitrary user files are never touched.
  if not isInsidePkgs(dir):
    debugLog("refusing to remove outside ~/.clue/packages: " & dir)
    return
  if dirExists(dir):
    removeDir(dir)

proc safeRemoveSymlink*(p: string) =
  ## Remove a develop-mode symlink stored under ~/.clue/develop. Only ever
  ## unlinks the symlink entry itself — the target (the user's source tree) is
  ## never touched.
  if not p.startsWith(clueDevelopPath & DirSep):
    debugLog("refusing to remove outside ~/.clue/develop: " & p)
    return
  if symlinkExists(p):
    removeFile(p)

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
    dev*: seq[NimbleDependency]
      ## The `dev:` block → development-only dependencies.
    tasks*: seq[tuple[name, description: string]]
      ## Nimscript tasks defined in the .nimble file.

var clueDB*: Store
var versionsDB*: Store
  ## The version index + deps cache live in their own store, separate from the
  ## registry/install-state DB (clue.db).
var clueInitialized = false

proc seedPackagesTable(nimblePackages: JsonNode): int
  ## Defined below, after `initClue`.

proc initClue*() =
  # Open the stores + run migrations exactly once per process — `withClueDB` is
  # used per DB operation, so re-initializing on every call is very slow.
  if clueInitialized:
    return
  clueInitialized = true

  discard existsOrCreateDir(cluePath)
  discard existsOrCreateDir(cluePkgsPath)
  discard existsOrCreateDir(cluePkgsCachePath)
  discard existsOrCreateDir(clueBinPath)
  discard existsOrCreateDir(clueDevelopPath)

  var hasDatabase = fileExists(clueDBPath)
  clueDB = newStore(clueDBPath, StorageMode.smDisk,
                    enableWal = true, walFlushEveryOps = 100'u32)
  versionsDB = newStore(versionsDBPath, StorageMode.smDisk,
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

  # migrate: the installed table predating the `features`/`path` columns is
  # rebuilt (its data is only the install graph, reconstructed on next install).
  if clueDB.hasTable("installed"):
    let installedTbl = clueDB.getTable("installed").get()
    var hasFeatures = false
    var hasPath = false
    for c in installedTbl.columns:
      if c.name == "features":
        hasFeatures = true
      elif c.name == "path":
        hasPath = true
    if not (hasFeatures and hasPath):
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
      newColumn("path", dtText, false),
      newColumn("installed_at", dtText, false)
    ]
  ))

  # --- versions.db: version index + deps cache ---
  versionsDB.createTableIfNotExist(newTable(
    name = "versions",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("tag", dtText, false),
      newColumn("discovered_at", dtText, false)
    ]
  ))
  versionsDB.createTableIfNotExist(newTable(
    name = "deps",
    primaryKey = "id",
    columns = [
      newColumn("id", dtInt, false),
      newColumn("name", dtText, false),
      newColumn("version", dtText, false),
      newColumn("deps", dtJson, false),
      newColumn("cached_at", dtText, false)
    ]
  ))

  # migrate: move legacy `versions`/`deps` tables out of clue.db into versions.db
  if clueDB.hasTable("versions"):
    let srcTbl = clueDB.getTable("versions").get()
    var versionRows: seq[tuple[name, version, tag, discoveredAt: string]]
    var depsRows: seq[tuple[name, version, depsJson: string]]
    for (pk, row) in srcTbl.allRows():
      if row["deps"].jsonVal.len > 2:
        depsRows.add((row["name"].strVal, row["version"].strVal, row["deps"].jsonVal))
      else:
        versionRows.add((row["name"].strVal, row["version"].strVal,
          row["tag"].strVal, row["discovered_at"].strVal))
    for (name, version, tag, at) in versionRows:
      discard versionsDB.insertRow("versions", row({
        "name": newTextValue(name),
        "version": newTextValue(version),
        "tag": newTextValue(tag),
        "discovered_at": newTextValue(at)
      }))
    for (name, version, depsJson) in depsRows:
      discard versionsDB.insertRow("deps", row({
        "name": newTextValue(name),
        "version": newTextValue(version),
        "deps": newJSONValue(parseJson(depsJson)),
        "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
      }))
    if versionRows.len > 0 or depsRows.len > 0:
      versionsDB.checkpoint()
    clueDB.dropTable("versions")
  if clueDB.hasTable("deps"):
    for (pk, row) in clueDB.getTable("deps").get().allRows():
      discard versionsDB.insertRow("deps", row({
        "name": newTextValue(row["name"].strVal),
        "version": newTextValue(row["version"].strVal),
        "deps": newJSONValue(parseJson(row["deps"].jsonVal)),
        "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
      }))
    versionsDB.checkpoint()
    clueDB.dropTable("deps")

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

    discard seedPackagesTable(nimblePackages)
    clueDB.checkpoint()

proc seedPackagesTable(nimblePackages: JsonNode): int =
  ## Insert every non-alias package from the registry index into the `packages`
  ## table. The caller must hold the `withClueDB` context. Returns the number of
  ## packages inserted.
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
      inc result
    except CatchableError:
      discard

proc refreshRegistry*(): bool =
  ## Fetch a fresh packages.json from the nim registry and re-seed the
  ## `packages` table in clue.db. Non-destructive: on any failure the previous
  ## index is kept.
  try:
    let nimbleDir = nimbleLocalPackages.parentDir()
    discard existsOrCreateDir(nimbleDir)
    let tmpFile = nimbleLocalPackages & ".tmp"
    let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " &
      tmpFile & " " & nimblePackagesUrl)
    if exitCode != 0:
      displayError("Failed to download package registry: " & output, quitProcess = true)
      return false
    var nimblePackages: JsonNode
    try:
      nimblePackages = fromJsonFile(tmpFile)
    except CatchableError:
      removeFile(tmpFile)
      displayError("Failed to parse downloaded registry: " & getCurrentExceptionMsg(), quitProcess = true)
      return false
    moveFile(tmpFile, nimbleLocalPackages)
    var count = 0
    initClue()
    let tbl = clueDB.getTable("packages").get()
    for (pk, row) in tbl.allRows():
      discard clueDB.deleteRow("packages", pk)
    count = seedPackagesTable(nimblePackages)
    clueDB.checkpoint()
    displaySuccess("Updated package registry (" & $count & " packages)")
    return true
  except CatchableError as e:
    displayError("Failed to update package registry: " & e.msg, quitProcess = true)
    false

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

proc detectNimVersion*(): string =
  ## The installed `nim --version` as `major.minor.patch` (fallback "2.2.10").
  let (outp, code) = execCmdEx("nim --version")
  if code != 0:
    return "2.2.10"
  for line in outp.splitLines():
    if "Nim Compiler Version" in line:
      for w in line.splitWhitespace():
        if w.len > 0 and w[0] in {'0'..'9'}:
          let parts = w.split('.')
          if parts.len >= 2:
            return if parts.len >= 3: parts[0] & "." & parts[1] & "." & parts[2]
                   else: parts[0] & "." & parts[1]
  "2.2.10"

proc checkNimConstraint*(nimble: NimbleFile) =
  ## Check the nimble `requires "nim ..."` constraint against the installed
  ## Nim compiler. Exact (`=`) mismatches are fatal — the build will fail.
  ## Range mismatches (`>=`, `<`, etc.) emit a warning since the build may
  ## still work.
  for d in nimble.requires:
    if not d.isNim: continue
    if d.constraint.kind == vcAny: continue
    let currentNim = detectNimVersion()
    try:
      let curVer = parseVersion(currentNim)
      if not curVer.satisfies(d.constraint):
        if d.constraint.kind == vcExact:
          displayError("Nim " & currentNim & " does not satisfy exact constraint " &
            $d.constraint & " — required by nimble, cannot proceed", quitProcess = true)
        else:
          displayWarning("Nim " & currentNim & " does not satisfy constraint " &
            $d.constraint & " — build may fail")
    except CatchableError:
      discard