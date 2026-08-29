# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
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
  clueBuildTempPath* = cluePath / "buildtemp"
  clueDevelopPath* = cluePath / "develop"
  clueSourcesPath* = cluePath / "sources.json"
  clueRegistriesDir* = cluePath / "registries"
  nimbleLocalPackages* = getHomeDir() / ".nimble" / "packages_official.json"
  nimblePackagesUrl* = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"
  defaultSourceName* = "nim-lang"

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
  Source* = object
    name*: string
    url*: string

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

proc isValidSourceName*(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-', '_'}: return false
  true

proc sourceCachePath*(name: string): string =
  clueRegistriesDir / name & ".json"

proc ensureSourcesFile*() =
  discard existsOrCreateDir(cluePath)
  discard existsOrCreateDir(clueRegistriesDir)
  if not fileExists(clueSourcesPath):
    let defaultSources = %*{"sources": [%*{"name": defaultSourceName, "url": nimblePackagesUrl}]}
    writeFile(clueSourcesPath, pretty(defaultSources))

proc loadSources*(): seq[Source] =
  ensureSourcesFile()
  try:
    let j = parseFile(clueSourcesPath)
    let arr = if j.hasKey("sources"): j["sources"] else: j
    if arr.kind != JArray:
      displayWarning("Invalid sources.json: expected array, using default")
      return @[Source(name: defaultSourceName, url: nimblePackagesUrl)]
    for item in arr:
      if item.hasKey("name") and item.hasKey("url"):
        let n = item["name"].getStr
        let u = item["url"].getStr
        if isValidSourceName(n) and u.len > 0:
          result.add(Source(name: n, url: u))
    if result.len == 0:
      result.add(Source(name: defaultSourceName, url: nimblePackagesUrl))
  except CatchableError as e:
    displayWarning("Failed to read sources.json: " & e.msg & " — using default")
    result = @[Source(name: defaultSourceName, url: nimblePackagesUrl)]

proc saveSources*(sources: seq[Source]) =
  ensureSourcesFile()
  var arr = newJArray()
  for s in sources:
    arr.add(%*{"name": s.name, "url": s.url})
  writeFile(clueSourcesPath, pretty(%*{"sources": arr}))

var clueDB*: Store
var versionsDB*: Store
  ## The version index + deps cache live in their own store, separate from the
  ## registry/install-state DB (clue.db).
var clueInitialized = false

proc resetClueForTests*() =
  ## Reset init flag so next withClueDB reopens stores at current HOME.
  ## Only for tests — leaks old Store handles but test process is short-lived.
  clueInitialized = false

proc seedPackagesTable*(nimblePackages: JsonNode, source: string = defaultSourceName): int
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
      newColumn("web", dtText, false),
      newColumn("source", dtText, false)
    ]
  ))

  # migrate: packages table predating `source` column — add it
  block:
    let tblOpt = clueDB.getTable("packages")
    if tblOpt.isSome:
      let tbl = tblOpt.get()
      var hasSource = false
      for c in tbl.columns:
        if c.name == "source":
          hasSource = true
          break
      if not hasSource:
        # Boogie has no ALTER ADD COLUMN — recreate
        var rows: seq[RowData]
        for (pk, row) in tbl.allRows():
          rows.add(row)
        clueDB.dropTable("packages")
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
            newColumn("web", dtText, false),
            newColumn("source", dtText, false)
          ]
        ))
        for row in rows:
          var r = row
          r["source"] = newTextValue(defaultSourceName)
          discard clueDB.insertRow("packages", r)
        clueDB.checkpoint()

  # ensure sources.json and registries dir exist
  ensureSourcesFile()
  discard existsOrCreateDir(clueRegistriesDir)

  # migrate: direct URL installs where repo dir != nimble name (e.g. hetzner-api -> hetzner)
  block:
    # _cache dirs
    if dirExists(cluePkgsCachePath):
      for kind, path in walkDir(cluePkgsCachePath):
        if kind != pcDir: continue
        let dirName = path.extractFilename
        var nf = ""
        for f in walkFiles(path / "*.nimble"):
          if f.extractFilename != "nim.nimble":
            nf = f
            break
        if nf.len == 0: continue
        let canonical = nf.extractFilename.changeFileExt("")
        if canonical.len == 0 or canonical == dirName: continue
        let canonicalPath = cluePkgsCachePath / canonical
        if not dirExists(canonicalPath):
          try: moveDir(path, canonicalPath) except: discard
        # ensure packages row for canonical exists (direct installs never had one)
        try:
          let tbl = clueDB.getTable("packages").get()
          if tbl.where("name", newTextValue(canonical)).toSeq().len == 0:
            # try to copy from old dirName row if exists
            var copied = false
            for (_, row) in tbl.where("name", newTextValue(dirName)).toSeq():
              var r = row
              r["name"] = newTextValue(canonical)
              if r["source"].strVal.len == 0:
                r["source"] = newTextValue("direct")
              discard clueDB.insertRow("packages", r)
              copied = true
              break
            if not copied:
              var url = ""
              try:
                let (outp, code) = execCmdEx("git -C " & quoteShell(canonicalPath) & " config --get remote.origin.url")
                if code == 0: url = outp.strip()
              except: discard
              discard clueDB.insertRow("packages", row({
                "name": newTextValue(canonical),
                "url": newTextValue(url),
                "method": newTextValue("git"),
                "tags": newJsonValue(newJArray()),
                "description": newTextValue(""),
                "license": newTextValue(""),
                "web": newTextValue(""),
                "source": newTextValue("direct")
              }))
            clueDB.checkpoint()
        except: discard
    # installed dirs and DB rows
    if clueDB.hasTable("installed"):
      try:
        let tblOpt = clueDB.getTable("installed")
        if tblOpt.isSome:
          let tbl = tblOpt.get()
          var toMigrate: seq[tuple[pk: string, row: RowData, canonical: string, oldPath: string, newPath: string]] = @[]
          for (pk, row) in tbl.allRows():
            let oldName = row["name"].strVal
            let oldPath = row["path"].strVal
            if oldPath.len == 0 or not dirExists(oldPath): continue
            var nf = ""
            for f in walkFiles(oldPath / "*.nimble"):
              if f.extractFilename != "nim.nimble":
                nf = f
                break
            if nf.len == 0:
              # try parent base dir's nimble
              let base = oldPath.parentDir()
              for f in walkFiles(base / "*.nimble"):
                if f.extractFilename != "nim.nimble":
                  nf = f
                  break
              if nf.len == 0: continue
            let canonical = nf.extractFilename.changeFileExt("")
            if canonical.len == 0 or canonical == oldName: continue
            let newPath = oldPath.replace(oldName, canonical)
            toMigrate.add((pk, row, canonical, oldPath, newPath))
          for item in toMigrate:
            let baseOld = cluePkgsPath / item.row["name"].strVal
            let baseNew = cluePkgsPath / item.canonical
            if dirExists(baseOld) and not dirExists(baseNew):
              try: moveDir(baseOld, baseNew) except: discard
            # also fix _cache alias already handled
            discard clueDB.deleteRow("installed", item.pk)
            var r = item.row
            r["name"] = newTextValue(item.canonical)
            r["path"] = newTextValue(item.newPath)
            discard clueDB.insertRow("installed", r)
          if toMigrate.len > 0:
            clueDB.checkpoint()
      except: discard
    # ensure every _cache dir has a packages row (covers already-migrated direct installs missing registry entry)
    if dirExists(cluePkgsCachePath):
      for kind, path in walkDir(cluePkgsCachePath):
        if kind != pcDir: continue
        var nf = ""
        for f in walkFiles(path / "*.nimble"):
          if f.extractFilename != "nim.nimble":
            nf = f
            break
        if nf.len == 0: continue
        let canonical = nf.extractFilename.changeFileExt("")
        if canonical.len == 0: continue
        try:
          let tbl = clueDB.getTable("packages").get()
          if tbl.where("name", newTextValue(canonical)).toSeq().len == 0:
            var url = ""
            try:
              let (outp, code) = execCmdEx("git -C " & quoteShell(path) & " config --get remote.origin.url")
              if code == 0: url = outp.strip()
            except: discard
            if url.len == 0: continue
            discard clueDB.insertRow("packages", row({
              "name": newTextValue(canonical),
              "url": newTextValue(url),
              "method": newTextValue("git"),
              "tags": newJsonValue(newJArray()),
              "description": newTextValue(""),
              "license": newTextValue(""),
              "web": newTextValue(""),
              "source": newTextValue("direct")
            }))
            clueDB.checkpoint()
        except: discard

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
    let sources = loadSources()
    # keep legacy cache for default source on first run
    var seededAny = false
    for src in sources:
      let cacheFile = sourceCachePath(src.name)
      var nimblePackages: JsonNode
      var gotData = false
      if fileExists(cacheFile):
        try:
          nimblePackages = fromJsonFile(cacheFile)
          gotData = true
        except CatchableError:
          displayWarning("Failed to read " & cacheFile & ": " & getCurrentExceptionMsg())
      elif src.name == defaultSourceName and fileExists(nimbleLocalPackages):
        try:
          nimblePackages = fromJsonFile(nimbleLocalPackages)
          gotData = true
          # migrate legacy cache
          discard existsOrCreateDir(clueRegistriesDir)
          writeFile(cacheFile, $nimblePackages)
        except CatchableError:
          displayWarning("Failed to read " & nimbleLocalPackages & ": " & getCurrentExceptionMsg())
      if not gotData:
        displayInfo("Downloading registry for source: " & src.name & "...")
        try:
          discard existsOrCreateDir(clueRegistriesDir)
          let tmpFile = cacheFile & ".tmp"
          let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " &
            quoteShell(tmpFile) & " " & quoteShell(src.url))
          if exitCode != 0:
            raise newException(IOError, "curl failed: " & output)
          nimblePackages = fromJsonFile(tmpFile)
          moveFile(tmpFile, cacheFile)
          displaySuccess("Downloaded registry for " & src.name)
          gotData = true
        except CatchableError as e:
          displayWarning("Could not download registry for " & src.name & ": " & e.msg)
          continue
      if gotData:
        discard seedPackagesTable(nimblePackages, src.name)
        seededAny = true
    if seededAny:
      clueDB.checkpoint()
    else:
      displayWarning("No registry data seeded — run `clue source.fetch`")

