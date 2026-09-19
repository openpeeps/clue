# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Resolved-dependency lockfile (`clue.lock`) for fast `build`/`check`/`test`.
##
## `collectResolvedPaths` (commands/build.nim) is the slow path: per-dep Boogie
## lookups, full-table scans, nimble re-parses and datpkgr resolution. The lock
## collapses that to one JSON read plus `dirExists` checks when the project
## fingerprint is unchanged. Any mismatch falls back to the slow path, which
## rewrites the lock on success. Develop-mode entries are always re-validated
## against the live checkout.
##
## Serialization uses `pkg/openparser/json`: Nim objects map straight to/from
## JSON via `toJson` / `fromJson`, no manual `JsonNode` juggling.

import std/[os, hashes, strutils, sequtils, algorithm, sets, tables]
import pkg/semver
import pkg/openparser/json
import ./resolver
import ./nimbleparser except findNimbleFile, parseNimbleFile

const
  LockFileName* = "clue.lock"
  LockVersion* = 1

type
  LockEntry* = object
    name*: string
    version*: string
    constraint*: string
    features*: seq[string]
    path*: string
    develop*: bool
    url*: string
    refStr*: string

  LockFile* = object
    fileVersion*: int
    root*: string
    nimbleHash*: string
    features*: seq[string]
    nimVersion*: string
    packages*: seq[LockEntry]

proc renameHook*(v: LockFile, fieldName: var string) =
  ## Map `fileVersion` <-> `version` on the wire. Declared as an involution
  ## so it round-trips: dump rewrites the Nim field name to the JSON key,
  ## parse rewrites the JSON key back to the field name.
  if fieldName == "fileVersion": fieldName = "version"
  elif fieldName == "version": fieldName = "fileVersion"

proc renameHook*(v: LockEntry, fieldName: var string) =
  ## Map `refStr` <-> `ref` on the wire (`ref` is a Nim keyword, so the
  ## field itself cannot carry the wire name).
  if fieldName == "refStr": fieldName = "ref"
  elif fieldName == "ref": fieldName = "refStr"

proc lockPathFor*(pkgDir: string): string =
  pkgDir / LockFileName

proc depSpecKey(name, url, constraint, branch, tag: string,
    features: seq[string]): string =
  var feats = features
  feats.sort()
  name & "|" & url & "|" & constraint & "|" & branch & "|" & tag &
    "|" & feats.join(",")

proc computeNimbleHash*(nimble: NimbleFile,
    activeRootFeatures: seq[string], nimVersion: string): string =
  ## Fingerprint of everything that affects resolution: hard requires, all
  ## feature blocks (so adding an inactive block still invalidates), active
  ## feature selection, layout fields and the toolchain version.
  var parts: seq[string] = @[]
  var reqs = nimble.requires.mapIt(
    depSpecKey(it.name, it.url, $it.constraint, it.branch, it.tag, it.features))
  reqs.sort()
  parts.add("requires:" & reqs.join(";"))
  var featBlocks: seq[string] = @[]
  for fname, fdeps in nimble.features:
    var fparts = fdeps.mapIt(
      depSpecKey(it.name, it.url, $it.constraint, it.branch, it.tag, it.features))
    fparts.sort()
    featBlocks.add(fname & "=" & fparts.join(";"))
  featBlocks.sort()
  parts.add("features:" & featBlocks.join("|"))
  var active = activeRootFeatures
  active.sort()
  parts.add("active:" & active.join(","))
  parts.add("srcDir:" & nimble.srcDir)
  var bins = nimble.bin
  bins.sort()
  parts.add("bin:" & bins.join(","))
  parts.add("nim:" & nimVersion)
  $abs(hash(parts.join("\n")))

proc newLockFile*(root, nimbleHash, nimVersion: string,
    activeFeatures: seq[string], packages: seq[LockEntry]): LockFile =
  LockFile(fileVersion: LockVersion, root: root, nimbleHash: nimbleHash,
    features: activeFeatures, nimVersion: nimVersion, packages: packages)

proc writeLock*(pkgDir: string, lock: LockFile) =
  ## Atomic write via tmp + rename so concurrent builds cannot corrupt it.
  let dst = lockPathFor(pkgDir)
  let tmp = dst & ".tmp-" & $getCurrentProcessId()
  try:
    writeFile(tmp, toJson(lock))
    moveFile(tmp, dst)
  except CatchableError:
    try: removeFile(tmp) except: discard

