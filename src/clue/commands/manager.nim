# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, sets, strformat, strutils,
          times, os, osproc, terminal, strtabs, algorithm]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]

import ../pkgmanager/resolver
import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/nimbleparser
import ../pkgmanager/builder
import ../pkgmanager/lockfile
import ./nimscript
import ./sources
import datpkgr/operations as datpkgrOps
import datpkgr/config as datpkgrConfig
import datpkgr/types as datpkgrTypes
import datpkgr/store as datpkgrStore

proc pkgNameFromUrl*(url: string): string =
  ## Derive a package name from a git URL's repository basename.
  var u = url.strip()
  for sep in ['#', '?']:
    let pos = u.find(sep)
    if pos >= 0:
      u = u[0 ..< pos]
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  u = u.replace("://", "/")
  u = u.replace("git@", "")
  u = u.replace(":", "/")
  for part in u.split('/'):
    if part.len > 0:
      result = part
  if result.endsWith(".git"):
    result = result[0 ..< ^4]

var pkgNameForUrlCache = initTable[string, string]()
  ## `pkgNameForUrl` answers from the registry, which means a store open per
  ## miss. Dependency lists repeat the same few URLs, so remember the misses
  ## too — the answer cannot change within a process.

proc pkgNameForUrl*(url: string): string =
  ## The package name a repository URL provides.
  ##
  ## A repository and the package inside it need not share a name:
  ## `github.com/supranim/tasks` ships `supranim_tasks.nimble`. So the registry
  ## is asked first, and only an unknown URL falls back to the basename — a
  ## private or unpublished repo, where the manifest is the only authority and
  ## the install path reads it.
  ##
  ## Guessing wrong here fails late and confusingly. datpkgr installs under the
  ## real name, so the guessed name is simply never recorded; the caller's
  ## dependency list keeps holding it, and the next step looks *that* up in the
  ## registry and reports the package as missing while it sits installed.
  let key = datpkgrStore.normalizeRepoUrl(url)
  if key.len == 0:
    return ""
  if pkgNameForUrlCache.hasKey(key):
    return pkgNameForUrlCache[key]
  let registered = datpkgrStore.pkgNameForUrl(getClueCfg(), url)
  result = if registered.len > 0: registered else: pkgNameFromUrl(url)
  pkgNameForUrlCache[key] = result

proc depName(d: NimbleDependency): string =
  ## The registry name for a dependency. URL deps (no name, only a `url`) are
  ## resolved against the registry, falling back to the repository basename.
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameForUrl(d.url)
  else: ""

proc depName(d: PkgDependency): string =
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameForUrl(d.url)
  else: ""

proc parseFeatureFlags*(s: string): seq[string] =
  for f in s.split(','):
    let ff = f.strip()
    if ff.len > 0:
      result.add(ff)

proc isGitUrl*(s: string): bool =
  s.startsWith("https://") or s.startsWith("http://") or
  s.startsWith("git@") or s.startsWith("git+") or
  s.startsWith("ssh://")

proc pluralize*(n: int, singular: string): string =
  ## `pluralize(1, "version")` → "version"; `pluralize(2, "version")` → "versions".
  singular & (if n == 1: "" else: "s")

proc fetchEventText(name: string, count: int, cached: bool): string =
  ## Live event text for version discovery of `name`: `<name> (cached)` on a
  ## cache hit, `<name> using HEAD` when the repo has no semver tags, otherwise
  ## `<name> (N version(s))`.
  if cached:
    result = name & " (cached)"
  elif count == 0:
    result = "fetched " & name & " using HEAD"
  else:
    result = "fetched " & name & " (" & $count & " " & pluralize(count, "version") & ")"

proc installPackage*(pkgName: string, pkgRef: string = "", refresh = false,
    features: seq[string] = @[], verbose = true, url = "",
    doBuild = false, buildRelease = true, buildDebug = false,
    constraint: VersionConstraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0)),
    backend = "c", sourceFilter: string = "", suppressSummary = false,
    depsOnly = false, showTree = true,
    directRoots: seq[datpkgrOps.ClosureRoot] = @[]) =
  ## Thin wrapper around datpkgr/operations.installPackage.
  ## Builder (`builder.nim`) stays in clue and is injected via buildHook.
  ## With `depsOnly` only the dependency closure is installed, never the
  ## requested package itself.
  ## With `directRoots` the whole closure of those dependencies is installed in
  ## a single resolution pass; `pkgName` is then only a label.
  let cfg = getClueCfg()
  devShadowWarningsEnabled = verbose
  let buildHook =
    if doBuild:
      proc(pkgName2: string, preferRef: string, backend2: string): bool =
        buildInstalled(pkgName2, buildRelease, buildDebug, verbose,
          preferRef = preferRef, nimFlags = extras, backend = backend2)
    else: nil
  let ok = datpkgrOps.installPackage(cfg, pkgName, pkgRef, refresh, features, verbose, url,
                                        doBuild, buildRelease, buildDebug, constraint,
                                        backend, sourceFilter, buildHook, suppressSummary,
                                        depsOnly, showTree, directRoots)
  if not ok:
    # datpkgr already logged; keep CLI exit
    # semantics (original called quit(1) on fail)
    quit(1)

