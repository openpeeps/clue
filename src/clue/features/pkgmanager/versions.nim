# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Version discovery + install engine for the clue package manager.
##
## Discovery is fast: versions and parsed deps are cached in the `versions`
## DB table, so repeat installs need zero network and zero re-parsing.
## Versions are read from the remote (`git ls-remote --tags`) only when a
## package isn't cached yet, and locally (`git tag --list`) once cloned.

import std/[os, osproc, strutils, tables, sets, sequtils, algorithm, times, json, options]

import pkg/semver
import pkg/kapsis/interactive/prompts

import ./configs
import ./resolver
import ./nimbleparser

type
  DiscoveredVersion* = object
    version*: Version
    tag*: string

  DepEntry* = tuple[name: string, version: string]
    ## A resolved dependency entry for the installed manifest.

proc clonePackage*(url, dest: string): bool =
  ## Clone (or refresh) a package repository into the cache.
  ## Refreshes tags from the remote even when the cache already exists.
  if dirExists(dest):
    let (output, exitCode) = execCmdEx("git -C " & dest & " fetch --tags --prune --quiet")
    if exitCode != 0:
      displayWarning("Failed to refresh " & dest & ": " & output)
    return true
  let cmd = "git clone " & url & " " & dest
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    displayWarning("Failed to clone " & url & ": " & output)
    return false
  discard execCmdEx("git -C " & dest & " fetch --tags --quiet")
  true

proc checkoutTag*(dest, tag: string): bool =
  ## Checkout an exact tag/ref in the cached repo (detached HEAD).
  let (output, code) = execCmdEx("git -C " & dest & " checkout " & tag & " --quiet 2>/dev/null")
  code == 0

proc checkoutRef*(dest, refStr: string): bool =
  ## Checkout a branch or arbitrary ref in the cached repo.
  let (output, code) = execCmdEx("git -C " & dest & " checkout " & refStr & " --quiet 2>/dev/null")
  code == 0

proc findLocalTags(dest: string): seq[string] =
  let (output, exitCode) = execCmdEx("git -C " & dest & " tag --list")
  if exitCode != 0: return @[]
  for line in output.splitLines():
    let tag = line.strip()
    if tag.len > 0: result.add(tag)

proc listRemoteTags(url: string): seq[string] =
  ## List all tag refs on a git remote without cloning.
  let (output, exitCode) = execCmdEx("git ls-remote --tags " & url)
  if exitCode != 0: return @[]
  var seen: seq[string]
  var set = initHashSet[string]()
  const prefix = "refs/tags/"
  for line in output.splitLines():
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    let refName = parts[1]
    if refName.endsWith("^{}"): continue   # skip peeled annotated-tag refs
    if refName.startsWith(prefix):
      let tag = refName[prefix.len .. ^1]
      if tag notin set:
        set.incl(tag)
        seen.add(tag)
  seen

proc parseTag(tag: string): tuple[ok: bool, ver: Version] =
  let verStr = if tag.startsWith("v"): tag[1 .. ^1] else: tag
  try:
    (true, parseVersion(verStr))
  except CatchableError:
    (false, newVersion(0, 0, 0))

proc tagForVersion*(dest: string, version: string): string =
  ## Find the exact git tag whose semver equals `version`.
  try:
    let want = parseVersion(version)
    for tag in findLocalTags(dest):
      let (ok, ver) = parseTag(tag)
      if ok and ver == want:
        return tag
  except CatchableError:
    discard
  let tags = findLocalTags(dest)
  if ("v" & version) in tags: return "v" & version
  if version in tags: return version
  ""

proc isCruftName(name: string, nimble: NimbleFile): bool =
  ## Heuristic for repo cruft we don't install (VCS, tests, examples, docs).
  let lower = name.toLowerAscii
  result = lower in [".git", ".github", ".gitignore", ".gitattributes",
                     "tests", "examples", "example", "docs", "nimcache"] or
    lower in nimble.skipDirs or lower in nimble.skipFiles

