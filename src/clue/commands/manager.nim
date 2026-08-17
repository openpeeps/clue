# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

import std/[sequtils, options, tables, sets, strformat, strutils,
          times, os, osproc, terminal, strtabs]

import pkg/[semver, openparser/json]
import pkg/kapsis/[runtime, interactive/prompts]
import pkg/malebolgia

import ../pkgmanager/resolver
import ../pkgmanager/configs
import ../pkgmanager/versions
import ../pkgmanager/nimbleparser
import ../pkgmanager/builder

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

proc depName(d: NimbleDependency): string =
  ## The registry name for a dependency. URL deps (no name, only a `url`) are
  ## resolved to their repository basename so the registry can be consulted.
  if d.name.len > 0: d.name
  elif d.url.len > 0: pkgNameFromUrl(d.url)
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

type
  InstallJob = object
    name: string
    cacheDir: string
    verDir: string
    refStr: string
    verStr: string
    refresh: bool
    label: string
    nimble: NimbleFile

proc installResolvedPkg(job: InstallJob): bool {.gcsafe.} =
  ## Thread-pool worker: checkout the resolved ref/tag in `_cache` and copy the
  ## package into the registry (flat, clean layout). Pure file/git ops — all
  ## paths and the parsed nimble are passed in, so it's safe on a thread pool.
  if job.refStr.len > 0:
    if not checkoutRef(job.cacheDir, job.refStr, job.refresh):
      return false
  elif job.verStr != "0.0.0":
    let tag = tagForVersion(job.cacheDir, job.verStr)
    if tag.len > 0:
      discard checkoutTag(job.cacheDir, tag)
  try:
    installCleanCopy(job.cacheDir, job.verDir, job.nimble)
    return true
  except CatchableError:
    return false

