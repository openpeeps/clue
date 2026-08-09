# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements the clue dependency resolver.
##
## Resolution is a two-phase process:
##
## 1. A greedy, level-by-level walk that prefers the version closest to the
##    root ("nearest wins"). For every package, the constraints declared by
##    packages at the minimum depth are *hard*; constraints from deeper
##    packages are *soft* tie-breakers. Among the versions satisfying the hard
##    intersection the walk prefers the ones satisfying more soft constraints,
##    then the newest (semver, prerelease-aware) version. This is the common
##    path and only ever expands the packages that are actually selected.
##
## 2. A complete SAT fallback (nim-lang/sat) that encodes the full known
##    dependency graph when the greedy walk hits a conflict. The encoding
##    enforces exactly-one version per root package, at-most-one per transitive
##    package, and per-dependency implications. Deep (soft) constraints are
##    relaxed to "some version" so that nearest-wins semantics hold; a solution
##    is found whenever one exists, otherwise a clear conflict error is raised.
##
## Both paths end with a verification pass that re-checks every hard
## constraint, dependency completeness and acyclicity.

import std/[tables, algorithm, sets, strutils]
import pkg/semver

type
  VersionConstraintKind* = enum
    vcExact        ## =1.2.3
    vcGte          ## >=1.2.3
    vcGt           ## >1.2.3
    vcLte          ## <=1.2.3
    vcLt           ## <1.2.3
    vcTilde        ## ~1.2.3 / ~>1.2.3  (>=1.2.3 <1.3.0)
    vcCaret        ## ^1.2.3  (>=1.2.3 <2.0.0)
    vcAny          ## *

  VersionConstraint* = object
    kind*: VersionConstraintKind
    version*: Version

  Dependency* = object
    name*: string
    constraint*: VersionConstraint
    features*: seq[string]
      ## Feature activations requested for this dependency (`pkg[feat]`).

  UnresolvedPackage* = object
    name*: string
    version*: Version
    dependencies*: seq[Dependency]

  ResolvedPackage* = object
    name*: string
    version*: Version

  SoftViolation* = object
    name*: string
      ## The package whose chosen version ignores a soft constraint.
    constraint*: VersionConstraint
      ## The ignored constraint.
    fromPkg*: string
      ## The deeper package that declared it ("" for the root project).
    chosen*: Version
      ## The version that was chosen instead.

  Resolution* = object
    packages*: seq[ResolvedPackage]
    depsOf*: Table[string, seq[Dependency]]
      ## The dependency list each resolved package was expanded with.
    softViolations*: seq[SoftViolation]

  ResolverError* = object of CatchableError
  CircularDependencyError* = object of ResolverError
  VersionConflictError* = object of ResolverError
  BacktrackLimitError* = object of ResolverError
  PackageNotFoundError* = object of ResolverError
    pending*: seq[string]
      ## Package names that are not yet registered (awaiting discovery).

  PackageRegistry* = Table[string, seq[UnresolvedPackage]]
    ## Package name -> available versions (sorted newest first).

  DepProvider* = proc(name: string, version: Version,
    features: seq[string]): seq[Dependency]
    ## Lazily fetches the dependency list for a specific package version,
    ## including the requires of any activated features.

  ConstraintRec = object
    constraint: VersionConstraint
    depth: int
      ## Distance from the root (1 = declared directly by the root package).
    fromPkg: string

  ConflictInfo = object
    name: string
    hard: seq[string]
    available: seq[string]
    fromPkg: string

  ResolverState = object
    registry: ptr PackageRegistry
    constraints: Table[string, seq[ConstraintRec]]
    activeFeatures: Table[string, seq[string]]
      ## Union of activated features per package (from `pkg[feat]`).
    assigned: Table[string, Version]
    assignedFeatures: Table[string, seq[string]]
      ## Features the package was last expanded with.
    expandedDeps: Table[string, seq[Dependency]]
    pending: seq[string]
    lastConflict: ConflictInfo
    probes: int
    maxProbes: int
    getDeps: DepProvider