proc readLock*(pkgDir: string): tuple[ok: bool, lock: LockFile] =
  let p = lockPathFor(pkgDir)
  if not fileExists(p):
    return (false, LockFile())
  try:
    let lock = fromJson(readFile(p), LockFile)
    if lock.fileVersion != LockVersion:
      return (false, LockFile())
    var clean = lock
    clean.packages = lock.packages.filterIt(it.name.len > 0 and it.path.len > 0)
    (true, clean)
  except CatchableError:
    (false, LockFile())

proc versionSatisfiesConstraint(versionStr, constraintStr: string): bool =
  if constraintStr.len == 0 or constraintStr == "*":
    return true
  try:
    let c = parseConstraint(constraintStr)
    if c.kind == vcAny:
      return true
    if c.kind == vcExact and c.version.major == 0 and
       c.version.minor == 0 and c.version.patch == 0:
      return true
    let v = parseVersion(versionStr)
    return v.satisfies(c)
  except CatchableError:
    return true

proc validateLock*(lock: LockFile, nimble: NimbleFile,
    activeRootFeatures: seq[string], nimVersion: string,
    developDir: string): bool =
  ## Fingerprint + per-entry checks. No DB or network. Entries flagged
  ## `develop` have a live `~/.clue/develop/<name>` checkout: the link must
  ## still exist and the recorded import path must be under its target.
  ## Unflagged entries (registry copies, or stale record paths without a
  ## link) are pinned paths validated by existence + constraint match.
  if lock.nimbleHash.len == 0:
    return false
  if lock.nimbleHash != computeNimbleHash(nimble, activeRootFeatures, nimVersion):
    return false
  var wantActive = activeRootFeatures
  wantActive.sort()
  var gotActive = lock.features
  gotActive.sort()
  if wantActive != gotActive:
    return false
  if lock.nimVersion.len > 0 and nimVersion.len > 0 and
     lock.nimVersion != nimVersion:
    return false
  if lock.packages.len == 0:
    return true
  var seen = initHashSet[string]()
  for e in lock.packages:
    if e.name in seen:
      return false
    seen.incl(e.name)
    if e.path.len == 0 or not dirExists(e.path):
      return false
    if e.develop:
      if developDir.len > 0:
        let link = developDir / e.name
        if not (symlinkExists(link) or dirExists(link)):
          return false
      # Live source must still be the recorded one: the develop link target
      # (when resolvable) should prefix-match the locked import path's base.
      # When unresolvable we already verified dirExists above.
      try:
        let link = developDir / e.name
        if symlinkExists(link):
          let target = expandSymlink(link)
          if target.len > 0 and not e.path.startsWith(target):
            # Import path may be <target>/src — prefix match covers it.
            return false
      except CatchableError:
        discard
    else:
      # Registry entry: recorded version must still satisfy the constraint
      # the lock was resolved with. `version` holds the verDir component
      # (not a srcDir suffix), so compare directly.
      if not versionSatisfiesConstraint(e.version, e.constraint):
        return false
  true

proc lockToFlags*(lock: LockFile, pkgName: string,
    activeRootFeatures: seq[string]): tuple[pathFlags: seq[string],
    featureDefines: string] =
  var pathFlags: seq[string] = @[]
  var seen = initHashSet[string]()
  for e in lock.packages:
    let f = "--path:" & e.path
    if f notin seen:
      seen.incl(f)
      pathFlags.add(f)
  var featureDefines = ""
  var defined = initHashSet[string]()
  var sortedActive = activeRootFeatures
  sortedActive.sort()
  for f in sortedActive:
    let d = " -d:features." & pkgName & "." & f
    if d notin defined:
      defined.incl(d)
      featureDefines.add(d)
  for e in lock.packages:
    var feats = e.features
    feats.sort()
    for f in feats:
      let d = " -d:features." & e.name & "." & f
      if d notin defined:
        defined.incl(d)
        featureDefines.add(d)
  (pathFlags, featureDefines)

proc invalidateLock*(pkgDir: string) =
  try:
    let p = lockPathFor(pkgDir)
    if fileExists(p):
      removeFile(p)
  except CatchableError:
    discard