proc seedPackagesTable*(nimblePackages: JsonNode, source: string = defaultSourceName): int =
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
        "web": newTextValue(localPkg["web"].getStr),
        "source": newTextValue(source)
      }))
      inc result
    except CatchableError:
      discard

proc refreshSource*(sourceName: string): bool =
  ## Fetch a single source's packages.json and re-seed its rows.
  var srcOpt: Option[Source]
  for s in loadSources():
    if s.name == sourceName:
      srcOpt = some(s)
      break
  if srcOpt.isNone:
    displayError("Unknown source: " & sourceName, quitProcess = true)
    return false
  let src = srcOpt.get()
  let cacheFile = sourceCachePath(src.name)
  let tmpFile = cacheFile & ".tmp"
  try:
    discard existsOrCreateDir(clueRegistriesDir)
    let (output, exitCode) = execCmdEx("curl -fsSL --connect-timeout 10 -o " &
      quoteShell(tmpFile) & " " & quoteShell(src.url))
    if exitCode != 0:
      displayError("Failed to download registry for " & src.name & ": " & output, quitProcess = true)
      return false
    var nimblePackages: JsonNode
    try:
      nimblePackages = fromJsonFile(tmpFile)
    except CatchableError:
      removeFile(tmpFile)
      displayError("Failed to parse registry for " & src.name & ": " & getCurrentExceptionMsg(), quitProcess = true)
      return false
    moveFile(tmpFile, cacheFile)
    # also keep legacy file for nim-lang compat
    if src.name == defaultSourceName:
      try:
        discard existsOrCreateDir(nimbleLocalPackages.parentDir())
        copyFile(cacheFile, nimbleLocalPackages)
      except CatchableError: discard
    initClue()
    let tbl = clueDB.getTable("packages").get()
    for (pk, row) in tbl.allRows():
      if row["source"].strVal == src.name:
        discard clueDB.deleteRow("packages", pk)
    let count = seedPackagesTable(nimblePackages, src.name)
    clueDB.checkpoint()
    displaySuccess("Updated " & src.name & " (" & $count & " packages)")
    return true
  except CatchableError as e:
    displayError("Failed to update source " & sourceName & ": " & e.msg, quitProcess = true)
    false