proc installPackage*(pkgName: string, pkgRef: string = "", refresh = false,
    features: seq[string] = @[], verbose = true, url = "",
    doBuild = false, buildRelease = true, buildDebug = false,
    constraint: VersionConstraint = VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))) =
  ## Install a package and its dependencies into ~/.clue/packages.
  ## Uses fast, cached version discovery and only installs versions that
  ## satisfy the resolved constraints. Prunes orphans afterwards.
  ## `features` activates the root package's `feature "name":` requires.
  ## `verbose` controls progress output (clue build calls it quietly).
  ## `url` bypasses the registry lookup and installs straight from a git URL.
  ## `doBuild` compiles the installed binaries (release by default) into
  ## ~/.clue/bin after the install — never done implicitly, since compiling a
  ## package executes its `{.compile.}` / `staticExec` code.
  ## `constraint` is the version constraint from the nimble `requires` line
  ## (e.g., `>= 0.1.9`). When `pkgRef` is empty and `constraint` is not `*`,
  ## the constraint is used as the root constraint for resolution.
  withClueDB do:
    let showProgress = verbose or isatty(stdout)
    proc progress(msg: string) =
      if showProgress: displayInfo(msg)
    proc warn(msg: string) =
      displayWarning(msg)
    proc fail(msg: string) =
      displayError(msg)
      quit(1)

    var rootMeta: PkgRef
    if url.len > 0:
      rootMeta = PkgRef(name: pkgName, url: url, refStr: "")
    else:
      let rootMetaOpt = fetchPkgMeta(pkgName)
      if rootMetaOpt.isNone:
        fail("Package not found in registry: " & pkgName)
        return
      rootMeta = rootMetaOpt.get()

    # 1. Ensure the root clone exists in _cache (full clone kept for install).
    #    Cloning happens only the first time; `--refresh` re-fetches the tags.
    let rootDest = cluePkgsCachePath / pkgName
    if not dirExists(rootDest):
      progress("fetching " & pkgName & "...")
      if not clonePackage(rootMeta.url, rootDest):
        fail("Failed to fetch " & pkgName)
        return
    else:
      progress("using cached " & pkgName)
      if refresh:
        discard clonePackage(rootMeta.url, rootDest, refresh = true)

    # 2. Root constraint: explicit semver ref, else latest (vcAny).
    #    Non-semver refs (git branches/tags via `pkg@ref` / `#ref`) install
    #    the ref directly. Feature refs (`pkg[feat]`) are NOT git refs.
    #    When a nimble `requires` constraint is provided (e.g., `>= 0.1.9`),
    #    it is used as the root constraint instead of vcAny.
    var rootConstraint = constraint
    if pkgRef.len > 0:
      try:
        rootConstraint = VersionConstraint(kind: vcExact, version: parseVersion(pkgRef))
      except CatchableError:
        rootMeta.refStr = pkgRef
        progress(pkgName & "@" & pkgRef)

    # 3. Registry + version index
    var registry: PackageRegistry
    var registered = initHashSet[string]()
    var pkgRefs = initTable[string, PkgRef]()
    pkgRefs[pkgName] = rootMeta

    proc registerVersions(name: string, versions: seq[DiscoveredVersion]) =
      ## Register all discovered versions (or a head placeholder when the repo
      ## has no semver tags) into the registry.
      if versions.len == 0:
        registry.addPackage(UnresolvedPackage(name: name,
          version: headVersion(name), dependencies: @[]))
      else:
        for v in versions:
          registry.addPackage(UnresolvedPackage(name: name,
            version: v.version, dependencies: @[]))
      registered.incl(name)

    # register the root's versions — from the DB index (offline) or, on a first
    # install / `--refresh`, from the freshly-cloned local tags
    registerVersions(pkgName, discoverVersions(pkgName, rootMeta.url, refresh))
    debugLog("root: " & pkgName & " (" & rootMeta.url & "), " &
      pluralize(registry[pkgName].len, "version") & " indexed")

    # 4. Phase A — clone & index every reachable package. Version discovery is
    #    clone-first and runs in parallel per level (thread pool); once a repo
    #    is in `_cache` its versions live in the DB, so no further network is
    #    needed afterwards. Expansion reads each package's *newest* version.
    var seen = initHashSet[string]()
    seen.incl(pkgName)
    var expandQueue = @[pkgName]
    while expandQueue.len > 0:
      var nextNames = initHashSet[string]()
      for name in expandQueue:
        let meta = pkgRefs.getOrDefault(name, PkgRef())
        if meta.url.len == 0: continue
        let versions = cachedVersions(name)
        let ver = if versions.len > 0: $versions[0].version else: "0.0.0"
        for d in getDeps(name, ver, @[], refresh, meta.url):
          let dn = depName(d)
          if dn.len == 0 or dn in seen: continue
          var dmeta = pkgRefs.getOrDefault(dn, PkgRef())
          if dmeta.url.len == 0:
            if d.url.len > 0:
              dmeta = PkgRef(name: dn, url: d.url, refStr: "")
            else:
              let m = fetchPkgMeta(dn)
              if m.isSome: dmeta = m.get()
            pkgRefs[dn] = dmeta
          if dmeta.url.len == 0:
            warn("Unknown package in registry, skipping: " & dn)
            continue
          if d.branch.len > 0 or d.tag.len > 0:
            # genuine git ref dep (`pkg#ref` / url#ref): head placeholder only;
            # its own deps are expanded lazily during resolution
            var m = dmeta
            m.refStr = if d.branch.len > 0: d.branch else: d.tag
            pkgRefs[dn] = m
            if not registry.hasKey(dn):
              registry.addPackage(UnresolvedPackage(name: dn,
                version: newVersion(0, 0, 0), dependencies: @[]))
            seen.incl(dn)
          else:
            nextNames.incl(dn)
      if nextNames.len == 0:
        break
      var toDiscover: seq[PkgRef]
      for name in nextNames:
        if name in registered: continue
        toDiscover.add(pkgRefs.getOrDefault(name, PkgRef()))
      if toDiscover.len > 0:
        debugLog("Phase A: fetching " & $toDiscover.len & " package(s)")
        progress("checking " & $toDiscover.len & " package(s)...")
        proc onFetch(name: string, count: int, cached: bool) =
          progress(fetchEventText(name, count, cached))
        let discovered = discoverVersionsBatch(toDiscover, refresh, onFetch)
        for name, versions in discovered:
          registerVersions(name, versions)
        for m in toDiscover:
          if m.name notin discovered:
            registerVersions(m.name, @[])
      seen.incl(nextNames)
      expandQueue = @[]
      for name in nextNames:
        if name in registered:
          expandQueue.add(name)
    debugLog("Phase A done: " & $registered.len & " package(s) indexed")

    # 5. Phase B — resolve. Deps are read per selected version from the local
    #    clones; a fallback lazily indexes any name the clone-first BFS missed
    #    (reachable only via an older version or a git-ref dep).
    debugLog("Phase B: resolving " & pkgName)
    var activeFeatOf = initTable[string, seq[string]]()
    proc provider(name: string, version: Version, feats: seq[string]): seq[Dependency] =
      activeFeatOf[name] = feats
      let deps = getDeps(name, $version, feats, refresh, pkgRefs.getOrDefault(name).url)
      result = @[]
      for d in deps:
        let dn = depName(d)
        # ensure we know the package URL
        var meta = pkgRefs.getOrDefault(dn, PkgRef())
        if meta.url.len == 0:
          if d.url.len > 0:
            # URL dep: use the URL the nimble file declares directly (may point
            # at a fork); the registry is only a fallback for the name lookup.
            meta = PkgRef(name: dn, url: d.url, refStr: "")
            pkgRefs[dn] = meta
          else:
            let m = fetchPkgMeta(dn)
            if m.isSome:
              meta = m.get()
              pkgRefs[dn] = meta
        if meta.url.len == 0:
          warn("Unknown package in registry, skipping: " & dn)
          continue
        if d.branch.len > 0 or d.tag.len > 0:
          # genuine git ref dep (`pkg#ref` / url#ref): no semver resolution.
          var m = meta
          m.refStr = if d.branch.len > 0: d.branch else: d.tag
          pkgRefs[dn] = m
          if not registry.hasKey(dn):
            registry.addPackage(UnresolvedPackage(name: dn,
              version: newVersion(0, 0, 0), dependencies: @[]))
          result.add(Dependency(name: dn,
            constraint: VersionConstraint(kind: vcExact, version: newVersion(0, 0, 0)),
            features: d.features))
        else:
          result.add(Dependency(name: dn, constraint: d.constraint, features: d.features))

    let roots = @[Dependency(name: pkgName, constraint: rootConstraint, features: features)]

    var resolution: Resolution
    try:
      while true:
        try:
          resolution = resolveDetailed(registry, roots, provider, maxProbes = 1000)
          break
        except PackageNotFoundError as e:
          var toDiscover: seq[PkgRef]
          for name in e.pending:
            if name in registered: continue
            let meta = pkgRefs.getOrDefault(name, PkgRef())
            if meta.url.len == 0: continue
            toDiscover.add(meta)
          if toDiscover.len == 0:
            fail("Could not resolve unknown package(s): " & e.pending.join(", "))
            return
          progress("checking " & $toDiscover.len & " package(s)...")
          proc onFetch2(name: string, count: int, cached: bool) =
            progress(fetchEventText(name, count, cached))
          let discovered = discoverVersionsBatch(toDiscover, refresh, onFetch2)
          for name, versions in discovered:
            registerVersions(name, versions)
          for m in toDiscover:
            if m.name notin discovered:
              registerVersions(m.name, @[])
    except CircularDependencyError as e:
      fail("Circular dependency: " & e.msg); return
    except VersionConflictError as e:
      fail("Version conflict: " & e.msg); return
    except ResolverError as e:
      fail("Resolution failed: " & e.msg); return

    var name2ver: Table[string, string]
    for rp in resolution.packages:
      name2ver[rp.name] = $rp.version
    debugLog("resolved " & $resolution.packages.len & " package(s)")
    if verbose:
      displayInfo("Resolved " & $resolution.packages.len & " package(s):")
      proc renderDepTree(name: string, leading: string, isLast: bool, isRoot: bool,
          path: var HashSet[string]) =
        let refStr = pkgRefs.getOrDefault(name).refStr
        var label = cyan(name)
        if refStr.len > 0:
          label.add(" @" & refStr)
        else:
          let ver = name2ver.getOrDefault(name)
          if ver.len > 0 and ver != "0.0.0":
            label.add(" v" & ver)
        let feats = activeFeatOf.getOrDefault(name)
        if feats.len > 0:
          label.add(" (features: " & feats.join(", ") & ")")
        var line = leading
        if not isRoot:
          line.add(if isLast: "└─ " else: "├─ ")
        display(line & label)
        if name in path:
          return
        path.incl(name)
        let deps = resolution.depsOf.getOrDefault(name)
        for i, dep in deps:
          let childIsLast = i == deps.high
          let childLeading =
            if isRoot: ""
            else: leading & (if isLast: "   " else: "│  ")
          if dep.name in name2ver:
            renderDepTree(dep.name, childLeading, childIsLast, false, path)
          else:
            display(childLeading & (if childIsLast: "└─ " else: "├─ ") &
              cyan(dep.name) & " " & $dep.constraint)
        path.excl(name)
      var path = initHashSet[string]()
      renderDepTree(pkgName, "", false, true, path)

    # soft violations: deeper constraints the chosen version could not honour
    for sv in resolution.softViolations:
      var msg = cyan(sv.name) & " resolved to " & $sv.chosen &
        " ignoring constraint " & $sv.constraint
      if sv.fromPkg.len > 0:
        msg.add(" from " & sv.fromPkg)
      warn(msg)

    # 6. Install each resolved package from the cache (clean, flat layout).
    #    The actual file copies run in parallel on a thread pool (one job per
    #    package); cache-ensuring and the already-installed check stay here.
    var installedCount = 0
    var installedLabels: seq[string]
    let rootLabel =
      if rootMeta.refStr.len > 0: "@" & rootMeta.refStr
      else:
        let v = name2ver.getOrDefault(pkgName)
        if v.len > 0: "@" & v else: ""
    if rootLabel.len > 0:
      progress("installing " & pkgName & rootLabel)
    var jobs: seq[InstallJob]
    for rp in resolution.packages:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr =
        if meta.refStr.len > 0: meta.refStr
        else: $rp.version
      debugLog("install: " & rp.name & "@" & verStr)
      let cacheDir = cluePkgsCachePath / rp.name
      if not dirExists(cacheDir):
        var url = meta.url
        if url.len == 0:
          let m = fetchPkgMeta(rp.name)
          if m.isSome:
            url = m.get().url
        if url.len == 0:
          warn("No URL for " & rp.name & ", skipping")
          continue
        if not clonePackage(url, cacheDir):
          continue
      let verDir = cluePkgsPath / rp.name / verStr
      let label =
        if meta.refStr.len > 0: " @" & verStr
        else: " v" & verStr
      if dirExists(verDir):
        progress(rp.name & label & " (cached)")
        installedCount.inc
        installedLabels.add(rp.name & "@" & verStr)
        continue
      jobs.add(InstallJob(name: rp.name, cacheDir: cacheDir, verDir: verDir,
        refStr: meta.refStr, verStr: verStr, refresh: refresh, label: label,
        nimble: block:
          let nimblePath = cacheDir / rp.name.changeFileExt("nimble")
          if fileExists(nimblePath): parseNimbleFile(nimblePath)
          else: NimbleFile(srcDir: "")))
    if jobs.len > 0:
      var results = newSeq[bool](jobs.len)
      var m = createMaster()
      m.awaitAll:
        for i, job in jobs:
          m.spawn installResolvedPkg(job) -> results[i]
      for i, ok in results:
        if ok:
          installedCount.inc
          installedLabels.add(jobs[i].name & "@" & jobs[i].verStr)
          progress("installed " & jobs[i].name & jobs[i].label)
        else:
          warn("Failed to install " & jobs[i].name & " v" & jobs[i].verStr)

    # 7. Record install manifests (resolved dep graph, used for pruning).
    #    Only the explicitly-installed package is a root; transitive deps
    #    are pruned when no longer reachable from any root.
    for rp in resolution.packages:
      let meta = pkgRefs.getOrDefault(rp.name, PkgRef())
      let verStr = if meta.refStr.len > 0: meta.refStr else: $rp.version
      let feats = activeFeatOf.getOrDefault(rp.name)
      var deps: seq[DepEntry]
      for d in getDeps(rp.name, $rp.version, feats, url = pkgRefs.getOrDefault(rp.name).url):
        let dn = depName(d)
        if d.branch.len > 0:
          deps.add((dn, d.branch))
        elif name2ver.hasKey(dn):
          deps.add((dn, name2ver[dn]))
      recordInstall(rp.name, verStr, deps, root = rp.name == pkgName,
        features = feats, installPath = cluePkgsPath / rp.name / verStr)

    # Success summary: `Installed N package(s)` (the install location is
    # implied) followed by the installed packages, one per line in cyan.
    if installedCount > 0:
      displaySuccess("Installed " & $installedCount & " " & pluralize(installedCount, "package"))
    for lbl in installedLabels:
      display("  " & cyan(lbl))

    # 8. Prune orphans / out-of-range versions
    pruneOrphans(verbose)

    # 9. Opt-in build (release by default). Runs after pruning so orphaned
    #    versions never get compiled.
    if doBuild:
      if not buildInstalled(pkgName, buildRelease, buildDebug, verbose):
        return

