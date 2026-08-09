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

import std/[os, osproc, strutils, tables, sets, sequtils, algorithm, times, json, options, locks, monotimes]

# threadpool is deprecated in favor of taskpools/weave, but remains fully
# supported; silence the hint so the build stays clean.
{.push warning[Deprecated]: off.}
import std/threadpool
{.pop.}

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

const gitSshEnv = "GIT_SSH_COMMAND='ssh -oBatchMode=yes -oConnectTimeout=10'"

proc gitExec(cmd: string): tuple[output: string, exitCode: int] {.gcsafe.} =
  ## Run a git command through the shell, echoing it to stderr when debug
  ## tracing is enabled (CLUE_DEBUG=1) so hangs/timeouts are diagnosable.
  if debugEnabled:
    let start = getMonoTime()
    debugLog("$ " & cmd)
    result = execCmdEx(cmd)
    let elapsed = (getMonoTime() - start).inMilliseconds()
    debugLog("  -> exit " & $result.exitCode & " (" & $elapsed & "ms)")
  else:
    result = execCmdEx(cmd)

var failedClones = initHashSet[string]()
  ## _cache dirs whose clone already failed this run — skip retrying (e.g. a
  ## private/inaccessible repo referenced by a dep), so we don't hammer it.
var failedClonesLock: Lock
failedClonesLock.initLock()

proc toGitSshUrl*(url: string): string =
  ## Translate an https(s) git URL into an scp-like SSH URL
  ## (`git@host:path.git`) so git operations run over SSH using the user's
  ## default SSH keys — enabling installs of private repositories.
  var u = url.strip()
  if u.startsWith("git+"):
    u = u[4 .. ^1]
  if not (u.startsWith("https://") or u.startsWith("http://")):
    return u
  let slashPos = u.split("://")[1].find('/')
  if slashPos < 0:
    return u
  let host = u.split("://")[1][0 ..< slashPos]
  var path = u.split("://")[1][slashPos + 1 .. ^1]
  if not path.endsWith(".git"):
    path.add(".git")
  result = "git@" & host & ":" & path

proc cloneRepo(url, dest: string, nonInteractive = false): bool {.gcsafe.} =
  ## Clone `url` into `dest` (SSH first, HTTPS fallback) and fetch tags.
  ## Pure git + local state — safe to call from a thread pool worker.
  ## With `nonInteractive` (version discovery) git is prevented from prompting
  ## for credentials, so dead/deleted URLs fail fast and the version is simply
  ## excluded; installs keep interactive prompts for private repositories.
  let promptEnv =
    if nonInteractive: "GIT_TERMINAL_PROMPT=0 " & gitSshEnv
    else: gitSshEnv
  let (o1, c1) = gitExec(promptEnv & " git clone " & toGitSshUrl(url) & " " & dest)
  if c1 == 0:
    discard gitExec(gitSshEnv & " git -C " & dest & " fetch --tags --quiet")
    return true
  let httpsEnv = if nonInteractive: "GIT_TERMINAL_PROMPT=0 " else: ""
  let (o2, c2) = gitExec(httpsEnv & " git clone " & url & " " & dest)
  if c2 == 0:
    discard gitExec(gitSshEnv & " git -C " & dest & " fetch --tags --quiet")
    return true
  false

proc clonePackage*(url, dest: string, refresh = false, nonInteractive = false): bool =
  ## Clone (or refresh) a package repository into the cache, preferring SSH and
  ## falling back to HTTPS. On an existing cache dir only `refresh` touches the
  ## network (incremental `git fetch --tags`); offline installs reuse the clone.
  ## `nonInteractive` suppresses prompts *and* failure warnings (used during
  ## version discovery where a dead URL just means "no versions").
  withLock failedClonesLock:
    if dest in failedClones:
      return false
  if dirExists(dest):
    if refresh:
      discard gitExec("git -C " & dest & " remote set-url origin " & toGitSshUrl(url))
      let promptEnv = if nonInteractive: "GIT_TERMINAL_PROMPT=0 " & gitSshEnv else: gitSshEnv
      let (output, exitCode) = gitExec(promptEnv & " git -C " & dest &
        " fetch --tags --prune --quiet")
      if exitCode != 0:
        # SSH not available — fall back to the original (https) remote
        discard gitExec("git -C " & dest & " remote set-url origin " & url)
        let (out2, code2) = gitExec(promptEnv & " git -C " & dest &
          " fetch --tags --prune --quiet")
        if code2 != 0 and not nonInteractive:
          displayWarning("Failed to refresh " & dest & ": " & output & out2)
    return true
  if cloneRepo(url, dest, nonInteractive):
    return true
  withLock failedClonesLock:
    failedClones.incl(dest)
  if not nonInteractive:
    displayWarning("Failed to clone " & url)
  false