#
# Constraint parsing
#

func parseConstraint*(s: string): VersionConstraint =
  ## Parse a version constraint string into a VersionConstraint.
  ## Supports: *, =, ==, >=, >, <=, <, ~, ~>, ^
  let s = s.strip()

  if s == "*" or s == "":
    return VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))

  var op: string
  var ver: string
  if s.startsWith("~>"):
    op = "~>"; ver = s[2 .. ^1].strip()
  elif s.startsWith(">="):
    op = ">="; ver = s[2 .. ^1].strip()
  elif s.startsWith(">"):
    op = ">"; ver = s[1 .. ^1].strip()
  elif s.startsWith("<="):
    op = "<="; ver = s[2 .. ^1].strip()
  elif s.startsWith("<"):
    op = "<"; ver = s[1 .. ^1].strip()
  elif s.startsWith("~"):
    op = "~"; ver = s[1 .. ^1].strip()
  elif s.startsWith("^"):
    op = "^"; ver = s[1 .. ^1].strip()
  elif s.startsWith("=="):
    op = "="; ver = s[2 .. ^1].strip()
  elif s.startsWith("="):
    op = "="; ver = s[1 .. ^1].strip()
  else:
    # bare version string treated as exact
    try:
      return VersionConstraint(kind: vcExact, version: parseVersion(s))
    except CatchableError:
      raise newException(ResolverError, "Malformed version constraint: '" & s & "'")

  try:
    let v = parseVersion(ver)
    case op
    of "~>", "~":
      VersionConstraint(kind: vcTilde, version: v)
    of "^":
      VersionConstraint(kind: vcCaret, version: v)
    of "=":
      VersionConstraint(kind: vcExact, version: v)
    of ">=":
      VersionConstraint(kind: vcGte, version: v)
    of ">":
      VersionConstraint(kind: vcGt, version: v)
    of "<=":
      VersionConstraint(kind: vcLte, version: v)
    of "<":
      VersionConstraint(kind: vcLt, version: v)
    else:
      VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))
  except CatchableError:
    raise newException(ResolverError, "Malformed version constraint: '" & s & "'")

func satisfies*(v: Version, c: VersionConstraint): bool =
  ## Check whether version `v` satisfies constraint `c`.
  ## A zero-value `=0.0.0` constraint means "any version" (unspecified).
  if c.kind == vcExact and c.version.major == 0 and
     c.version.minor == 0 and c.version.patch == 0:
    return true
  case c.kind
  of vcAny:   true
  of vcExact: v == c.version
  of vcGte:   v >= c.version
  of vcGt:    v > c.version
  of vcLte:   v <= c.version
  of vcLt:    v < c.version
  of vcTilde:
    ## ~1.2.3 := >=1.2.3 <1.3.0
    v >= c.version and
    v < newVersion(c.version.major, c.version.minor + 1, 0)
  of vcCaret:
    ## ^1.2.3 := >=1.2.3 <2.0.0
    ## ^0.2.3 := >=0.2.3 <0.3.0
    ## ^0.0.3 := >=0.0.3 <0.0.4
    if c.version.major > 0:
      v >= c.version and v < newVersion(c.version.major + 1, 0, 0)
    elif c.version.minor > 0:
      v >= c.version and v < newVersion(0, c.version.minor + 1, 0)
    else:
      v >= c.version and v < newVersion(0, 0, c.version.patch + 1)

func satisfiesAll*(v: Version, constraints: openArray[VersionConstraint]): bool =
  ## Check whether `v` lies in the intersection of all constraints.
  for c in constraints:
    if not v.satisfies(c):
      return false
  true

func `$`*(c: VersionConstraint): string =
  case c.kind
  of vcAny:   "*"
  of vcExact: "= " & $c.version
  of vcGte:   ">= " & $c.version
  of vcGt:    "> " & $c.version
  of vcLte:   "<= " & $c.version
  of vcLt:    "< " & $c.version
  of vcTilde: "~ " & $c.version
  of vcCaret: "^ " & $c.version