proc installCommand*(v: Values) =
  let raw = if v.has("pkg"): v.get("pkg").getStr else: ""
  let refresh = v.has("--refresh")
  let verbose = v.has("--verbose")
  devShadowWarningsEnabled = verbose
  let doBuild = v.has("--build")
  let buildDebug = v.has("--debug")
  let buildRelease = not buildDebug
  let backend = if v.has("-b"): v.get("-b").getAny else: "c"
  let sourceFilter = if v.has("--source"): v.get("--source").getStr else: ""
  # Registry auto-refresh is deliberately *not* done up front: fetching
  # packages.json is a multi-megabyte GET, and a closure that already resolves
  # from local state (develop checkouts, install records, the versions DB)
  # needs none of it. Callers invoke this only once they know something is
  # genuinely unresolvable locally. Failures only warn (see sources.nim).
  proc ensureFreshRegistryIfStale() =
    ensureFreshRegistry(sourceFilter)
  let depsOnly = v.has("--depsOnly")
  var features: seq[string]
  if v.has("--features"):
    features = parseFeatureFlags(v.get("--features").getStr)
  
  if raw.len == 0:
    # Local install: `clue install` (no <pkg>) — source is the project
    # readonly disk, destination is the clue disk.
    # Two disks: projectFs (readonly, getCurrentDir()) and clue disk.
    let projectFs = newProjectDisk()
    let nimblePath = findNimbleFile(getCurrentDir(), getClueCfg(), projectFs)
    if nimblePath.len == 0:
      displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
      return

    let nimble = parseNimbleFile(nimblePath)
    let pkgName = nimblePath.extractFilename.changeFileExt("")

    checkNimConstraint(nimble)

    if not depsOnly:
      # Before install hook
      discard runNimscriptHook(nimblePath, "install", before=true)

      let version = if nimble.version.len > 0: nimble.version else: "0.0.0"
      let verDir = cluePkgsPath / pkgName / version
      safeRemoveDir(verDir)
      # Copy via project disk -> clue disk. Uses new LocalDriver API
      # `copyFromHost` if needed; installCleanCopy now operates between disks.
      # For now, installCleanCopy still takes host paths; projectFs ensures
      # the .nimble was found on the readonly disk.
      nimbleparser.installCleanCopy(getCurrentDir(), verDir, nimble)
      var deps: seq[DepEntry]
      for d in nimble.requires:
        if d.isNim: continue
        deps.add((depName(d), ""))
      recordInstall(pkgName, version, deps, root = true,
        features = @[], installPath = verDir)
      displaySuccess("Installed " & pkgName & "@" & version & " to " & verDir)
    # Immediate mode: per-package lines stream from inside `installPackage`
    # (clone/fetch/install start + finish). Emit one header up front, then
    # only a summary count afterwards — no post-hoc bulk re-print.
    var localDirect: seq[string]
    var localDepLabels: seq[string]
    var localSeen = initHashSet[string]()
    var localHeaderEmitted = false
    proc ensureLocalHeader() =
      if not localHeaderEmitted:
        displayInfo("Installing packages...")
        localHeaderEmitted = true
    proc displayLbl(lbl: string, cached = false) =
      let msg = "  " & lbl
      let headIdx = msg.find("#HEAD")
      if headIdx >= 0:
        let prefix = msg[0 ..< headIdx]
        let suffix = if headIdx + 5 < msg.len: msg[headIdx + 5 .. ^1] else: ""
        var parts = @[span(prefix, DefaultTextFg, indentSize = 0),
                      span("#HEAD", fgYellow, indentSize = 0),
                      span(suffix, DefaultTextFg, indentSize = 0)]
        if cached:
          parts.add(span(" (cached)", fgCyan, indentSize = 0))
        display(parts)
      else:
        let atIdx = msg.find("@")
        if atIdx >= 0:
          let prefix = msg[0 .. atIdx]
          let verPart = if atIdx + 1 < msg.len: msg[atIdx+1 .. ^1] else: ""
          var parts = @[span(prefix, DefaultTextFg, indentSize = 0),
                        span(verPart, indentSize = 0)]
          if cached:
            parts.add(span(" (cached)", fgCyan, indentSize = 0))
          display(parts)
        elif cached:
          display(@[span(msg, DefaultTextFg, indentSize = 0),
                    span(" (cached)", fgCyan, indentSize = 0)])
        else:
          display(msg)
    proc fmtLbl(name, ver: string): string =
      if ver.len == 0 or ver == "0.0.0" or ver == name:
        return name & "#HEAD"
      try:
        discard parseVersion(ver)
        return name & "@" & ver
      except CatchableError:
        return name & "#HEAD"
    proc emitLbl(lbl: string, cached: bool) =
      if lbl notin localSeen:
        localSeen.incl(lbl)
        localDepLabels.add(lbl)
        ensureLocalHeader()
        displayLbl(lbl, cached)
    proc installedBitsPresent(dep, recVersion, recPath: string): bool =
      ## True when an installed-manifest row's bits are usable as-is. A
      ## develop checkout counts: the live source *is* the install, and its
      ## recorded install dir (under the registry) deliberately holds no files.
      if isDevelopAvailable(dep):
        return true
      let verDir = cluePkgsPath / dep / recVersion
      dirExists(verDir) or (recPath.len > 0 and dirExists(recPath))
    # One snapshot of the installed manifest drives the whole analysis below.
    # Reading per package name instead re-opens the stores (exclusive
    # cross-process lock + WAL replay) and fsyncs them on close, once per
    # package per question — which is what made this loop crawl.
    let snap = installedSnapshot()

    proc isInstalledOnDisk(s: InstalledSnapshot, name: string): bool =
      ## Any installed-manifest row for `name` whose install dir exists on
      ## disk. Matches semver rows, `HEAD`/ref rows and develop rows alike —
      ## a db entry for an existing dir means the bits are reusable as-is.
      if isDevelopAvailable(name):
        return true
      for rec in s.records.getOrDefault(name, @[]):
        if rec.version.len == 0:
          continue
        if installedBitsPresent(name, rec.version, rec.path):
          return true
      false
    proc labelVer(s: InstalledSnapshot, name: string): string =
      ## Version to render in a label for `name`, from the snapshot. "" renders
      ## as `name#HEAD`, which is what a develop checkout (no registry version)
      ## and a tagless install both are.
      if isDevelopAvailable(name):
        return ""
      var bestVer = newVersion(0, 0, 0)
      var best = ""
      var fallback = ""
      for rec in s.records.getOrDefault(name, @[]):
        if not installedBitsPresent(name, rec.version, rec.path):
          continue
        if fallback.len == 0:
          fallback = rec.version
        try:
          let v = parseVersion(rec.version)
          if v > bestVer:
            bestVer = v
            best = rec.version
        except CatchableError:
          discard
      if best.len > 0: best else: fallback
    proc closureNames(s: InstalledSnapshot, roots: seq[string]): seq[string] =
      ## Reachable names in the recorded closure of `roots`, BFS'd over the
      ## snapshot's dep edges — no extra store round-trips.
      var visited = initHashSet[string]()
      var queue = roots
      while queue.len > 0:
        let name = queue.pop()
        if name in visited:
          continue
        visited.incl(name)
        for d in s.depsOf.getOrDefault(name, @[]):
          if d notin visited:
            queue.add(d)
      toSeq(visited)
    proc emitTransitives(print: bool) =
      ## Tally the recorded closure of every direct dep, and print its labels
      ## when `print`. Re-reads the snapshot because the install pass may have
      ## added versions.
      ##
      ## Always tallies even when silent: the `Installed N packages` summary is
      ## derived from the tally, and on `--verbose` datpkgr's dependency tree
      ## takes over the rendering.
      let post = installedSnapshot()
      for tdep in closureNames(post, localDirect):
        let lbl = fmtLbl(tdep, labelVer(post, tdep))
        if lbl notin localSeen:
          localSeen.incl(lbl)
          localDepLabels.add(lbl)
          if print:
            ensureLocalHeader()
            displayLbl(lbl, isInstalledOnDisk(post, tdep))
    proc installedVersionForReuse(s: InstalledSnapshot, dep: string, refStr: string,
        constraint: VersionConstraint): string =
      ## Installed version of `dep` reusable as-is (record exists and the
      ## install dir is on disk), else "". Ref-pinned deps (branch/tag, incl.
      ## HEAD installs recorded under their ref) match by ref; semver deps
      ## match the newest record satisfying the nimble constraint.
      var bestVer = newVersion(0, 0, 0)
      for rec in s.records.getOrDefault(dep, @[]):
        if rec.version.len == 0:
          continue
        if refStr.len > 0:
          if rec.version != refStr:
            continue
        else:
          var v: Version
          try: v = parseVersion(rec.version)
          except CatchableError: continue
          if not v.satisfies(constraint):
            continue
          if result.len > 0 and cmp(v, bestVer) <= 0:
            continue
          bestVer = v
        if installedBitsPresent(dep, rec.version, rec.path):
          if refStr.len > 0:
            return rec.version
          result = rec.version
    proc closureOnDisk(s: InstalledSnapshot, dep: string): bool =
      ## Every package in `dep`'s recorded closure has an installed-manifest
      ## row with an existing dir (roots included — `HEAD`/ref rows count).
      for name in closureNames(s, @[dep]):
        if not isInstalledOnDisk(s, name):
          return false
      true

    # Label every direct dep *before* the work starts, so a slow resolve shows
    # the package it is stuck on instead of a silent pause. `(cached)` means
    # the local bits are already good — no clone, no fetch.
    var directRoots: seq[datpkgrOps.ClosureRoot]
    var anyNeedsRemote = false
    for d in nimble.requires:
      if d.isNim: continue
      let dep = depName(d)
      if dep.len == 0:
        displayWarning("Cannot derive package name from URL: " & d.url & " - skipping")
        continue
      if dep in localDirect: continue
      localDirect.add(dep)
      ensureLocalHeader()
      let refStr = if d.branch.len > 0: d.branch elif d.tag.len > 0: d.tag else: ""
      directRoots.add(datpkgrOps.ClosureRoot(name: dep, constraint: d.constraint,
        features: d.features, url: d.url, refStr: refStr))
      var reused = ""
      if not refresh:
        reused = installedVersionForReuse(snap, dep, refStr, d.constraint)
        if reused.len > 0 and not closureOnDisk(snap, dep):
          reused = ""
      if reused.len == 0:
        anyNeedsRemote = true
      let lblVer = if reused.len > 0: reused else: refStr
      emitLbl(fmtLbl(dep, lblVer), reused.len > 0)
    # One resolution + install pass for the whole closure. Reused deps ride
    # along: the pass re-records them (cheap, local) and would otherwise risk
    # pruning a closure whose roots were filtered out.
    if directRoots.len > 0:
      if anyNeedsRemote:
        ensureFreshRegistryIfStale()
      installPackage(pkgName, "", refresh, @[], verbose,
        suppressSummary = true, showTree = verbose, directRoots = directRoots)
    # The tree covers the closure on `--verbose`; otherwise print the flat
    # labels. Either way the tally runs so the summary count stays right.
    emitTransitives(not verbose)
    if localDepLabels.len > 0:
      displaySuccess("Installed " & $localDepLabels.len & " " & pluralize(localDepLabels.len, "package"))
    if doBuild and not depsOnly:
      if not buildInstalled(pkgName, buildRelease, buildDebug, verbose,
          nimFlags = extras, backend = backend):
        return

    if not depsOnly:
      # After install hook
      discard runNimscriptHook(nimblePath, "install", before=false)
    # The dependency closure changed — drop any stale `clue.lock` so the
    # next build re-resolves instead of reusing pinned versions.
    invalidateLock(nimblePath.parentDir())
    return

  if isGitUrl(raw):
    # `https://host/owner/repo[#ref]` installs straight from git.
    # cloneRepo will try SSH first (for private repos) then fall back to HTTPS.
    var url = raw
    var urlRef = ""
    let hashPos = url.find('#')
    if hashPos >= 0:
      urlRef = url[hashPos + 1 .. ^1]
      url = url[0 ..< hashPos]
    let name = pkgNameFromUrl(url)
    if name.len == 0:
      displayError("Could not derive a package name from: " & raw, quitProcess = true)
      return
    # A URL install always goes to the network, so stale registry metadata is
    # worth refreshing up front.
    ensureFreshRegistryIfStale()
    installPackage(name, urlRef, refresh, features, verbose, url = url,
            doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug,
            backend = backend, sourceFilter = sourceFilter, depsOnly = depsOnly)
  else:
    let pkgInput = split(raw, "@")
    let pkgName = pkgInput[0]
    let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
    if not refresh:
      # Already installed with a complete closure on disk: no resolve, no
      # fetch — reuse the bits as-is. `--refresh` and git-URL installs
      # always take the full path below.
      let reused = installedVersionForReuse(pkgName, pkgRef)
      if reused.len > 0 and closureOnDisk(pkgName):
        markInstalledRoot(pkgName, reused)
        displaySuccess("Installing packages...")
        var isSemver = true
        try: discard parseVersion(reused)
        except CatchableError: isSemver = false
        if isSemver:
          display(@[span("  " & pkgName & "@", DefaultTextFg, indentSize = 0),
                    span(reused, indentSize = 0),
                    span(" (cached)", fgCyan, indentSize = 0)])
        else:
          display(@[span("  " & pkgName & "#" & reused, DefaultTextFg, indentSize = 0),
                    span(" (cached)", fgCyan, indentSize = 0)])
        displaySuccess("Installed 1 package")
        if doBuild:
          if not buildInstalled(pkgName, buildRelease, buildDebug, verbose,
              nimFlags = extras, backend = backend):
            return
        return
    ensureFreshRegistryIfStale()
    installPackage(pkgName, pkgRef, refresh, features, verbose,
          doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug,
          backend = backend, sourceFilter = sourceFilter, depsOnly = depsOnly)
    # Dependency versions on disk may have moved — the project lock (if any)
    # pins the previous resolution, so drop it for a clean re-resolve.
    try: invalidateLock(getCurrentDir())
    except CatchableError: discard
  # except CatchableError as e:
  #   echo "EXCEPTION in installCommand: ", e.msg
  #   echo getStackTrace(e)
  #   quit(1)