proc installCleanCopy*(cacheDir, verDir: string, nimble: NimbleFile) =
  ## Copy a package into `verDir` with a clean, flat layout matching nimble's
  ## pkgs2: the `srcDir` contents are placed at the package root (so
  ## `import pkg/<name>` resolves with `--path:verDir`), plus the nimble file
  ## and any installDirs/installFiles/installExt. VCS/test cruft is skipped.
  createDir(verDir)

  proc copyEntry(e: string) =
    let name = e.extractFilename
    if isCruftName(name, nimble): return
    if dirExists(e):
      copyDir(e, verDir / name)
    else:
      copyFile(e, verDir / name)

  # source files: flatten srcDir (or repo root when no srcDir)
  if nimble.srcDir.len > 0 and dirExists(cacheDir / nimble.srcDir):
    for e in walkDir(cacheDir / nimble.srcDir):
      copyEntry(e.path)
  else:
    for e in walkDir(cacheDir):
      copyEntry(e.path)

  # nimble file
  let nimbleFile = cacheDir / nimble.path.extractFilename
  if fileExists(nimbleFile):
    copyFile(nimbleFile, verDir / nimble.path.extractFilename)

  # explicit install dirs/files
  for d in nimble.installDirs:
    if dirExists(cacheDir / d):
      copyDir(cacheDir / d, verDir / d)
  for f in nimble.installFiles:
    if fileExists(cacheDir / f):
      copyFile(cacheDir / f, verDir / f)

  # files matching installExt (searched under the source dir)
  if nimble.installExt.len > 0:
    let srcDir = if nimble.srcDir.len > 0: cacheDir / nimble.srcDir else: cacheDir
    var found: seq[string]
    for f in walkDirRec(srcDir):
      if f.extractFilename.splitFile.ext in nimble.installExt and f notin found:
        found.add(f)
    for f in found:
      let rel = relativePath(f, srcDir)
      let target = verDir / rel
      if not dirExists(target.parentDir()):
        createDir(target.parentDir())
      copyFile(f, target)

#
# Versions cache (DB)
#

proc cacheVersions(name: string, versions: seq[DiscoveredVersion]) =
  withClueDB do:
    let tbl = clueDB.getTable("versions").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      discard clueDB.deleteRow("versions", pk)
    let nowStr = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    for v in versions:
      discard clueDB.insertRow("versions", row({
        "name": newTextValue(name),
        "version": newTextValue($v.version),
        "tag": newTextValue(v.tag),
        "deps": newJSONValue(newJArray()),
        "discovered_at": newTextValue(nowStr)
      }))
    clueDB.checkpoint()

proc discoverVersions*(name, url: string, refresh = false): seq[DiscoveredVersion] =
  ## Discover all semver versions for a package, newest first.
  ## Serves from the DB cache unless `refresh` is set.
  result = @[]
  var served = false
  if not refresh:
    withClueDB do:
      let rows = clueDB.getTable("versions").get().where("name", newTextValue(name)).toSeq()
      if rows.len > 0:
        var all: seq[DiscoveredVersion]
        for (pk, row) in rows:
          try:
            all.add(DiscoveredVersion(version: parseVersion(row["version"].strVal),
                                      tag: row["tag"].strVal))
          except CatchableError:
            discard
        if all.len > 0:
          all.sort(proc(a, b: DiscoveredVersion): int = cmp(b.version, a.version))
          result = all
          served = true
  if not served:
    let dest = cluePkgsCachePath / name
    let tags =
      if dirExists(dest): findLocalTags(dest)
      else: listRemoteTags(url)
    var all: seq[DiscoveredVersion]
    for tag in tags:
      let (ok, ver) = parseTag(tag)
      if ok:
        all.add(DiscoveredVersion(version: ver, tag: tag))
    all.sort(proc(a, b: DiscoveredVersion): int = cmp(b.version, a.version))
    # dedupe by version (e.g. "1.2.3" and "v1.2.3" both present)
    var seen: seq[Version]
    for v in all:
      if v.version notin seen:
        seen.add(v.version)
        result.add(v)
    cacheVersions(name, result)

proc headVersion*(name: string): Version =
  ## Version to register for a package with no semver tags: the version
  ## declared in its nimble file (checked out at the default branch),
  ## or 0.0.0 when unknown.
  let dest = cluePkgsCachePath / name
  if not dirExists(dest):
    let meta = fetchPkgMeta(name)
    if meta.isNone:
      return newVersion(0, 0, 0)
    if not clonePackage(meta.get().url, dest):
      return newVersion(0, 0, 0)
  let nimblePath = dest / name.changeFileExt("nimble")
  if fileExists(nimblePath):
    try:
      return parseVersion(parseNimbleFile(nimblePath).version)
    except CatchableError:
      discard
  newVersion(0, 0, 0)