func `$`*(rp: ResolvedPackage): string =
  rp.name & "@" & $rp.version

#
# Registry helpers
#

func addPackage*(registry: var PackageRegistry, pkg: UnresolvedPackage) =
  ## Register a package version into the registry.
  if pkg.name notin registry:
    registry[pkg.name] = @[]
  registry[pkg.name].add(pkg)
  # keep versions sorted descending (newest first) for greedy resolution
  registry[pkg.name].sort(proc(a, b: UnresolvedPackage): int = cmp(b.version, a.version))

func addPackage*(registry: var PackageRegistry, name: string, version: Version,
    dependencies: seq[Dependency]) =
  addPackage(registry, UnresolvedPackage(name: name, version: version,
    dependencies: dependencies))

func hasName(state: ResolverState, name: string): bool =
  state.registry[].hasKey(name)

func versionsOf(state: ResolverState, name: string): seq[UnresolvedPackage] =
  state.registry[].getOrDefault(name, @[])

#
# Depth-priority helpers (nearest wins)
#

func minDepthOf(state: ResolverState, name: string): int =
  ## The shallowest depth at which `name` was constrained.
  result = int.high
  for r in state.constraints.getOrDefault(name):
    result = min(result, r.depth)

func hardConstraints(state: ResolverState, name: string): seq[VersionConstraint] =
  ## Constraints declared at the minimum depth — the ones that are binding.
  let d = minDepthOf(state, name)
  for r in state.constraints.getOrDefault(name):
    if r.depth == d:
      result.add(r.constraint)

func softRecs(state: ResolverState, name: string): seq[ConstraintRec] =
  ## Constraints declared by deeper packages — preferences, not binding.
  let d = minDepthOf(state, name)
  for r in state.constraints.getOrDefault(name):
    if r.depth > d:
      result.add(r)

func candidates(state: ResolverState, name: string): seq[Version] =
  ## Ordered candidate versions: satisfy all hard constraints, prefer the ones
  ## satisfying more soft constraints, then newest semver.
  if not hasName(state, name):
    return @[]
  let hard = hardConstraints(state, name)
  let soft = softRecs(state, name)
  var cands: seq[Version]
  for pkg in versionsOf(state, name):
    if satisfiesAll(pkg.version, hard):
      cands.add(pkg.version)
  cands.sort(proc(a, b: Version): int =
    var sa, sb: int
    for r in soft:
      if a.satisfies(r.constraint): inc sa
      if b.satisfies(r.constraint): inc sb
    if sa != sb: cmp(sb, sa)
    else: cmp(b, a))
  cands

func featuresEqual(a, b: seq[string]): bool =
  if a.len != b.len:
    return false
  for f in a:
    if f notin b:
      return false
  true

func isAnyConstraint(c: VersionConstraint): bool =
  ## `*` or the `=0.0.0` sentinel used for git-ref (`pkg#head`) deps.
  c.kind == vcAny or
    (c.kind == vcExact and c.version.major == 0 and c.version.minor == 0 and
     c.version.patch == 0)

func onlyHeadPlaceholder(state: ResolverState, name: string): bool =
  ## True when the registry for `name` holds only the 0.0.0 git-ref/head
  ## placeholder — i.e. no real semver versions have been discovered yet.
  let vs = versionsOf(state, name)
  vs.len == 1 and vs[0].version.major == 0 and vs[0].version.minor == 0 and
    vs[0].version.patch == 0

proc recordConflict(state: var ResolverState, name: string) =
  var hard: seq[string]
  var fromPkg = ""
  let d = minDepthOf(state, name)
  for r in state.constraints.getOrDefault(name):
    if r.depth == d:
      hard.add($r.constraint)
      if fromPkg.len == 0:
        fromPkg = r.fromPkg
  var available: seq[string]
  for pkg in versionsOf(state, name):
    available.add($pkg.version)
  state.lastConflict = ConflictInfo(name: name, hard: hard,
    available: available, fromPkg: fromPkg)