proc updateCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.updateAllPackages / updatePackage.
  ## Parallelism (install-time thread pool) lives in datpkgr/pool.
  let verbose = v.has("--verbose")
  let cfg = getClueCfg()
  if v.has("pkg"):
    let ok = datpkgrOps.updatePackage(cfg, v.get("pkg").getStr, verbose)
    if not ok: quit(1)
  else:
    let exe = getAppFilename()
    let ok = datpkgrOps.updateAllPackages(cfg, verbose, exe)
    if not ok: quit(1)
  # Installed versions moved — drop the project lock so the next build
  # re-resolves instead of reusing the previous pins.
  try: invalidateLock(getCurrentDir())
  except CatchableError: discard

proc developCommand*(v: Values) =
  ## Thin wrapper around datpkgr/operations.developPackage (generic Manifest).
  let cfg = getClueCfg()
  let dir = getCurrentDir()
  let ok = datpkgrOps.developPackage(cfg, dir)
  if not ok:
    quit(1)
  # ops logs via cfg.logInfo (plain); emit styled success for CLI consistency
  # (avoid double-line by not re-logging generic message – only styled)
  discard

proc versionsCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.versionsFor
  let pkgName = v.get("pkg").getStr
  let cfg = getClueCfg()
  let versions = datpkgrOps.versionsFor(cfg, pkgName, v.has("--refresh"))
  if versions.len == 0:
    # versionsFor already logged if not found; check if we need extra message
    let metaOpt = fetchPkgMeta(pkgName)
    if metaOpt.isNone:
      displayError("Package not found in registry: " & pkgName, quitProcess = true)
      return
    displayInfo("No semver tags found for " & pkgName)
    return
  displayInfo("Available versions for " & pkgName & ":")
  for ver in versions:
    echo "  " & $ver.version