proc installCommand*(v: Values) =
  let raw = if v.has("pkg"): v.get("pkg").getStr else: ""
  let refresh = v.has("--refresh")
  let verbose = v.has("--verbose")
  devShadowWarningsEnabled = verbose
  let doBuild = v.has("--build")
  let buildDebug = v.has("--debug")
  let buildRelease = not buildDebug
  var features: seq[string]
  if v.has("--features"):
    features = parseFeatureFlags(v.get("--features").getStr)

  if raw.len == 0:
    # Local install: copy the current nimble package into the registry
    # (~/.clue/packages/<name>/<version>) with a clean, nimble-style layout.
    # Dependencies are installed too (like `clue install <pkg>`), so a
    # subsequent `clue test`/`clue build` finds the whole closure already
    # present instead of fetching it on the fly.
    let nimblePath = findNimbleFile(getCurrentDir())
    if nimblePath.len == 0:
      displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
      return
    let nimble = parseNimbleFile(nimblePath)
    let pkgName = nimblePath.extractFilename.changeFileExt("")

    checkNimConstraint(nimble)

    let version = if nimble.version.len > 0: nimble.version else: "0.0.0"
    let verDir = cluePkgsPath / pkgName / version
    safeRemoveDir(verDir)
    installCleanCopy(getCurrentDir(), verDir, nimble)
    var deps: seq[DepEntry]
    for d in nimble.requires:
      if d.isNim: continue
      deps.add((depName(d), ""))
    recordInstall(pkgName, version, deps, root = true,
      features = @[], installPath = verDir)
    displaySuccess("Installed " & pkgName & "@" & version & " to " & verDir)
    for d in nimble.requires:
      if d.isNim: continue
      let dep = depName(d)
      if dep.len == 0: continue
      let refStr = if d.branch.len > 0: d.branch elif d.tag.len > 0: d.tag else: ""
      installPackage(dep, refStr, false, d.features, verbose, constraint = d.constraint)
    if doBuild:
      if not buildInstalled(pkgName, buildRelease, buildDebug, verbose):
        return
    return

  if isGitUrl(raw):
    # `https://host/owner/repo[#ref]` installs straight from git. The URL is
    # translated to SSH (`git@host:path.git`) so private repos clone with the
    # user's default SSH keys.
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
    installPackage(name, urlRef, refresh, features, verbose, url = toGitSshUrl(url),
      doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug)
  else:
    let pkgInput = split(raw, "@")
    let pkgName = pkgInput[0]
    let pkgRef = if pkgInput.len > 1 and pkgInput[1] != "head": pkgInput[1] else: ""
    installPackage(pkgName, pkgRef, refresh, features, verbose,
      doBuild = doBuild, buildRelease = buildRelease, buildDebug = buildDebug)