const
  depsCacheVersion = 3

type
  CachedDeps = object
    hard: seq[NimbleDependency]
    features: Table[string, seq[NimbleDependency]]

proc depsToJsonArr(deps: seq[NimbleDependency]): JsonNode =
  result = newJArray()
  for d in deps:
    var node = %*{"name": d.name, "url": d.url, "branch": d.branch,
                  "constraint": $d.constraint, "isNim": d.isNim}
    if d.features.len > 0:
      node["features"] = %d.features
    result.add(node)

proc jsonToDepsArr(n: JsonNode): seq[NimbleDependency] =
  for d in n:
    var features: seq[string]
    if d.hasKey("features"):
      for f in d["features"]:
        features.add(f.getStr)
    result.add(NimbleDependency(
      name: d["name"].getStr,
      url: d["url"].getStr,
      branch: d["branch"].getStr,
      constraint: parseConstraint(d["constraint"].getStr),
      features: features,
      isNim: if d.hasKey("isNim"): d["isNim"].getBool else: false
    ))

proc readCachedDeps(name, version: string): Option[CachedDeps] =
  withClueDB do:
    let rows = clueDB.getTable("versions").get().where("name", newTextValue(name)).toSeq()
    for (pk, row) in rows:
      if row["version"].strVal == version and row["deps"].jsonVal.len > 2:
        try:
          let n = parseJson(row["deps"].jsonVal)
          if n.kind != JObject:
            # legacy cache format: a flat array of deps (no feature blocks)
            return some(CachedDeps(hard: jsonToDepsArr(n)))
          if not n.hasKey("v") or n["v"].getInt != depsCacheVersion:
            # cache written by an older clue — re-parse
            return none(CachedDeps)
          var res = CachedDeps(hard: jsonToDepsArr(n["hard"]))
          if n.hasKey("features"):
            for fname, fnode in n["features"]:
              res.features[fname] = jsonToDepsArr(fnode)
          return some(res)
        except CatchableError:
          return none(CachedDeps)
  none(CachedDeps)

proc cacheDeps(name, version: string, deps: CachedDeps) =
  withClueDB do:
    let tbl = clueDB.getTable("versions").get()
    var found = false
    var tag = ""
    var discoveredAt = ""
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        tag = row["tag"].strVal
        discoveredAt = row["discovered_at"].strVal
        discard clueDB.deleteRow("versions", pk)
        found = true
        break
    if not found:
      discoveredAt = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    var featsNode = newJObject()
    for fname, fdeps in deps.features:
      featsNode[fname] = depsToJsonArr(fdeps)
    let depsNode = %*{"v": depsCacheVersion,
                      "hard": depsToJsonArr(deps.hard), "features": featsNode}
    discard clueDB.insertRow("versions", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "tag": newTextValue(tag),
      "deps": newJSONValue(depsNode),
      "discovered_at": newTextValue(discoveredAt)
    }))
    clueDB.checkpoint()

proc getDeps*(name, version: string, features: seq[string] = @[],
    refresh = false): seq[NimbleDependency] =
  ## Lazily fetch the dependency list for a specific package version,
  ## including the requires of any activated `features`. Serves from the
  ## DB cache, cloning + parsing on first demand.
  result = @[]
  var cached: Option[CachedDeps]
  if not refresh:
    cached = readCachedDeps(name, version)
    # if a requested feature is missing from the cached feature map, the
    # cache predates feature parsing — re-parse from the nimble file.
    if cached.isSome:
      for f in features:
        if not cached.get.features.hasKey(f):
          cached = none(CachedDeps)
          break

  var deps: CachedDeps
  if cached.isSome:
    deps = cached.get
  else:
    let dest = cluePkgsCachePath / name
    if not dirExists(dest):
      let meta = fetchPkgMeta(name)
      if meta.isNone:
        displayWarning("Unknown package in registry: " & name)
        return @[]
      if not clonePackage(meta.get().url, dest):
        return @[]

    # checkout the exact version tag (0.0.0 = HEAD marker, keep default branch)
    if version != "0.0.0":
      let tag = tagForVersion(dest, version)
      if tag.len > 0:
        discard checkoutTag(dest, tag)

    let nimblePath = dest / name.changeFileExt("nimble")
    if fileExists(nimblePath):
      let pkg = parseNimbleFile(nimblePath)
      for dep in pkg.requires:
        if not dep.isNim:
          deps.hard.add(dep)
      for fname, fdeps in pkg.features:
        var farr: seq[NimbleDependency]
        for dep in fdeps:
          if not dep.isNim:
            farr.add(dep)
        deps.features[fname] = farr
      cacheDeps(name, version, deps)

  result = deps.hard
  for f in features:
    if deps.features.hasKey(f):
      for dep in deps.features[f]:
        result.add(dep)