proc pruneCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.prunePackages
  datpkgrOps.prunePackages(getClueCfg())

proc fetchCommand*(v: Values) =
  ## Wrapper around datpkgr/operations.fetchRegistry
  if not datpkgrOps.fetchRegistry(getClueCfg()):
    quit(1)

template whenPackageExists(pkgName: string, body: untyped): untyped =
  let pkgBase = cluePkgsPath / pkgName
  var hasInstalled = false
  if dirExists(pkgBase):
    for entry in walkDir(pkgBase):
      if entry.kind == pcDir:
        hasInstalled = true
        break
  if not hasInstalled:
    hasInstalled = resolveInstalledPath(pkgName, "").len > 0
  # Self-scoped (nesting is free): valid regardless of caller scope.
  var hasRegistry = false
  withClueDB do:
    hasRegistry = clueDB.getTable("packages")
                          .get()
                          .where("name", newTextValue(pkgName))
                          .toSeq()
                          .len > 0
  if hasInstalled or hasRegistry:
    block:
      `body`
  else:
    displayError("Package not found: " & cyan(pkgName), quitProcess = true)

proc uninstallCommand*(v: Values) =
  let pkgInput = split(v.get("pkg").getStr, "@")
  let pkgName = pkgInput[0]
  let pkgVersion = if pkgInput.len > 1: pkgInput[1] else: ""
  let cfg = getClueCfg()
  proc confirm(msg: string): bool =
    promptConfirm(msg)
  let ok = datpkgrOps.uninstallPackage(cfg, pkgName, pkgVersion, confirm)
  if not ok:
    quit(1)

