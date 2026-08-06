# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue
import std/[os, osproc, strformat, strutils, algorithm, sets, tables, json, sequtils, options]
import pkg/semver
import pkg/kapsis/[runtime, interactive/prompts]
import ../features/pkgmanager/nimbleparser
import ../features/pkgmanager/configs
import ../features/pkgmanager/versions
import ./pkgmanager_commands

proc depNameOf(d: NimbleDependency): string =
  if d.name.len > 0: d.name else: d.url

proc installedCoversFeatures(name: string, feats: seq[string]): bool =
  ## True when the installed manifest for `name` was resolved with every
  ## requested feature (so `-d:features.<name>.<feat>` is meaningful).
  if feats.len == 0:
    return true
  let map = installedFeatures()
  if not map.hasKey(name):
    return false
  for f in feats:
    if f notin map[name]:
      return false
  true

proc collectTransitiveDepNames(rootNames: seq[string]): seq[string] =
  ## BFS over the installed manifest graph to collect every reachable
  ## dependency name, so the compiler gets `--path` for the whole tree.
  var depsOf: Table[string, seq[string]]
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.allRows():
      let name = row["name"].strVal
      var deps: seq[string]
      try:
        for dep in parseJson(row["deps"].jsonVal):
          deps.add(dep["name"].getStr)
      except CatchableError:
        discard
      if deps.len == 0: continue
      if not depsOf.hasKey(name):
        depsOf[name] = @[]
      for d in deps:
        if d notin depsOf[name]:
          depsOf[name].add(d)
  var visited = initHashSet[string]()
  var queue = rootNames
  while queue.len > 0:
    let name = queue.pop()
    if name in visited:
      continue
    visited.incl(name)
    if depsOf.hasKey(name):
      for d in depsOf[name]:
        if d notin visited:
          queue.add(d)
  toSeq(visited)

proc findNimbleFile(dir: string): string =
  ## Locate a .nimble file in the given directory.
  for f in walkFiles(dir / "*.nimble"):
    if f.extractFilename != "nim.nimble":
      return f
  ""

proc srcDirPath(verDir, depName: string): string =
  ## Nim resolves `import pkg/<name>` to `<path>/<name>/<name>.nim`.
  ## For clue-installed packages (raw repo copies) the module often lives in
  ## a `srcDir` subdir, so point `--path` at the source dir when present.
  let nimblePath = verDir / depName.changeFileExt("nimble")
  if fileExists(nimblePath):
    try:
      let srcDir = parseNimbleFile(nimblePath).srcDir
      if srcDir.len > 0 and dirExists(verDir / srcDir):
        return verDir / srcDir
    except CatchableError:
      discard
  verDir

proc resolveDepPath(depName: string, preferRef = ""): string =
  ## Locate an installed dependency, preferring the dir for `preferRef`
  ## (branch/tag) when given, else the latest semver version.
  let clueInstall = cluePkgsPath / depName
  if dirExists(clueInstall):
    if preferRef.len > 0 and dirExists(clueInstall / preferRef):
      return srcDirPath(clueInstall / preferRef, depName)
    var dirs: seq[string] = @[]
    for entry in walkDir(clueInstall):
      if entry.kind == pcDir:
        dirs.add(entry.path.extractFilename)
    var best = ""
    var bestIsSemver = false
    for d in dirs:
      var isSemver = false
      try:
        discard parseVersion(d)
        isSemver = true
      except CatchableError:
        discard
      if best.len == 0:
        best = d
        bestIsSemver = isSemver
      elif isSemver and not bestIsSemver:
        best = d
        bestIsSemver = true
      elif isSemver == bestIsSemver:
        if isSemver:
          if parseVersion(d) > parseVersion(best): best = d
        elif d > best:
          best = d
    if best.len > 0:
      return srcDirPath(clueInstall / best, depName)
  ""