#
# Installed manifest + pruning
#

proc recordInstall*(name, version: string, deps: seq[DepEntry], root = false,
    features: seq[string] = @[]) =
  ## Record an installed package version with its resolved dependencies.
  ## `root` marks packages the user explicitly installed (vs. pulled as deps);
  ## only roots survive pruning. `features` are the active feature set the
  ## package was resolved with (used to emit `-d:features.<pkg>.<feat>`).
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        discard clueDB.deleteRow("installed", pk)
    var depsArr = newJArray()
    for (dn, dv) in deps:
      depsArr.add(%*{"name": dn, "version": dv})
    discard clueDB.insertRow("installed", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "root": newBoolValue(root),
      "features": newJSONValue(%features),
      "deps": newJSONValue(depsArr),
      "installed_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
    }))
    clueDB.checkpoint()

proc installedFeatures*(): Table[string, seq[string]] =
  ## Map of installed package name -> the features it was resolved with.
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      if result.hasKey(name):
        continue  # first (arbitrary) row wins; keep it simple
      var feats: seq[string]
      try:
        if row.hasKey("features"):
          for f in parseJson(row["features"].jsonVal):
            feats.add(f.getStr)
      except CatchableError:
        discard
      result[name] = feats
  result

proc unrecordInstall*(name, version: string) =
  ## Remove an installed record (dirs removed separately by the caller).
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if version.len == 0 or row["version"].strVal == version:
        discard clueDB.deleteRow("installed", pk)
    clueDB.checkpoint()

proc pruneOrphans*(verbose = true) =
  ## Remove installed packages that are no longer reachable from any root,
  ## or whose resolved version no longer matches the current dependency graph.
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()

    var depsOf: Table[string, seq[string]]  # "name@ver" -> deps
    var installed: seq[(string, string)]    # (name, ver)
    var explicitRoots: HashSet[string]      # name@ver the user installed directly
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      let ver = row["version"].strVal
      installed.add((name, ver))
      if row.hasKey("root") and row["root"].boolVal:
        explicitRoots.incl(name & "@" & ver)
      var deps: seq[string]
      try:
        for dep in parseJson(row["deps"].jsonVal):
          deps.add(dep["name"].getStr & "@" & dep["version"].getStr)
      except CatchableError:
        discard
      depsOf[name & "@" & ver] = deps

    # roots = packages the user explicitly installed (not transitive deps).
    # Without this, orphaned transitive deps would become pseudo-roots and
    # survive pruning after their parent is removed.
    var roots: seq[string]
    for key in explicitRoots:
      roots.add(key)

    # BFS from roots -> reachable set
    var reachable: HashSet[string]
    var queue = roots
    while queue.len > 0:
      let key = queue.pop()
      if key in reachable: continue
      reachable.incl(key)
      if depsOf.hasKey(key):
        for d in depsOf[key]:
          if d notin reachable:
            queue.add(d)

    var removed = 0
    for (name, ver) in installed:
      let key = name & "@" & ver
      if key in reachable: continue
      let dir = cluePkgsPath / name / ver
      if dirExists(dir):
        removeDir(dir)
      let parentDir = cluePkgsPath / name
      if dirExists(parentDir):
        var hasEntries = false
        for e in walkDir(parentDir):
          hasEntries = true
          break
        if not hasEntries:
          removeDir(parentDir)
      for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
        if row["version"].strVal == ver:
          discard clueDB.deleteRow("installed", pk)
          inc removed
          if verbose:
            display("  removed " & name & "@" & ver)
          break
    if removed > 0:
      clueDB.checkpoint()
      if verbose:
        displaySuccess("Pruned " & $removed & " orphaned package(s)")
    else:
      if verbose:
        displayInfo("No orphaned packages to prune")

proc installedCount*(): int =
  withClueDB do:
    var n = 0
    for (pk, row) in clueDB.getTable("installed").get().allRows():
      inc n
    result = n