proc checkoutTag*(dest, tag: string): bool =
  ## Checkout an exact tag/ref in the cached repo (detached HEAD).
  let (output, code) = gitExec("git -C " & dest & " checkout " & tag & " --quiet 2>/dev/null")
  code == 0

proc checkoutHead*(dest: string, refresh = false): bool =
  ## Checkout the default branch. With `refresh` the remote is fetched first so
  ## `pkg@head` deps resolve to the latest commit; otherwise the local default
  ## branch state is used (offline-safe).
  if refresh:
    discard gitExec(gitSshEnv & " git -C " & dest & " fetch origin --quiet")
  let (defOut, _) = gitExec("git -C " & dest &
    " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var branch = defOut.strip()
  if branch.startsWith("refs/remotes/origin/"):
    branch = branch["refs/remotes/origin/".len .. ^1]
  if branch.len == 0:
    branch = "master"
  let (output, code) = gitExec("git -C " & dest &
    " checkout -q origin/" & branch & " -- 2>/dev/null")
  if code == 0:
    return true
  # fallback: try the common default branch names
  for b in ["master", "main"]:
    let (out2, code2) = gitExec("git -C " & dest &
      " checkout -q origin/" & b & " -- 2>/dev/null")
    if code2 == 0:
      return true
  false

proc checkoutRef*(dest, refStr: string, refresh = false): bool =
  ## Checkout a branch or arbitrary ref in the cached repo.
  if refStr.len > 0 and refStr.toLowerAscii == "head":
    return checkoutHead(dest, refresh)
  let (output, code) = gitExec("git -C " & dest & " checkout " & refStr & " --quiet 2>/dev/null")
  code == 0

type
  GitHeadInfo* = object
    hash*: string    ## full commit hash of the latest commit
    date*: string    ## ISO-8601 committer date
    author*: string  ## committer name
    subject*: string ## first line of the commit message

proc gitHeadInfo*(name, url: string): Option[GitHeadInfo] =
  ## Last-commit metadata for a git URL (`clue dump`). Prefers the cached clone
  ## in `_cache` when present (offline, checks out the default branch tip);
  ## otherwise does a fresh clone into the system temp dir and removes it after.
  ## Returns `none` when the repo isn't reachable.
  var repo = cluePkgsCachePath / name
  var own = false
  if not dirExists(repo):
    repo = getTempDir() / ("clue_head_" & $getMonoTime().ticks)
    if not clonePackage(url, repo, nonInteractive = true):
      return none(GitHeadInfo)
    own = true
  else:
    discard checkoutHead(repo)
  let (output, code) = gitExec("git -C " & repo &
    " log -1 --format=%H%n%aI%n%an%n%s")
  if own:
    removeDir(repo)  # our own temp clone — created and removed by clue
  if code != 0 or output.len == 0:
    return none(GitHeadInfo)
  let lines = output.splitLines()
  if lines.len < 3:
    return none(GitHeadInfo)
  some(GitHeadInfo(
    hash: lines[0],
    date: lines[1],
    author: lines[2],
    subject: lines[3]))


proc findLocalTags(dest: string): seq[string] {.gcsafe.} =
  ## List local git tags by reading the ref store directly (`.git/packed-refs`
  ## plus loose `refs/tags/`) — no `git` subprocess, so it's fast even across
  ## many packages.
  var seen = initHashSet[string]()
  let gitDir = dest / ".git"
  let packedRefs = gitDir / "packed-refs"
  if fileExists(packedRefs):
    for line in readFile(packedRefs).splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let parts = trimmed.splitWhitespace()
      if parts.len >= 2 and parts[1].startsWith("refs/tags/"):
        var tag = parts[1]["refs/tags/".len .. ^1]
        if tag.endsWith("^{}"):
          continue # peeled annotated-tag ref — the plain tag ref is enough
        if tag notin seen:
          seen.incl(tag)
          result.add(tag)
  let refsDir = gitDir / "refs" / "tags"
  if dirExists(refsDir):
    for f in walkDirRec(refsDir):
      let tag = relativePath(f, refsDir)
      if tag.len > 0 and tag notin seen:
        seen.incl(tag)
        result.add(tag)

proc listRemoteTags(url: string): seq[string] =  ## List all tag refs on a git remote without cloning (SSH first, HTTPS
  ## fallback). Prompts are disabled so a dead URL fails fast, never blocks.
  var output: string
  var exitCode: int
  (output, exitCode) = gitExec("GIT_TERMINAL_PROMPT=0 " & gitSshEnv &
    " git ls-remote --tags " & toGitSshUrl(url))
  if exitCode != 0:
    (output, exitCode) = gitExec("GIT_TERMINAL_PROMPT=0 git ls-remote --tags " & url)
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
    let tbl = versionsDB.getTable("versions").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      discard versionsDB.deleteRow("versions", pk)
    let nowStr = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
    for v in versions:
      discard versionsDB.insertRow("versions", row({
        "name": newTextValue(name),
        "version": newTextValue($v.version),
        "tag": newTextValue(v.tag),
        "discovered_at": newTextValue(nowStr)
      }))
    versionsDB.checkpoint()

proc cachedVersions*(name: string): seq[DiscoveredVersion] =
  ## Read the version list for `name` from the versions DB, newest first. The
  ## DB is authoritative once populated — no git or network is touched here, so
  ## repeat installs/builds stay fully offline.
  withClueDB do:
    let rows = versionsDB.getTable("versions").get().where("name", newTextValue(name)).toSeq()
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
        return all
  @[]

proc discoverFromTags(name: string, tags: seq[string]): seq[DiscoveredVersion] =
  ## Parse, sort and dedupe a tag list into semver versions (newest first).
  ## Dedupes e.g. "1.2.3" and "v1.2.3" pointing at the same version.
  var all: seq[DiscoveredVersion]
  for tag in tags:
    let (ok, ver) = parseTag(tag)
    if ok:
      all.add(DiscoveredVersion(version: ver, tag: tag))
  all.sort(proc(a, b: DiscoveredVersion): int = cmp(b.version, a.version))
  var seen: seq[Version]
  for v in all:
    if v.version notin seen:
      seen.add(v.version)
      result.add(v)

proc discoverVersions*(name, url: string, refresh = false,
    cloneOnMiss = true): seq[DiscoveredVersion] =
  ## Discover all semver versions for a package, newest first.
  ## Serves from the DB cache unless `refresh` is set. On a cache miss the
  ## package is cloned into `_cache` (first time only) and versions are read
  ## from its local git tags — no network afterwards. With `cloneOnMiss = false`
  ## (the `clue versions` query) it lists the remote without cloning.
  if not refresh:
    let cached = cachedVersions(name)
    if cached.len > 0:
      return cached
  let dest = cluePkgsCachePath / name
  if cloneOnMiss and not dirExists(dest):
    if not clonePackage(url, dest, refresh, nonInteractive = true):
      return @[]
  let tags =
    if dirExists(dest): findLocalTags(dest)
    else: listRemoteTags(url)
  result = discoverFromTags(name, tags)
  cacheVersions(name, result)

type
  TagFetchJob = tuple[name: string, url: string]

proc fetchTagsJob(job: TagFetchJob): tuple[name: string, tags: seq[string]] {.gcsafe.} =
  ## Worker for `discoverVersionsBatch`: clones the package if needed (first
  ## time only, network, non-interactive so dead URLs fail fast) and lists its
  ## local git tags. Never touches the DB.
  debugLog("discover: " & job.name & " <- " & job.url)
  let dest = cluePkgsCachePath / job.name
  if not dirExists(dest):
    if not cloneRepo(job.url, dest, nonInteractive = true):
      debugLog("discover: " & job.name & " clone FAILED")
      return (job.name, @[])
  let tags = findLocalTags(dest)
  (job.name, tags)

proc discoverVersionsBatch*(pkgs: openArray[PkgRef], refresh = false,
    onDone: proc(name: string, versions: int, cached: bool) = nil):
    Table[string, seq[DiscoveredVersion]] =
  ## Discover versions for many packages at once. The clone-and-list steps run
  ## concurrently on a thread pool; DB cache writes happen sequentially on the
  ## caller's thread since the store isn't thread-safe. `onDone` is called on
  ## the caller's thread as each package finishes (for live progress), with
  ## `cached` true when it was served from the local DB (no network).
  var jobs: seq[FlowVar[tuple[name: string, tags: seq[string]]]]
  for pkg in pkgs:
    if pkg.name.len == 0 or result.hasKey(pkg.name):
      continue
    if not refresh:
      let cached = cachedVersions(pkg.name)
      if cached.len > 0:
        result[pkg.name] = cached
        if onDone != nil:
          onDone(pkg.name, cached.len, true)
        continue
    jobs.add(spawn fetchTagsJob((pkg.name, pkg.url)))
  for fv in jobs:
    while not fv.isReady:
      sleep(20)
    let (name, tags) = ^fv
    let versions = discoverFromTags(name, tags)
    debugLog("discover " & name & ": " & $versions.len & " version(s), " & $tags.len & " tag(s)")
    cacheVersions(name, versions)
    result[name] = versions
    if onDone != nil:
      onDone(name, versions.len, false)

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
  depsCacheVersion = 5

type
  CachedDeps = object
    hard: seq[NimbleDependency]
    features: Table[string, seq[NimbleDependency]]
    dev: seq[NimbleDependency]

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
    let rows = versionsDB.getTable("deps").get().where("name", newTextValue(name)).toSeq()
    for (pk, row) in rows:
      if row["version"].strVal == version:
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
          if n.hasKey("dev"):
            res.dev = jsonToDepsArr(n["dev"])
          return some(res)
        except CatchableError:
          return none(CachedDeps)
  none(CachedDeps)

proc cacheDeps(name, version: string, deps: CachedDeps) =
  withClueDB do:
    let tbl = versionsDB.getTable("deps").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        discard versionsDB.deleteRow("deps", pk)
        break
    var featsNode = newJObject()
    for fname, fdeps in deps.features:
      featsNode[fname] = depsToJsonArr(fdeps)
    let depsNode = %*{"v": depsCacheVersion,
                      "hard": depsToJsonArr(deps.hard),
                      "features": featsNode,
                      "dev": depsToJsonArr(deps.dev)}
    discard versionsDB.insertRow("deps", row({
      "name": newTextValue(name),
      "version": newTextValue(version),
      "deps": newJSONValue(depsNode),
      "cached_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
    }))
    clueDB.checkpoint()

proc defaultBranch(dest: string): string =
  ## The default branch name of a cached clone (origin/HEAD, fallback master).
  let (defOut, _) = gitExec("git -C " & dest &
    " symbolic-ref --quiet refs/remotes/origin/HEAD")
  var b = defOut.strip()
  if b.startsWith("refs/remotes/origin/"):
    b = b["refs/remotes/origin/".len .. ^1]
  if b.len == 0:
    b = "master"
  b

proc readNimbleContent(dest, name, version: string): string =
  ## Read a package version's nimble file via `git show` — no working-tree
  ## checkout, so it's fast and always reflects exactly that version.
  let nimbleName = name.changeFileExt("nimble")
  let (output, exitCode) =
    if version == "0.0.0":
      gitExec("git -C " & dest & " show origin/" & defaultBranch(dest) & ":" &
        nimbleName & " 2>/dev/null")
    else:
      let tag = tagForVersion(dest, version)
      if tag.len == 0:
        return ""
      gitExec("git -C " & dest & " show " & tag & ":" & nimbleName & " 2>/dev/null")
  if exitCode == 0: output else: ""

proc getDeps*(name, version: string, features: seq[string] = @[],
    refresh = false, url = ""): seq[NimbleDependency] =
  ## Lazily fetch the dependency list for a specific package version,
  ## including the requires of any activated `features`. Serves from the
  ## DB cache, cloning + parsing on first demand. `url` overrides the registry
  ## lookup when the package is only known by its repository URL.
  debugLog("deps: " & name & "@" & version & (if url.len > 0: " <- " & url else: ""))
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
      var pkgUrl = url
      if pkgUrl.len == 0:
        let meta = fetchPkgMeta(name)
        if meta.isSome:
          pkgUrl = meta.get().url
      if pkgUrl.len == 0:
        displayWarning("Unknown package in registry: " & name)
        return @[]
      if not clonePackage(pkgUrl, dest, refresh):
        return @[]

    # refresh the default branch for head deps when asked
    if version == "0.0.0" and refresh:
      discard gitExec(gitSshEnv & " git -C " & dest & " fetch origin --quiet")

    # read this version's nimble straight from the git object store — fast and
    # always the exact version, never a stale working tree
    let nimbleCode = readNimbleContent(dest, name, version)
    if nimbleCode.len > 0:
      let pkg = parseNimbleString(nimbleCode)
      for dep in pkg.requires:
        if not dep.isNim:
          deps.hard.add(dep)
      for fname, fdeps in pkg.features:
        var farr: seq[NimbleDependency]
        for dep in fdeps:
          if not dep.isNim:
            farr.add(dep)
        deps.features[fname] = farr
      for dep in pkg.dev:
        if not dep.isNim:
          deps.dev.add(dep)
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
    features: seq[string] = @[], installPath = "") =
  ## Record an installed package version with its resolved dependencies.
  ## `root` marks packages the user explicitly installed (vs. pulled as deps);
  ## only roots survive pruning. `features` are the active feature set the
  ## package was resolved with (used to emit `-d:features.<pkg>.<feat>`).
  ## `installPath` is the directory the compiler gets via `--path`.
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
      "path": newTextValue(installPath),
      "installed_at": newTextValue(now().format("yyyy-MM-dd'T'HH:mm:sszzz"))
    }))
    clueDB.checkpoint()