proc updateRootSubprocess(exe, name: string): int {.gcsafe.} =
  ## Thread-pool worker for `clue update` (no argument): runs `clue update
  ## <name>` in an isolated process (streaming its output straight to the
  ## terminal), so parallel roots never share the DB or git state.
  var subEnv = newStringTable()
  for k, v in envPairs():
    subEnv[k] = v
  var p = startProcess(exe, args = ["update", name], env = subEnv,
    options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()

proc updateCommand*(v: Values) =
  ## Fetch new tags from remote for a package — or every installed root
  ## package — and upgrade it, and its whole dependency tree, to the newest
  ## satisfying versions. Develop-mode installs are skipped: they point at the
  ## user's own source tree, not the registry. With no argument the installed
  ## roots are updated in parallel (each in an isolated process).
  let verbose = v.has("--verbose")
  proc updatePkg(name: string) =
    let recs = installedRecords(name)
    if recs.len > 0 and recs.all(proc(r: InstalledRecord): bool = isDevInstall(r)):
      displayInfo("Skipping develop-mode package " & name & " (editable source, not registry-managed)")
      return
    installPackage(name, "", refresh = true, @[], verbose)
  if v.has("pkg"):
    updatePkg(v.get("pkg").getStr)
  else:
    let roots = installedRoots()
    if roots.len == 0:
      displayInfo("No installed packages to update")
      return
    if roots.len == 1:
      updatePkg(roots[0])
    else:
      let exe = getAppFilename()
      var codes = newSeq[int](roots.len)
      var m = createMaster()
      m.awaitAll:
        for i, name in roots:
          m.spawn updateRootSubprocess(exe, name) -> codes[i]
      if codes.anyIt(it != 0):
        quit(1)

proc developCommand*(v: Values) =
  ## Develop-mode (editable) install of the current nimble package: the install
  ## record points at a symlink under ~/.clue/develop whose target is the
  ## working tree — no source is ever copied, and uninstall only ever removes
  ## the DB entry (plus the symlink), never the files. Never compiles anything;
  ## its purpose is library discovery: other packages' builds pick the package
  ## up via the recorded path (`import pkg/<name>` resolves against live source).
  let nimblePath = findNimbleFile(getCurrentDir())
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
    return
  let nimble = parseNimbleFile(nimblePath)
  let pkgName = nimblePath.extractFilename.changeFileExt("")
  let version = if nimble.version.len > 0: nimble.version else: "0.0.0"
  let linkPath = clueDevelopPath / pkgName
  discard existsOrCreateDir(clueDevelopPath)
  safeRemoveSymlink(linkPath)
  createSymlink(getCurrentDir(), linkPath)
  var deps: seq[DepEntry]
  for d in nimble.requires:
    if d.isNim: continue
    deps.add((depName(d), ""))
  recordInstall(pkgName, version, deps, root = true,
    features = @[], installPath = linkPath)
  displaySuccess("Develop-mode: " & pkgName & "@" & version & " (editable, library discovery from " & getCurrentDir() & ")")

proc versionsCommand*(v: Values) =
  ## Show available versions for a package.
  let pkgName = v.get("pkg").getStr
  let metaOpt = fetchPkgMeta(pkgName)
  if metaOpt.isNone:
    displayError("Package not found in registry: " & pkgName, quitProcess = true)
    return
  let meta = metaOpt.get()
  let versions = discoverVersions(pkgName, meta.url, v.has("--refresh"))
  if versions.len == 0:
    displayInfo("No semver tags found for " & pkgName)
    return
  displayInfo("Available versions for " & pkgName & ":")
  for v in versions:
    echo "  " & $v.version

proc pruneCommand*(v: Values) =
  ## Prune orphaned or out-of-range installed packages.
  pruneOrphans()

proc registryUpdateCommand*(v: Values) =
  ## Fetch a fresh packages.json from the nim registry and re-index the
  ## available packages.
  if not refreshRegistry():
    quit(1)

template whenPackageExists(pkgName: string, body: untyped): untyped =
  let pkgBase = cluePkgsPath / pkgName
  var found = false
  if dirExists(pkgBase):
    for entry in walkDir(pkgBase):
      if entry.kind == pcDir:
        found = true
        break
  if found:
    let res = clueDB.getTable("packages")
                      .get()
                      .where("name", newTextValue(pkgName))
                      .toSeq()
    if res.len == 0:
      displayError("Package not found: " & pkgName, quitProcess = true)
      return
    block:
      `body`
  else:
    displayError("Package not found: " & cyan(pkgName), quitProcess = true)

proc uninstallCommand*(v: Values) =
  let pkgInput = split(v.get("pkg").getStr, "@")
  let pkgName = pkgInput[0]
  let pkgVersion = if pkgInput.len > 1: pkgInput[1] else: ""
  if pkgVersion.len > 0:
    var rec: InstalledRecord
    var found = false
    for r in installedRecords(pkgName):
      if r.version == pkgVersion:
        rec = r
        found = true
        break
    if not found:
      displayError("Version not installed: " & pkgName & "@" & pkgVersion, quitProcess = true)
      return
    if rec.isDevInstall:
      # develop-mode install: only the DB entry (and the ~/.clue/develop
      # symlink) exist — never touch the source files
      if promptConfirm("Remove develop-mode install " & pkgName & "@" & pkgVersion & " (files kept)?"):
        unrecordInstall(pkgName, pkgVersion)
        safeRemoveSymlink(clueDevelopPath / pkgName)
        displaySuccess("Removed " & pkgName & "@" & pkgVersion & " (editable install, files untouched)")
      else:
        displayInfo("Removal cancelled.")
    else:
      let verDir = cluePkgsPath / pkgName / pkgVersion
      if dirExists(verDir):
        if promptConfirm("Remove " & pkgName & "@" & pkgVersion & "?"):
          safeRemoveDir(verDir)
          unrecordInstall(pkgName, pkgVersion)
          displaySuccess("Removed " & pkgName & "@" & pkgVersion)
        else:
          displayInfo("Removal cancelled.")
      else:
        displayError("Version not installed: " & pkgName & "@" & pkgVersion, quitProcess = true)
  else:
    # unversioned: the installed records are the source of truth (dev installs
    # have no files under ~/.clue/packages, only DB entries)
    let recs = installedRecords(pkgName)
    var hasDirs = false
    if dirExists(cluePkgsPath / pkgName):
      for e in walkDir(cluePkgsPath / pkgName):
        if e.kind == pcDir:
          hasDirs = true
          break
    if recs.len == 0 and not hasDirs:
      displayError("Package not found: " & cyan(pkgName), quitProcess = true)
      return
    if promptConfirm("Remove all versions of " & cyan(pkgName) & "?"):
      safeRemoveDir(cluePkgsPath / pkgName)
      unrecordInstall(pkgName, "")
      safeRemoveSymlink(clueDevelopPath / pkgName)
      displaySuccess("All versions of " & pkgName & " removed")
    else:
      displayInfo("Uninstallation cancelled.")
  pruneOrphans()

proc dumpCommand*(v: Values) =
  ## Dump package info from the registry, its available versions and recent
  ## git activity (latest commit hash/date/author) — `--refresh` re-reads
  ## versions from the remote instead of the local cache.
  withClueDB do:
    let pkgName = v.get("pkg").getStr
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
        # available versions (newest first) + latest-commit git activity
        let versions = discoverVersions(pkgName, pkgData[1]["url"].strVal,
          v.has("--refresh"), cloneOnMiss = false)
        var verArr = newJArray()
        for dv in versions:
          verArr.add(%($dv.version))
        pkgInfo["versions"] = verArr
        let git = gitHeadInfo(pkgName, pkgData[1]["url"].strVal)
        if git.isSome:
          pkgInfo["git"] = %*{
            "head": git.get().hash,
            "date": git.get().date,
            "author": git.get().author,
            "subject": git.get().subject
          }
        display(pretty(pkgInfo))


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
