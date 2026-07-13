
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
    registry: PackageRegistry
    resolved: Table[string, ResolvedPackage]
    visiting: HashSet[string]   ## cycle detection stack
    visited: HashSet[string]    ## fully resolved nodes

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

func findBestMatch(registry: PackageRegistry, name: string,
    constraint: VersionConstraint): Option[UnresolvedPackage] =
  ## Return the newest package version satisfying the constraint.
  if name notin registry:
    return none(UnresolvedPackage)
  for pkg in registry[name]:   # already sorted newest-first
    if pkg.version.satisfies(constraint):
      return some(pkg)
  none(UnresolvedPackage)

#
# Core resolver  (DFS + cycle detection)
#

proc resolvePackage(state: var ResolverState, name: string,
    constraint: VersionConstraint) =

  # Cycle detection: if we're already visiting this node, we have a cycle.
  if name in state.visiting:
    raise newException(CircularDependencyError,
      "Circular dependency detected: '" & name & "' is already being resolved")

  # already fully resolved: verify the locked version still satisfie
  if name in state.visited:
    let locked = state.resolved[name]
    if not locked.version.satisfies(constraint):
      raise newException(VersionConflictError,
        "Version conflict for '" & name & "': locked at " &
        $locked.version & " but constraint " & $constraint.version &
        " is not satisfied")
    return

  # look up best candidate
  let candidate = state.registry.findBestMatch(name, constraint)
  if candidate.isNone:
    raise newException(PackageNotFoundError,
      "No version of '" & name & "' satisfies constraint")

  let pkg = candidate.get()

  # mark as being visited (cycle guard)
  state.visiting.incl(name)

  # recurse into dependencies
  for dep in pkg.dependencies:
    let depConstraint = dep.constraint
    state.resolvePackage(dep.name, depConstraint)

  # done visiting – lock this package
  state.visiting.excl(name)
  state.visited.incl(name)
  state.resolved[name] = ResolvedPackage(name: pkg.name, version: pkg.version)

#
# Public API
#
proc resolve*(registry: PackageRegistry,
    roots: seq[Dependency]): seq[ResolvedPackage] =
  ## Resolve a list of root dependencies against the registry.
  ## Returns the full flat list of resolved packages.
  ##
  ## Raises:
  ##   CircularDependencyError  – when a cycle is detected
  ##   VersionConflictError     – when two requirements conflict
  ##   PackageNotFoundError     – when no matching version exists
  var state = ResolverState(registry: registry)

  for dep in roots:
    state.resolvePackage(dep.name, dep.constraint)

  for _, rp in state.resolved:
    result.add(rp)

func `$`*(c: VersionConstraint): string =
  case c.kind
  of vcAny:   "*"
  of vcExact: "=" & $c.version
  of vcGte:   ">=" & $c.version
  of vcGt:    ">" & $c.version
  of vcLte:   "<=" & $c.version
  of vcLt:    "<" & $c.version
  of vcTilde: "~" & $c.version
  of vcCaret: "^" & $c.version

func `$`*(rp: ResolvedPackage): string =
  rp.name & "@" & $rp.version

when isMainModule:
  var registry: PackageRegistry
  registry.addPackage(
    UnresolvedPackage(
      name: "httpx",
      version: v"2.1.0",
      dependencies: @[
        Dependency(name: "chronos", constraint: parseConstraint("^3.0.0"))
      ]
  ))
  registry.addPackage("httpx", v"2.0.0", @[
    Dependency(name: "chronos", constraint: parseConstraint("~2.5.0"))
  ])
  registry.addPackage("chronos", v"2.5.3", @[])

  let roots = @[
    Dependency(name: "httpx", constraint: parseConstraint(">=2.0.0"))
  ]

  let resolved = registry.resolve(roots)
  for rp in resolved:
    echo rp   # httpx@2.1.0, chronos@3.2.1