proc refreshAllSources*(): bool =
  var ok = true
  var anyOk = false
  for src in loadSources():
    if not refreshSource(src.name):
      ok = false
    else:
      anyOk = true
  result = anyOk

proc refreshRegistry*(): bool =
  ## Backward-compat alias: refresh all sources.
  refreshAllSources()

template withClueDB*(stmt) =
  initClue()
  stmt

proc fetchPkgMeta*(pkgName: string, sourceFilter: string = ""): Option[PkgRef] =
  ## Look up a package URL from the registry DB.
  ## If sourceFilter is set, only that source is searched; otherwise
  ## priority follows sources.json order, and helper hint is provided.
  withClueDB do:
    let tbl = clueDB.getTable("packages").get()
    if sourceFilter.len > 0:
      let res = tbl.where("name", newTextValue(pkgName)).toSeq()
      for (_, row) in res:
        if row["source"].strVal == sourceFilter:
          return some(PkgRef(name: pkgName, url: row["url"].strVal, refStr: ""))
      # not found in requested source — provide hint
      if res.len > 0:
        var foundSources: seq[string]
        for (_, row) in res:
          foundSources.add(row["source"].strVal)
        displayWarning("Package '" & pkgName & "' not found in source '" &
          sourceFilter & "' but found in: " & foundSources.join(", ") &
          " — use --source=" & foundSources[0])
      return none(PkgRef)
    else:
      # priority-ordered lookup: iterate sources.json order
      let sources = loadSources()
      var bySource = initTable[string, string]()
      for (_, row) in tbl.where("name", newTextValue(pkgName)).toSeq():
        let src = row["source"].strVal
        if src notin bySource:
          bySource[src] = row["url"].strVal
      for src in sources:
        if src.name in bySource:
          return some(PkgRef(name: pkgName, url: bySource[src.name], refStr: ""))
      # fallback: any source (for DBs predating migration)
      let res = tbl.where("name", newTextValue(pkgName)).toSeq()
      if res.len == 0:
        return none(PkgRef)
      return some(PkgRef(name: pkgName, url: res[0][1]["url"].strVal, refStr: ""))
  none(PkgRef)