proc renderDepSpec(d: NimbleDependency): string =
  ## `"name >= 1.2.3"` — or just the name when the constraint is any (`*`).
  let c = $d.constraint
  if c == "*": d.name else: d.name & " " & c

proc buildLocalNimbleInfo(nimblePath: string): JsonNode =
  ## JSON details parsed from a .nimble file (used by both dump modes).
  let nimble = parseNimbleFile(nimblePath)
  result = %*{
    "name": nimblePath.extractFilename.changeFileExt(""),
    "version": nimble.version,
    "author": nimble.author,
    "description": nimble.description,
    "license": nimble.license,
    "srcDir": nimble.srcDir,
    "binDir": nimble.binDir,
    "bin": %nimble.bin,
    "installDirs": %nimble.installDirs,
    "installFiles": %nimble.installFiles,
    "installExt": %nimble.installExt,
    "skipDirs": %nimble.skipDirs,
    "skipFiles": %nimble.skipFiles,
    "skipExt": %nimble.skipExt,
  }
  var reqArr = newJArray()
  for dep in nimble.requires:
    reqArr.add(%renderDepSpec(dep))
  result["requires"] = reqArr
  var tasksArr = newJArray()
  for (tname, tdesc) in nimble.tasks:
    tasksArr.add(%{"name": %tname, "description": %tdesc})
  result["tasks"] = tasksArr