proc installedPath*(name, version: string): string =
  ## The recorded `--path` for an installed package version ("" if unknown).
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      if row["version"].strVal == version:
        return row["path"].strVal
  ""

proc resolveInstalledPath*(name, preferRef: string): string =
  ## The recorded `--path` for an installed package, preferring the explicit ref
  ## (branch/tag) when given, else the latest semver version.
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    var bestVer = newVersion(0, 0, 0)
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      let ver = row["version"].strVal
      if ver.len > 0 and ver == preferRef:
        return row["path"].strVal
      try:
        let v = parseVersion(ver)
        if v > bestVer:
          bestVer = v
          result = row["path"].strVal
      except CatchableError:
        discard
    if result.len > 0:
      return result
  ""

type
  InstalledRecord* = object
    version*: string
    path*: string
    root*: bool

proc installedRecords*(name: string): seq[InstalledRecord] =
  ## All installed records for `name` from the installed manifest. This is the
  ## source of truth for uninstall/prune — records can exist without any files
  ## on disk (develop-mode installs point at the user's source tree).
  withClueDB do:
    let tbl = clueDB.getTable("installed").get()
    for (pk, row) in tbl.where("name", newTextValue(name)).toSeq():
      result.add(InstalledRecord(
        version: row["version"].strVal,
        path: row["path"].strVal,
        root: row.hasKey("root") and row["root"].boolVal
      ))

