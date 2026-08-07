# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## This module implements a simple package resolver using DFS (Depth-First Search) with
## cycle detection and version conflict handling.

import std/[tables, algorithm, sets, sequtils, strutils, options]
import pkg/semver

type
  VersionConstraintKind* = enum
    vcExact      ## =1.2.3
    vcGte        ## >=1.2.3
    vcGt         ## >1.2.3
    vcLte        ## <=1.2.3
    vcLt         ## <1.2.3
    vcTilde      ## ~1.2.3  (>=1.2.3 <1.3.0)
    vcCaret      ## ^1.2.3  (>=1.2.3 <2.0.0)
    vcAny        ## *

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

  ResolverError* = object of CatchableError
  CircularDependencyError* = object of ResolverError
  VersionConflictError* = object of ResolverError
  PackageNotFoundError* = object of ResolverError

  ## Registry maps package name -> available versions (sorted desc)
  PackageRegistry* = Table[string, seq[UnresolvedPackage]]

  ResolverState = object
    resolved: Table[string, ResolvedPackage]
    constraints: Table[string, seq[VersionConstraint]]
      ## accumulated (intersected) constraints per package
    activeFeatures: Table[string, seq[string]]
      ## union of features activated for each package (from `pkg[feat]`)
    visiting: HashSet[string]   ## cycle detection stack
    visited: HashSet[string]    ## fully resolved nodes

  DepProvider* = proc(name: string, version: Version,
    features: seq[string]): seq[Dependency]
    ## Lazily fetches the dependency list for a specific package version,
    ## including the requires of any activated features.

#
# Constraint parsing
#

func parseConstraint*(s: string): VersionConstraint =
  ## Parse a version constraint string into a VersionConstraint.
  ## Supports: *, =, >=, >, <=, <, ~, ^
  let s = s.strip()

  if s == "*" or s == "":
    return VersionConstraint(kind: vcAny, version: newVersion(0, 0, 0))

  if s.startsWith(">="):
    return VersionConstraint(kind: vcGte, version: parseVersion(s[2..^1].strip()))
  if s.startsWith(">"):
    return VersionConstraint(kind: vcGt, version: parseVersion(s[1..^1].strip()))
  if s.startsWith("<="):
    return VersionConstraint(kind: vcLte, version: parseVersion(s[2..^1].strip()))
  if s.startsWith("<"):
    return VersionConstraint(kind: vcLt, version: parseVersion(s[1..^1].strip()))
  if s.startsWith("~"):
    return VersionConstraint(kind: vcTilde, version: parseVersion(s[1..^1].strip()))
  if s.startsWith("^"):
    return VersionConstraint(kind: vcCaret, version: parseVersion(s[1..^1].strip()))
  if s.startsWith("="):
    return VersionConstraint(kind: vcExact, version: parseVersion(s[1..^1].strip()))

  # bare version string treated as exact
  VersionConstraint(kind: vcExact, version: parseVersion(s))

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
  addPackage(registry, UnresolvedPackage(name: name, version: version, dependencies: dependencies))

func satisfiesAll*(v: Version, constraints: openArray[VersionConstraint]): bool =
  ## Check whether `v` lies in the intersection of all constraints,
  ## i.e. satisfies every constraint at once.
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

func filterToIntersection(registry: var PackageRegistry, name: string,
    constraints: seq[VersionConstraint]) =
  ## Narrow the registry entry for `name` down to versions that lie in
  ## the intersection of all accumulated constraints. Versions outside the
  ## intersection can never satisfy all parents, so they are dropped
  ## entirely — their dependency lists are never probed.
  if name notin registry:
    return
  var kept: seq[UnresolvedPackage]
  for pkg in registry[name]:
    if satisfiesAll(pkg.version, constraints):
      kept.add(pkg)
  registry[name] = kept

func findBestMatch(registry: PackageRegistry, name: string,
    constraints: seq[VersionConstraint]): Option[UnresolvedPackage] =
  ## Return the newest package version in the intersection of constraints.
  if name notin registry:
    return none(UnresolvedPackage)
  for pkg in registry[name]:   # already sorted newest-first
    if satisfiesAll(pkg.version, constraints):
      return some(pkg)
  none(UnresolvedPackage)

#
# Core resolver  (DFS + cycle detection + constraint intersection)
#