proc dumpCommand*(v: Values) =
  ## Dump package info from the registry, its available versions and recent
  ## git activity (latest commit hash/date/author) — `--refresh` re-reads
  ## versions from the remote instead of the local cache.
  ## With no argument, dumps the current directory's .nimble file.
  let pkgName =
    if v.has("pkg"): v.get("pkg").getStr
    else: ""
  if pkgName.len == 0:
    # Local dump: parse the .nimble file in the current directory (readonly project disk).
    let projectFs = newProjectDisk()
    let nimblePath = findNimbleFile(getCurrentDir(), getClueCfg(), projectFs)
    if nimblePath.len == 0:
      displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
      return
    echo pretty(buildLocalNimbleInfo(nimblePath))
    return

  # Registry dump. JSON goes to stdout, so silence Info/Success logs for the
  # duration (on a fresh ~/.clue `initDatpkgr` logs "Initializing database..."
  # via displayInfo -> stdout, which breaks parseJson). Warn/Error stay on stderr.
  let dumpCfg = getClueCfg()
  let savedDumpLog = dumpCfg.callbacks.log
  dumpCfg.callbacks.log = proc(level: datpkgrConfig.LogLevel, msg: string) {.gcsafe.} =
    case level
    of datpkgrConfig.lvlWarn, datpkgrConfig.lvlError:
      try: stderr.writeLine(msg) except: discard
    else: discard
  try:
    withClueDB do:
      whenPackageExists pkgName:
        let res = clueDB.getTable("packages")
                          .get()
                          .where("name", newTextValue(pkgName))
                          .toSeq()
        if res.len > 0:
          var pkgData = res[0]
          var pkgInfo = %*{
            "method": pkgData[1]["method"].strVal,
            "name": pkgData[1]["name"].strVal,
            "url": pkgData[1]["url"].strVal,
            "description": pkgData[1]["description"].strVal,
            "web": pkgData[1]["web"].strVal,
            "license": pkgData[1]["license"].strVal,
            "tags": fromJson(pkgData[1]["tags"].jsonVal)
          }
          # available versions (newest first)
          let versions = discoverVersions(pkgName, pkgData[1]["url"].strVal,
            v.has("--refresh"), cloneOnMiss = false)
          var verArr = newJArray()
          for dv in versions:
            verArr.add(%($dv.version))
          pkgInfo["versions"] = verArr
          # Embed the dumped package's own .nimble details (from its installed
          # registry copy) when available.
          let pkgDir = resolveInstalledPath(pkgName, "")
          if pkgDir.len > 0:
            let pkgNimble = findNimbleFile(pkgDir, getClueCfg())
            if pkgNimble.len > 0:
              pkgInfo["nimble"] = buildLocalNimbleInfo(pkgNimble)
          echo pretty(pkgInfo)
        else:
          # installed-only (e.g. direct URL before packages row existed) — dump from installed
          let pkgDir = resolveInstalledPath(pkgName, "")
          if pkgDir.len > 0:
            let pkgNimble = findNimbleFile(pkgDir, getClueCfg())
            var pkgInfo: JsonNode
            if pkgNimble.len > 0:
              pkgInfo = buildLocalNimbleInfo(pkgNimble)
              pkgInfo["installedAt"] = %pkgDir
            else:
              pkgInfo = %*{"name": pkgName, "installedAt": pkgDir}
            echo pretty(pkgInfo)
          else:
            displayError("Package not found: " & cyan(pkgName), quitProcess = true)
  finally:
    dumpCfg.callbacks.log = savedDumpLog


type
  ChoosenimInfo = object
    selected: string
    channel: string
    path: string
    versions: seq[string]

proc stripAnsi(s: string): string =
  ## Remove common ANSI escape sequences (SGR / CSI sequences like "\x1b[...m")
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\x1b': # escape char
      inc(i)
      if i < s.len and s[i] == '[':
        inc(i)
        # skip until final byte (usually a letter like 'm')
        while i < s.len and not (s[i].isAlphaAscii):
          inc(i)
        if i < s.len:
          inc(i)
      else:
        # skip single-char escape if present
        if i < s.len: inc(i)
      continue
    else:
      result = result & $c
      inc(i)