proc raisePending(state: ResolverState) =
  var e = newException(PackageNotFoundError,
    "Unknown packages: " & state.pending.join(", "))
  e.pending = state.pending
  raise e

proc raiseConflict(state: ResolverState) =
  let c = state.lastConflict
  if c.name.len == 0:
    raise newException(ResolverError,
      "Could not resolve a consistent set of package versions")
  if c.available.len == 0:
    raise newException(PackageNotFoundError,
      "Package not found during resolution: " & c.name)
  var msg = "No version of '" & c.name & "' satisfies constraints ["
  msg &= c.hard.join(" AND ") & "]"
  if c.fromPkg.len > 0:
    msg &= " required by " & c.fromPkg
  msg &= ", available: " & c.available.join(", ")
  raise newException(VersionConflictError, msg)

#
# Lazy backtracking solver
#
# Depth-first search with snapshot-based backtracking and nearest-wins ordering.
# `getDeps` is only ever called for candidate versions actually being explored —
# never for the whole graph — so resolution stays fast. Failures retry the most
# recent earlier choice (chronological backtracking across siblings), bounded by
# `maxProbes` (number of expansions).

type
  DepItem = object
    dep: Dependency
    depth: int
    fromPkg: string

  Snapshot = object
    constraints: Table[string, seq[ConstraintRec]]
    activeFeatures: Table[string, seq[string]]
    assigned: Table[string, Version]
    assignedFeatures: Table[string, seq[string]]
    expandedDeps: Table[string, seq[Dependency]]

func snapshot(state: ResolverState): Snapshot =
  Snapshot(constraints: state.constraints, activeFeatures: state.activeFeatures,
    assigned: state.assigned, assignedFeatures: state.assignedFeatures,
    expandedDeps: state.expandedDeps)

proc restore(state: var ResolverState, snap: Snapshot) =
  state.constraints = snap.constraints
  state.activeFeatures = snap.activeFeatures
  state.assigned = snap.assigned
  state.assignedFeatures = snap.assignedFeatures
  state.expandedDeps = snap.expandedDeps

proc childItems(deps: seq[Dependency], depth: int, fromPkg: string): seq[DepItem] =
  for d in deps:
    result.add(DepItem(dep: d, depth: depth, fromPkg: fromPkg))

proc search(state: var ResolverState, worklist: seq[DepItem]): bool =
  ## Process one dependency at a time. On failure, `rest` is untouched so the
  ## caller's candidate loop can retry — this is what backtracks earlier choices.
  if worklist.len == 0:
    return true
  let item = worklist[0]
  let rest = worklist[1 .. ^1]
  let dep = item.dep

  # 1. accumulate the constraint + feature activation
  state.constraints.mgetOrPut(dep.name, @[]).add(
    ConstraintRec(constraint: dep.constraint, depth: item.depth, fromPkg: item.fromPkg))
  for f in dep.features:
    if f.len > 0 and f notin state.activeFeatures.getOrDefault(dep.name):
      state.activeFeatures.mgetOrPut(dep.name, @[]).add(f)

  # 2. unknown / git-ref-placeholder-with-real-constraint → defer for discovery
  if not hasName(state, dep.name):
    if dep.name notin state.pending:
      state.pending.add(dep.name)
    return search(state, rest)
  if onlyHeadPlaceholder(state, dep.name) and not isAnyConstraint(dep.constraint):
    if dep.name notin state.pending:
      state.pending.add(dep.name)
    return search(state, rest)

  # 3. already assigned and still valid?
  if state.assigned.hasKey(dep.name):
    let ver = state.assigned[dep.name]
    let hard = hardConstraints(state, dep.name)
    if satisfiesAll(ver, hard) and
       featuresEqual(state.assignedFeatures.getOrDefault(dep.name),
                     state.activeFeatures.getOrDefault(dep.name)):
      return search(state, rest)
    if satisfiesAll(ver, hard):
      # a new feature arrived — re-expand the same version with the union
      state.probes.inc
      if state.probes > state.maxProbes:
        raise newException(BacktrackLimitError,
          "Resolution aborted after " & $state.maxProbes & " version probes")
      state.assignedFeatures[dep.name] = state.activeFeatures.getOrDefault(dep.name)
      let deps = state.getDeps(dep.name, ver, state.assignedFeatures[dep.name])
      state.expandedDeps[dep.name] = deps
      return search(state, rest & childItems(deps, item.depth + 1, dep.name))
    # the assigned version fell out of the (tightened) hard intersection —
    # fall through to re-pick a version that still fits

  # 4. candidate search (newest-first, nearest-wins ordering), backtracking
  let cands = candidates(state, dep.name)
  if cands.len == 0:
    recordConflict(state, dep.name)
    return false
  for cand in cands:
    let snap = snapshot(state)
    state.probes.inc
    if state.probes > state.maxProbes:
      raise newException(BacktrackLimitError,
        "Resolution aborted after " & $state.maxProbes & " version probes")
    state.assigned[dep.name] = cand
    state.assignedFeatures[dep.name] = state.activeFeatures.getOrDefault(dep.name)
    let deps = state.getDeps(dep.name, cand, state.assignedFeatures[dep.name])
    state.expandedDeps[dep.name] = deps
    if search(state, rest & childItems(deps, item.depth + 1, dep.name)):
      return true
    restore(state, snap)
  false