proc resolvePackage(state: var ResolverState, registry: var PackageRegistry,
    name: string, constraint: VersionConstraint, features: seq[string],
    getDeps: DepProvider) =

  # Cycle detection: if we're already visiting this node, we have a cycle.
  if name in state.visiting:
    raise newException(CircularDependencyError,
      "Circular dependency detected: '" & name & "' is already being resolved")

  # Accumulate this constraint into the package's intersection.
  # e.g. A wants X >= 0.1.4 and B wants X >= 0.1.5 ⇒ intersection = >= 0.1.5.
  state.constraints.mgetOrPut(name, @[]).add(constraint)
  let intersection = state.constraints[name]

  # Only ever consider versions inside the intersection of ALL constraints.
  registry.filterToIntersection(name, intersection)

  # Accumulate the union of activated features (from `pkg[feat]`).
  if not state.activeFeatures.hasKey(name):
    state.activeFeatures[name] = @[]
  var featuresGrew = false
  for f in features:
    if f.len > 0 and f notin state.activeFeatures[name]:
      state.activeFeatures[name].add(f)
      featuresGrew = true
  let activeFeatures = state.activeFeatures[name]

  # Already fully resolved: keep the lock if it still lies in the
  # intersection and no new features arrived.
  if name in state.visited:
    let locked = state.resolved[name]
    if satisfiesAll(locked.version, intersection) and not featuresGrew:
      return
    # A tighter constraint or a new feature activation arrived later.
    # Unlock and re-resolve with the narrowed version set / wider features.
    state.visited.excl(name)

  let candidate = registry.findBestMatch(name, intersection)
  if candidate.isNone:
    var avail: seq[string]
    if name in registry:
      for pkg in registry[name]:
        avail.add($pkg.version)
    var constraintsStr = ""
    for c in intersection:
      if constraintsStr.len > 0:
        constraintsStr.add(" AND ")
      constraintsStr.add($c)
    raise newException(PackageNotFoundError,
      "No version of '" & name & "' satisfies constraints [" & constraintsStr &
      "], available: " & (if avail.len > 0: avail.join(", ") else: "none"))

  let pkg = candidate.get()

  # mark as being visited (cycle guard)
  state.visiting.incl(name)

  # Lazily fetch dependencies for the exact chosen candidate version,
  # including the requires of any activated features.
  let deps = getDeps(pkg.name, pkg.version, activeFeatures)
  for dep in deps:
    resolvePackage(state, registry, dep.name, dep.constraint, dep.features, getDeps)

  # done visiting – lock this package
  state.visiting.excl(name)
  state.visited.incl(name)
  state.resolved[name] = ResolvedPackage(name: pkg.name, version: pkg.version)

#
# Public API
#
proc resolve*(registry: var PackageRegistry,
    roots: seq[Dependency], getDeps: DepProvider): seq[ResolvedPackage] =
  ## Resolve a list of root dependencies against the registry.
  ## Dependency lists are fetched lazily via `getDeps` per chosen candidate.
  ## Returns the full flat list of resolved packages.
  ##
  ## Raises:
  ##   CircularDependencyError  – when a cycle is detected
  ##   VersionConflictError     – when two requirements conflict
  ##   PackageNotFoundError     – when no matching version exists
  var state = ResolverState()

  for dep in roots:
    resolvePackage(state, registry, dep.name, dep.constraint, dep.features, getDeps)

  for _, rp in state.resolved:
    result.add(rp)

when isMainModule:
  import std/[strutils]

  block intersection:
    # A wants X >= 0.1.4, B wants X >= 0.1.5 ⇒ must pick 0.1.6 (intersection).
    # X 0.1.3 / 0.1.4 are dropped entirely and never probed.
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
      echo rp
    doAssert xVer == "0.1.6", "expected intersection 0.1.6, got " & xVer

  block reResolve:
    # A wants X >= 0.1.4, B wants X >= 0.2.0.
    # First lock (0.1.6) falls out of the intersection; must re-resolve to 0.2.1.
    var registry: PackageRegistry
    registry.addPackage("X", v"0.1.4", @[])
    registry.addPackage("X", v"0.1.6", @[])
    registry.addPackage("X", v"0.2.0", @[])
    registry.addPackage("X", v"0.2.1", @[])
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"1.0.0", @[])

    var depsOf = initTable[(string, string), seq[Dependency]]()
    depsOf[("A", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.1.4"))]
    depsOf[("B", "1.0.0")] = @[Dependency(name: "X", constraint: parseConstraint(">= 0.2.0"))]

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
      echo rp
    doAssert xVer == "0.2.1", "expected re-resolved 0.2.1, got " & xVer

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
      doAssert false, "expected PackageNotFoundError for empty intersection"
    except PackageNotFoundError:
      echo "empty intersection correctly rejected"

  block features:
    # App[full] activates the `full` feature of Lib, whose deps then resolve.
    var registry: PackageRegistry
    registry.addPackage("App", v"1.0.0", @[])
    registry.addPackage("Lib", v"1.0.0", @[])
    registry.addPackage("Fancy", v"1.0.0", @[])
    registry.addPackage("Core", v"1.0.0", @[])

    # Lib's hard dep: Core. Feature "full": Fancy.
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