proc fetchAllPkgMetas*(pkgName: string): seq[PkgRef] =
  withClueDB do:
    for (_, row) in clueDB.getTable("packages").get().where("name", newTextValue(pkgName)).toSeq():
      result.add(PkgRef(name: pkgName, url: row["url"].strVal, refStr: ""))
  # dedupe by url not needed

# parseNimbleFile is defined in nimbleparser.nim

proc resolveNimBin*(): string =
  ## Resolve the nim compiler binary.
  ## Priority: .env/venv.json > PATH > ~/.choosenim/current/bin/nim > bare "nim"
  let venvConfig = getCurrentDir() / ".env" / "venv.json"
  if fileExists(venvConfig):
    try:
      let config = parseFile(venvConfig)
      let nimBin = config["nim_bin"].getStr()
      if nimBin.len > 0 and dirExists(nimBin):
        let nimExe = nimBin / "nim"
        if fileExists(nimExe):
          return nimExe
    except CatchableError:
      discard
  let nimPath = findExe("nim")
  if nimPath.len > 0:
    return nimPath
  let choosenimBin = getHomeDir() / ".choosenim" / "current" / "bin" / "nim"
  if fileExists(choosenimBin):
    return choosenimBin
  "nim"

proc defaultToolchainFlags*(userFlags = ""): string =
  ## Default native include/link search paths per operating system, appended
  ## to every compile so headers/libs from common package managers (MacPorts,
  ## Homebrew) resolve without manual `--passC` / `--passL`. Skipped entirely
  ## when `userFlags` already contains an explicit --passC/--passL.
  if userFlags.contains("--passC") or userFlags.contains("--passL"):
    return ""
  var parts: seq[string]
  proc check(incDir, libDir: string) =
    if dirExists(incDir):
      parts.add(" --passC:-I" & incDir)
    if dirExists(libDir):
      parts.add(" --passL:-L" & libDir)
      parts.add(" --passL:-Wl,-rpath," & libDir)
  when defined(macosx):
    check("/opt/local/include", "/opt/local/lib")
    check("/opt/homebrew/include", "/opt/homebrew/lib")
    check("/usr/local/include", "/usr/local/lib")
  elif defined(linux):
    check("/usr/local/include", "/usr/local/lib")
  result = parts.join("")

proc defaultColorsFlag*(userFlags = ""): string =
  ## Nim compiler colors default to on so errors stay readable when output is
  ## captured; suppressed when the user passes their own `--colors:<x>` flag.
  if userFlags.contains("--colors"): "" else: " --colors:on"

proc detectNimVersion*(): string =
  ## The installed `nim --version` as `major.minor.patch` (fallback "2.2.10").
  let (outp, code) = execCmdEx(resolveNimBin() & " --version")
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