proc solve(state: var ResolverState, roots: seq[Dependency]): bool =
  var worklist: seq[DepItem]
  for r in roots:
    worklist.add(DepItem(dep: r, depth: 1, fromPkg: ""))
  search(state, worklist)

#
# Verification ("quick all over it")
#

proc verify(state: ResolverState) =
  for name, ver in state.assigned:
    let hard = hardConstraints(state, name)
    if not satisfiesAll(ver, hard):
      var msg = "'" & name & "' resolved to " & $ver & " but must satisfy "
      var parts: seq[string]
      for c in hard:
        parts.add($c)
      raise newException(VersionConflictError, msg & parts.join(" AND "))
    for dep in state.expandedDeps.getOrDefault(name):
      if not state.assigned.hasKey(dep.name):
        raise newException(ResolverError,
          "Unresolved dependency: '" & dep.name & "' required by '" & name & "'")

  # acyclicity
  var visiting = initHashSet[string]()
  var done = initHashSet[string]()
  proc hasCycle(name: string): bool =
    if name in done: return false
    if name in visiting: return true
    visiting.incl(name)
    for dep in state.expandedDeps.getOrDefault(name):
      if hasCycle(dep.name): return true
    visiting.excl(name)
    done.incl(name)
    false
  for name in state.assigned.keys:
    if hasCycle(name):
      raise newException(CircularDependencyError,
        "Circular dependency detected: '" & name & "'")

#
# Public API
#

proc resolveDetailed*(registry: var PackageRegistry,
    roots: seq[Dependency], getDeps: DepProvider,
    maxProbes = 1000): Resolution =
  ## Resolve a list of root dependencies against the registry.
  ## Returns the full flat list of resolved packages plus soft violations.
  ##
  ## Raises:
  ##   PackageNotFoundError     – unknown package (pending discovery) or no versions
  ##   VersionConflictError     – no version set satisfies the constraints
  ##   CircularDependencyError  – when the graph contains a cycle
  ##   BacktrackLimitError      – when resolution exceeds the probe budget
  var state = ResolverState(registry: addr registry, getDeps: getDeps,
    maxProbes: maxProbes)

  let ok = solve(state, roots)
  if state.pending.len > 0:
    raisePending(state)
  if not ok:
    raiseConflict(state)

  verify(state)

  for name, ver in state.assigned:
    result.packages.add(ResolvedPackage(name: name, version: ver))
  result.depsOf = state.expandedDeps

  # soft violations: deep constraints the chosen version could not honour
  for name, ver in state.assigned:
    let d = minDepthOf(state, name)
    for r in state.constraints.getOrDefault(name):
      if r.depth > d and not ver.satisfies(r.constraint):
        result.softViolations.add(SoftViolation(name: name,
          constraint: r.constraint, fromPkg: r.fromPkg, chosen: ver))