proc buildCommand*(v: Values) =
  let isRelease = v.has("--release")
  let isDebug = v.has("--debug")

  # Active root features: `--features:foo,bar` + the implicit `dev` feature
  # (always active when building a package, matching nimble).
  var activeRootFeatures: seq[string]
  if v.has("--features"):
    activeRootFeatures = parseFeatureFlags(v.get("--features").getStr)
  if "dev" notin activeRootFeatures:
    activeRootFeatures.add("dev")

  let pkgDir = getCurrentDir()
  let nimblePath = findNimbleFile(pkgDir)

  if nimblePath.len == 0:
    displayError("No .nimble file found in " & pkgDir)
    return

  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")

  if nimble.bin.len == 0:
    displayInfo("No binaries defined in " & nimblePath)
    return

  let srcDir =
    if nimble.srcDir.len > 0: nimble.srcDir
    else: "src"

  let binDir =
    if nimble.binDir.len > 0: nimble.binDir
    else: "bin"

  # Effective direct deps = hard requires + requires of active root features.
  var directDeps: seq[NimbleDependency] = nimble.requires
  for f in activeRootFeatures:
    if nimble.features.hasKey(f):
      for d in nimble.features[f]:
        directDeps.add(d)

  var pathFlags: seq[string]
  var processed = initHashSet[string]()

  # 1. Ensure direct deps are installed with the right features, resolving
  #    their paths. A dep already installed but lacking a requested feature
  #    is re-resolved so its manifest records the feature (→ defines).
  var directNames: seq[string]
  for dep in directDeps:
    if dep.isNim: continue
    let name = depNameOf(dep)
    let refStr = if dep.branch.len > 0: dep.branch elif dep.tag.len > 0: dep.tag else: ""
    var depPath = resolveDepPath(name, refStr)
    if depPath.len > 0 and not installedCoversFeatures(name, dep.features):
      displayInfo("Refreshing " & name & " (features: " & dep.features.join(", ") & ")")
      installPackage(name, refStr, false, dep.features)
      depPath = resolveDepPath(name, refStr)
    if depPath.len == 0:
      displayInfo("Dependency not installed, fetching: " & name)
      installPackage(name, refStr, false, dep.features)
      depPath = resolveDepPath(name, refStr)
    if depPath.len > 0:
      processed.incl(name)
      directNames.add(name)
      pathFlags.add("--path:" & depPath)
      display("  dep " & name & " → " & depPath)
    else:
      displayWarning("Dependency not found: " & name)

  # 2. Ensure the whole transitive closure is on the path, installing
  #    any transitive deps that are missing. Loop until the closure
  #    stops growing (installing one dep may pull in more).
  var changed = true
  while changed:
    changed = false
    for name in collectTransitiveDepNames(directNames):
      if name in processed:
        continue
      processed.incl(name)
      var depPath = resolveDepPath(name)
      if depPath.len == 0:
        displayInfo("Transitive dependency not installed, fetching: " & name)
        installPackage(name)
        depPath = resolveDepPath(name)
        changed = true
      if depPath.len > 0:
        pathFlags.add("--path:" & depPath)
        display("  dep " & name & " → " & depPath)
      else:
        displayWarning("Transitive dependency not found: " & name)

  # dedupe path flags while preserving order
  var seenFlags = initHashSet[string]()
  pathFlags = pathFlags.filterIt(block:
    if it in seenFlags:
      false
    else:
      seenFlags.incl(it)
      true)

  # feature defines so `when defined(features.<pkg>.<feat>)` works in code —
  # for the root package and every dependency with active features.
  var featureDefines = ""
  var definedFeats = initHashSet[string]()
  for f in activeRootFeatures:
    let d = " -d:features." & pkgName & "." & f
    if d notin definedFeats:
      definedFeats.incl(d)
      featureDefines.add(d)
  let featsMap = installedFeatures()
  for name in collectTransitiveDepNames(directNames):
    if featsMap.hasKey(name):
      for f in featsMap[name]:
        let d = " -d:features." & name & "." & f
        if d notin definedFeats:
          definedFeats.incl(d)
          featureDefines.add(d)

  discard existsOrCreateDir(pkgDir / binDir)

  for bin in nimble.bin:
    let srcFile = pkgDir / srcDir / bin.addFileExt("nim")
    let outFile = pkgDir / binDir / bin
    var flags = " " & pathFlags.join(" ") & featureDefines
    if isRelease:
      flags.add(" -d:release --opt:size")
    elif isDebug:
      flags.add(" --debugger:native")

    let cmd = &"nim c{flags} --out:{outFile} {srcFile}"
    display("  " & cyan(cmd))
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode == 0:
      displaySuccess("Built " & bin & " → " & outFile)
    else:
      displayError("Build failed for " & bin & ":\n" & output)