proc parseChoosenimShow(output: string): ChoosenimInfo =
  # Parse the output of `choosenim show`
  result = ChoosenimInfo()
  for line in output.splitLines():
    let trimmed = stripAnsi(line).strip()
    if trimmed.startsWith("Selected:"):
      result.selected = trimmed.replace("Selected:", "").strip()
    elif trimmed.startsWith("Channel:"):
      result.channel = trimmed.replace("Channel:", "").strip()
    elif trimmed.startsWith("Path:"):
      result.path = trimmed.replace("Path:", "").strip()
    elif trimmed.len > 0 and not trimmed.startsWith("Versions:"):
      # Version lines may start with `*` (active) or spaces
      let v = trimmed.replace("*", "").strip()
      if v.len > 0:
        result.versions.add(v)

proc getChoosenimInfo(): Option[ChoosenimInfo] =
  # Run `choosenim show` and parse the output
  let (output, exitCode) = execCmdEx("choosenim show")
  if exitCode != 0:
    return none(ChoosenimInfo)
  some(parseChoosenimShow(output))

proc getNimVersionPath(choosenimHome: string, version: string): string =
  ## Resolve the absolute path to a specific Nim version toolchain
  choosenimHome / "toolchains" / ("nim-" & version)

proc venvCommand*(v: Values) =
  ## Create a virtual environment for a Nim package
  let requestedVersion = v.get("--nim").getStr
  if requestedVersion.len == 0:
    displayError("Please specify a Nim version: --nim:<version>", quitProcess = true)
    return

  # Check choosenim availability and installed versions
  let choosenimInfoOpt = getChoosenimInfo()
  if choosenimInfoOpt.isNone:
    displayError("`choosenim` is not installed or not available in PATH.", quitProcess = true)
    return

  let choosenimInfo = choosenimInfoOpt.get()

  # Validate requested version is installed
  if requestedVersion notin choosenimInfo.versions:
    displayError("Nim version " & cyan(requestedVersion) & " is not installed.", quitProcess = true)
    displayInfo("Installed versions: " & choosenimInfo.versions.join(", "))
    displayInfo("Install it with: choosenim " & requestedVersion)
    return

  # Resolve the choosenim home directory
  let choosenimHome =
    if choosenimInfo.path.len > 0:
      # e.g. /Users/user/.choosenim/toolchains/nim-2.2.0 -> /Users/user/.choosenim
      choosenimInfo.path.parentDir().parentDir()
    else:
      getHomeDir() / ".choosenim"

  let nimVersionPath = getNimVersionPath(choosenimHome, requestedVersion)
  if not dirExists(nimVersionPath):
    displayError("Toolchain path not found: " & nimVersionPath, quitProcess = true)
    displayInfo("Try reinstalling with: choosenim " & requestedVersion)
    return

  let nimBinPath = nimVersionPath / "bin"
  let currentDir = getCurrentDir()
  let venvDir = currentDir / ".env"
  let configFile = venvDir / "venv.json"

  # Create venv directory
  if dirExists(venvDir):
    displayInfo("Virtual environment already exists at: " & cyan(venvDir))
    let overwrite = promptConfirm("Overwrite existing virtual environment?")
    if not overwrite:
      return
  else:
    createDir(venvDir)

  # Build venv config
  let pkgName = currentDir.lastPathPart()
  let nimblePkgsPath = venvDir / "pkgs"
  discard existsOrCreateDir(nimblePkgsPath)

  let config = %*{
    "nim_version": requestedVersion,
    "nim_path": nimVersionPath,
    "nim_bin": nimBinPath,
    "package": pkgName,
    "created_at": $now(),
    "paths": {
      "venv": venvDir,
      "pkgs": nimblePkgsPath
    },
    "env": {
      "PATH": nimBinPath & ":" & getEnv("PATH"),
      "NIMBLE_DIR": nimblePkgsPath
    }
  }

  writeFile(configFile, pretty(config))

  # Write the activation and deactivation scripts
  let activateScript = venvDir / "activate"
  let deactivateScript = venvDir / "deactivate"
  let activateContents = """
#!/bin/sh
# Nimbox virtual environment activation script
# Generated by clue venv

TARGET_VENV="__VENVDIR__"

# If this venv is already active in this shell, do nothing.
if [ "$CLUE_VENV" = "$TARGET_VENV" ]; then
  echo "Nimbox venv already activated: $TARGET_VENV"
  return 0
fi

CLUE_VENV="$TARGET_VENV"
export CLUE_VENV

# Save previous environment only if not already saved (prevents double-save)
if [ -z "$_CLUE_OLD_PATH" ]; then
  export _CLUE_OLD_PATH="$PATH"
fi
if [ -z "$_CLUE_OLD_NIMBLE_DIR" ]; then
  export _CLUE_OLD_NIMBLE_DIR="$NIMBLE_DIR"
fi

# Prompt customization: prefer env var, then .clue_prompt file, then default
if [ -z "$CLUE_PROMPT" ]; then
  if [ -f "$CLUE_VENV/.clue_prompt" ]; then
    CLUE_PROMPT="$(cat "$CLUE_VENV/.clue_prompt")"
  else
    CLUE_PROMPT="➜ __PKG__"
  fi
fi
export CLUE_PROMPT

# Save and set shell prompt for zsh/bash (falls back to PS1); only save once
if [ -n "$ZSH_VERSION" ]; then
  if [ -z "$_CLUE_OLD_PROMPT" ]; then
    export _CLUE_OLD_PROMPT="$PROMPT"
    PROMPT="$CLUE_PROMPT $PROMPT"
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -z "$_CLUE_OLD_PS1" ]; then
    export _CLUE_OLD_PS1="$PS1"
    PS1="$CLUE_PROMPT $PS1"
  fi
else
  if [ -z "$_CLUE_OLD_PS1" ]; then
    export _CLUE_OLD_PS1="$PS1"
    PS1="$CLUE_PROMPT $PS1"
  fi
fi

# Set venv-specific vars
export CLUE_dir="$CLUE_VENV/pkgs"
export NIMBLE_DIR="$CLUE_VENV/pkgs"
export PATH="__NIMBIN__:$PATH"

echo "Nimbox venv activated (Nim __VERSION__)"
echo "  Nim bin : __NIMBIN__"
echo "  Pkgs dir: $NIMBLE_DIR"
echo ""
echo "To switch back, run:"
echo "  source .env/deactivate"
"""

  let deactivateContents = """
#!/bin/sh
# Nimbox virtual environment deactivation script
# Generated by clue venv

TARGET_VENV="__VENVDIR__"

# If this venv is not active in this shell, do nothing.
if [ -z "$CLUE_VENV" ] || [ "$CLUE_VENV" != "$TARGET_VENV" ]; then
  echo "Nimbox venv not active for this directory: $TARGET_VENV"
  return 0
fi

# Restore previous PATH if present
if [ -n "$_CLUE_OLD_PATH" ]; then
  export PATH="$_CLUE_OLD_PATH"
  unset _CLUE_OLD_PATH
fi

# Restore previous NIMBLE_DIR or unset
if [ -n "$_CLUE_OLD_NIMBLE_DIR" ]; then
  export NIMBLE_DIR="$_CLUE_OLD_NIMBLE_DIR"
  unset _CLUE_OLD_NIMBLE_DIR
else
  unset NIMBLE_DIR
fi

# Restore prompt
if [ -n "$ZSH_VERSION" ]; then
  if [ -n "$_CLUE_OLD_PROMPT" ]; then
    PROMPT="$_CLUE_OLD_PROMPT"
    unset _CLUE_OLD_PROMPT
  fi
elif [ -n "$BASH_VERSION" ]; then
  if [ -n "$_CLUE_OLD_PS1" ]; then
    PS1="$_CLUE_OLD_PS1"
    unset _CLUE_OLD_PS1
  fi
else
  if [ -n "$_CLUE_OLD_PS1" ]; then
    PS1="$_CLUE_OLD_PS1"
    unset _CLUE_OLD_PS1
  fi
fi

unset CLUE_VENV
unset CLUE_PROMPT

echo "Nimbox venv deactivated"
"""

  # write activation/deactivation with embedded absolute venv path
  writeFile(activateScript,
    activateContents.replace("__NIMBIN__", nimBinPath)
                    .replace("__VERSION__", requestedVersion)
                    .replace("__PKG__", pkgName)
                    .replace("__VENVDIR__", venvDir))
  writeFile(deactivateScript, deactivateContents.replace("__VENVDIR__", venvDir))


  # write default per-venv prompt file (user can edit or set CLUE_PROMPT env var)
  let promptFile = venvDir / ".clue_prompt"
  if not fileExists(promptFile):
    writeFile(promptFile, "🜲 v" & requestedVersion)

  discard execCmdEx("chmod +x " & activateScript & " && chmod +x " & deactivateScript)

  displaySuccess("Virtual environment created at: " & cyan(venvDir))
  let outputMessage = fmt"""

To activate:
  `source .env/activate`

To deactivate (in the same shell), run:
  `source .env/deactivate`

Customize the prompt:
  - Edit .env/.clue_prompt to change the prefix (or set CLUE_PROMPT).
  - Activation will prepend that prefix to your current zsh/bash prompt.
"""
  displayInfo(outputMessage)