proc isDevInstall*(rec: InstalledRecord): bool =
  ## True for develop-mode (editable) installs whose path points outside the
  ## package registry — i.e. at the user's own source tree. Such installs have
  ## no files under ~/.clue/packages; only their DB entry exists, and only the
  ## entry may ever be deleted.
  rec.path.len > 0 and not isInsidePkgs(rec.path)

proc collectInstalledDepNames*(rootNames: seq[string]): seq[string] =
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

proc resolveDepPathLike(name: string): string =
  ## Locate the latest installed version dir for a package on disk (fallback
  ## for legacy installs that predate the recorded `path` column).
  let base = cluePkgsPath / name
  if not dirExists(base): return ""
  var best = ""
  var bestVer = newVersion(0, 0, 0)
  for entry in walkDir(base):
    if entry.kind == pcDir:
      try:
        let v = parseVersion(entry.path.extractFilename)
        if v > bestVer:
          bestVer = v
          best = entry.path
      except CatchableError:
        discard
  best

proc pathForImports(p: string): string =
  ## The `--path` target for an installed package dir. Develop-mode installs
  ## point at the live source tree, so imports resolve against the `srcDir`
  ## (e.g. `<pkg>/src`); registry installs are flattened (srcDir contents sit
  ## at the root), so the dir itself is returned.
  let nimblePath = findNimbleFile(p)
  if nimblePath.len > 0:
    try:
      let srcDir = parseNimbleFile(nimblePath).srcDir
      let src =
        if srcDir.len > 0: srcDir
        else: "src"
      if dirExists(p / src):
        return p / src
    except CatchableError:
      discard
  p

proc allInstalledPaths*(): seq[string] =
  ## One `--path` (install dir) per installed package — the latest version each —
  ## so `import xyz` / `import pkg/xyz` resolves for any clue-installed package.
  ## One path per package avoids Nim's ambiguity error from multiple versions.
  var bestBy: Table[string, tuple[ver: Version, path: string]]
  withClueDB do:
    for (pk, row) in clueDB.getTable("installed").get().allRows():
      let name = row["name"].strVal
      try:
        let v = parseVersion(row["version"].strVal)
        if not bestBy.hasKey(name) or v > bestBy[name].ver:
          bestBy[name] = (v, row["path"].strVal)
      except CatchableError:
        discard
  for name, entry in bestBy:
    var p = entry.path
    if p.len == 0:
      # legacy install without a recorded path — locate it on disk
      p = resolveDepPathLike(name)
    if p.len > 0:
      let src = pathForImports(p)
      if src notin result:
        result.add(src)

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
      safeRemoveDir(dir)
      let parentDir = cluePkgsPath / name
      if dirExists(parentDir):
        var hasEntries = false
        for e in walkDir(parentDir):
          hasEntries = true
          break
        if not hasEntries:
          safeRemoveDir(parentDir)
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