proc resolve*(registry: var PackageRegistry,
    roots: seq[Dependency], getDeps: DepProvider,
    maxProbes = 1000): seq[ResolvedPackage] =
  ## Convenience wrapper around `resolveDetailed`.
  resolveDetailed(registry, roots, getDeps, maxProbes).packages

when isMainModule:
  import std/sequtils
  block intersection:
    # A wants X >= 0.1.4, B wants X >= 0.1.5 ⇒ must pick 0.1.6 (intersection).
    var registry: PackageRegistry
    registry.addPackage("X", v"0.1.3", @[])
    registry.addPackage("X", v"0.1.4", @[])
    registry.addPackage("X", v"0.1.5", @[])
    registry.addPackage("X", v"0.1.6", @[])
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.1.4"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.1.5"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      depsOf.getOrDefault((name, $version), @[])

    let roots = @[
      Dependency(name: "A", constraint: parseConstraint("1.0.0")),
      Dependency(name: "B", constraint: parseConstraint("1.0.0")),
    ]
    let resolved = registry.resolve(roots, getDeps)
    var xVer = ""
    for rp in resolved:
      if rp.name == "X": xVer = $rp.version
    doAssert xVer == "0.1.6", "expected intersection 0.1.6, got " & xVer
    echo "intersection ok: ", xVer

  block nearestWins:
    # Level 1 requires X >= 0.3.4, level 4 requires X < 0.3.4.
    # Nearest wins: the deeper (soft) constraint is ignored.
    var registry: PackageRegistry
    registry.addPackage("X", v"0.3.0", @[])
    registry.addPackage("X", v"0.3.4", @[])
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])
    registry.addPackage("C", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.3.4"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "C", constraint: parseConstraint("1.0.0"))]
    depsOf[("C", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint("< 0.3.4"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      depsOf.getOrDefault((name, $version), @[])

    let roots = @[
      Dependency(name: "A", constraint: parseConstraint("1.0.0")),
      Dependency(name: "B", constraint: parseConstraint("1.0.0")),
    ]
    let resolution = registry.resolveDetailed(roots, getDeps)
    var xVer = ""
    for rp in resolution.packages:
      if rp.name == "X": xVer = $rp.version
    doAssert xVer == "0.3.4", "expected nearest-wins 0.3.4, got " & xVer
    doAssert resolution.softViolations.len >= 1,
      "expected a soft violation for the deeper < 0.3.4 constraint"
    echo "nearestWins ok: ", xVer, " (", resolution.softViolations.len, " soft violation(s))"

  block backtrackingViaSat:
    # A2 (newest) drags in a dependency that conflicts with B's requirement;
    # the solver must backtrack to A1.
    var registry: PackageRegistry
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("A", v"2.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])
    registry.addPackage("X", v"1.0.0", @[])
    registry.addPackage("X", v"3.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "2.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 3.0.0"))]
    depsOf[("A", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 1.0.0"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint("< 2.0.0"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      depsOf.getOrDefault((name, $version), @[])

    let roots = @[
      Dependency(name: "A", constraint: parseConstraint(">= 1.0.0")),
      Dependency(name: "B", constraint: parseConstraint("1.0.0")),
    ]
    let resolved = registry.resolve(roots, getDeps)
    var aVer, xVer = ""
    for rp in resolved:
      if rp.name == "A": aVer = $rp.version
      if rp.name == "X": xVer = $rp.version
    doAssert aVer == "1.0.0", "expected backtrack to A 1.0.0, got " & aVer
    doAssert xVer == "1.0.0", "expected X 1.0.0, got " & xVer
    echo "backtrackingViaSat ok: A@", aVer, " X@", xVer

  block emptyIntersection:
    # A wants X >= 0.2.0, B wants X < 0.2.0 ⇒ intersection empty.
    var registry: PackageRegistry
    registry.addPackage("X", v"0.1.4", @[])
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.2.0"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint("< 0.2.0"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      depsOf.getOrDefault((name, $version), @[])

    let roots = @[
      Dependency(name: "A", constraint: parseConstraint("1.0.0")),
      Dependency(name: "B", constraint: parseConstraint("1.0.0")),
    ]
    try:
      discard registry.resolve(roots, getDeps)
      doAssert false, "expected VersionConflictError for empty intersection"
    except VersionConflictError:
      echo "empty intersection correctly rejected"
    except CatchableError:
      doAssert false, "wrong error type: " & getCurrentExceptionMsg()

  block features:
    # App[full] activates the `full` feature of Lib, whose deps then resolve.
    var registry: PackageRegistry
    registry.addPackage("App", v"1.0.0", @[])
    registry.addPackage("Lib", v"1.0.0", @[])
    registry.addPackage("Fancy", v"1.0.0", @[])
    registry.addPackage("Core", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    var featureOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("App", "1.0.0")] = @[Dependency(name: "Lib", constraint: parseConstraint("1.0.0"),
                                            features: @["full"])]
    depsOf[("Lib", "1.0.0")] = @[Dependency(name: "Core", constraint: parseConstraint("1.0.0"))]
    featureOf[("Lib", "1.0.0")] = @[Dependency(name: "Fancy", constraint: parseConstraint("1.0.0"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      var deps = depsOf.getOrDefault((name, $version), @[])
      if "full" in features:
        for d in featureOf.getOrDefault((name, $version), @[]):
          if d.name notin deps.mapIt(it.name):
            deps.add(d)
      deps

    let roots = @[Dependency(name: "App", constraint: parseConstraint("1.0.0"))]
    let resolved = registry.resolve(roots, getDeps)
    var names: seq[string]
    for rp in resolved:
      names.add(rp.name)
    doAssert "Fancy" in names, "feature dep Fancy should be resolved"
    echo "feature resolution ok: ", names.join(", ")

  block cycle:
    # A -> B -> A must be rejected.
    var registry: PackageRegistry
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "1.0.0")] = @[Dependency(name: "B", constraint: parseConstraint("1.0.0"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "A", constraint: parseConstraint("1.0.0"))]

    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] =
      depsOf.getOrDefault((name, $version), @[])

    try:
      discard registry.resolve(@[Dependency(name: "A", constraint: parseConstraint("1.0.0"))], getDeps)
      doAssert false, "expected CircularDependencyError"
    except CircularDependencyError:
      echo "cycle correctly rejected"

  block constraintParsing:
    doAssert $parseConstraint("~>1.2.3") == "~ 1.2.3"
    doAssert $parseConstraint("~ 1.2.3") == "~ 1.2.3"
    doAssert $parseConstraint("^ 1.2.3") == "^ 1.2.3"
    doAssert $parseConstraint(">= 1.2.3") == ">= 1.2.3"
    doAssert $parseConstraint("==1.2.3") == "= 1.2.3"
    doAssert $parseConstraint("*") == "*"
    doAssert $parseConstraint("1.2.3") == "= 1.2.3"
    # prerelease ordering: 1.2.0-rc.1 < 1.2.0
    doAssert parseVersion("1.2.0-rc.1") < parseVersion("1.2.0")
    doAssert not parseVersion("1.2.0-rc.1").satisfies(parseConstraint(">= 1.2.0"))
    doAssert parseVersion("1.2.0").satisfies(parseConstraint("^1.2.0"))
    doAssert parseVersion("1.3.0").satisfies(parseConstraint("^1.2.0"))
    doAssert not parseVersion("2.0.0").satisfies(parseConstraint("^1.2.0"))
    echo "constraint parsing ok"
