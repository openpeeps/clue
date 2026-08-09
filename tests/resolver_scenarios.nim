# Clue resolver scenarios — simulated package trees.
#
# Exercises the resolver against deterministic in-memory dependency graphs
# (no git, no network): newest-first selection, constraint intersection,
# nearest-wins depth priority, SAT backtracking, git-ref placeholders,
# features, cycles, prereleases and error reporting.

import std/[tables, unittest]
import pkg/semver
import clue/pkgmanager/resolver

type
  SimDep = object
    name: string
    constraint: string
    features: seq[string]

  SimPkg = object
    name: string
    version: string
    deps: seq[SimDep]
    features: Table[string, seq[SimDep]]

func simDep*(name, constraint: string, features: seq[string] = @[]): SimDep =
  SimDep(name: name, constraint: constraint, features: features)

func simPkg*(name, version: string, deps: seq[SimDep] = @[],
    features: Table[string, seq[SimDep]] = initTable[string, seq[SimDep]]()): SimPkg =
  SimPkg(name: name, version: version, deps: deps, features: features)

proc toDep(d: SimDep): Dependency =
  Dependency(name: d.name, constraint: parseConstraint(d.constraint), features: d.features)

proc makeSim*(pkgs: openArray[SimPkg]): (PackageRegistry, DepProvider) =
  ## Build a registry + provider from a simulated package tree.
  var registry: PackageRegistry
  var depsOf = initTable[(string, string), seq[Dependency]]()
  var featOf = initTable[(string, string), Table[string, seq[Dependency]]]()
  for p in pkgs:
    registry.addPackage(UnresolvedPackage(name: p.name,
      version: parseVersion(p.version), dependencies: @[]))
    var deps: seq[Dependency]
    for d in p.deps:
      deps.add(toDep(d))
    depsOf[(p.name, p.version)] = deps
    if p.features.len > 0:
      var fmap: Table[string, seq[Dependency]]
      for fname, fdeps in p.features:
        var arr: seq[Dependency]
        for d in fdeps:
          arr.add(toDep(d))
        fmap[fname] = arr
      featOf[(p.name, p.version)] = fmap
  proc provider(name: string, version: Version, features: seq[string]): seq[Dependency] =
    result = depsOf.getOrDefault((name, $version), @[])
    for f in features:
      for d in featOf.getOrDefault((name, $version)).getOrDefault(f, @[]):
        result.add(d)
  (registry, provider)

proc root*(name: string, constraint = "*"): Dependency =
  Dependency(name: name, constraint: parseConstraint(constraint))

proc versionOf(res: Resolution, name: string): string =
  for rp in res.packages:
    if rp.name == name:
      return $rp.version
  ""

suite "resolver scenarios":
  test "newest first":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0"), simPkg("R", "2.0.0"), simPkg("R", "3.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "R") == "3.0.0"

  test "constraint intersection":
    # A wants X >= 0.1.4, B wants X >= 0.1.5 -> 0.1.6
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("X", ">= 0.1.4")]),
      simPkg("B", "1.0.0", @[simDep("X", ">= 0.1.5")]),
      simPkg("X", "0.1.3"), simPkg("X", "0.1.4"), simPkg("X", "0.1.5"),
      simPkg("X", "0.1.6"),
    ])
    let res = registry.resolveDetailed(@[root("A"), root("B")], provider)
    check versionOf(res, "X") == "0.1.6"

  test "nearest wins (depth priority)":
    # Level 1 requires X >= 0.3.4, a deeper package requires X < 0.3.4.
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("X", ">= 0.3.4")]),
      simPkg("B", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("C", "1.0.0", @[simDep("X", "< 0.3.4")]),
      simPkg("X", "0.3.0"), simPkg("X", "0.3.4"),
    ])
    let res = registry.resolveDetailed(@[root("A"), root("B")], provider)
    check versionOf(res, "X") == "0.3.4"
    check res.softViolations.len >= 1

  test "backtracking: newer root version is unsatisfiable":
    # A2.0 drags in X >= 3.0 which conflicts with B's X < 2.0.
    var (registry, provider) = makeSim([
      simPkg("A", "2.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "< 2.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "3.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("A"), root("B")], provider)
    check versionOf(res, "A") == "1.0.0"
    check versionOf(res, "X") == "1.0.0"

  test "backtracking: newer transitive version is unsatisfiable (supranim/powpow)":
    # R requires A and B. A0.1.8 needs powpow >= 0.1.8 (unreleased); A0.1.7
    # needs powpow >= 0.1.4. R must stay, A must drop to 0.1.7.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", ">= 0.1.0"), simDep("B", ">= 0.1.0")]),
      simPkg("A", "0.1.8", @[simDep("powpow", ">= 0.1.8")]),
      simPkg("A", "0.1.7", @[simDep("powpow", ">= 0.1.4")]),
      simPkg("B", "1.0.0"),
      simPkg("powpow", "0.1.4"), simPkg("powpow", "0.1.7"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "R") == "1.0.0"
    check versionOf(res, "A") == "0.1.7"
    check versionOf(res, "powpow") == "0.1.7"

  test "root version preference: pick the newest satisfiable root":
    # tim 0.2.7 depends on A which needs an unreleased Y; tim 0.2.6 depends on B.
    var (registry, provider) = makeSim([
      simPkg("tim", "0.2.7", @[simDep("A", ">= 0.1.0")]),
      simPkg("tim", "0.2.6", @[simDep("B", ">= 0.1.0")]),
      simPkg("A", "0.1.0", @[simDep("Y", ">= 2.0.0")]),
      simPkg("B", "0.1.0"),
      simPkg("Y", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("tim")], provider)
    check versionOf(res, "tim") == "0.2.6"

  test "re-pick when an assigned version falls out of the intersection":
    # A wants X >= 1.0 (greedy picks 3.0), then B wants X < 2.0.
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "< 2.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "3.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("A"), root("B")], provider)
    check versionOf(res, "X") == "1.0.0"

  test "empty intersection raises VersionConflictError":
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("X", ">= 0.2.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "< 0.2.0")]),
      simPkg("X", "0.1.4"),
    ])
    expect VersionConflictError:
      discard registry.resolveDetailed(@[root("A"), root("B")], provider)

  test "cycle raises CircularDependencyError":
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("A")], provider)

  test "feature activation adds feature deps":
    var (registry, provider) = makeSim([
      simPkg("App", "1.0.0", @[simDep("Lib", "1.0.0", @["full"])]),
      simPkg("Lib", "1.0.0", @[simDep("Core", "1.0.0")],
        {"full": @[simDep("Fancy", "1.0.0")]}.toTable),
      simPkg("Core", "1.0.0"),
      simPkg("Fancy", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("App")], provider)
    check versionOf(res, "Fancy") == "1.0.0"

  test "git-ref placeholder + semver constraint: discover then resolve":
    # bag requires valido#head (0.0.0 placeholder); kapsis requires valido >= 0.1.0.
    var (registry, provider) = makeSim([
      simPkg("bag", "1.0.0", @[simDep("valido", "0.0.0")]),
      simPkg("kapsis", "1.0.0", @[simDep("valido", ">= 0.1.0")]),
      simPkg("valido", "0.0.0"),
    ])
    # first resolve: valido only has the 0.0.0 placeholder -> pending discovery
    expect PackageNotFoundError:
      discard registry.resolveDetailed(@[root("bag"), root("kapsis")], provider)
    # simulate the discovery step: valido's real version arrives
    registry.addPackage(UnresolvedPackage(name: "valido",
      version: parseVersion("0.1.0"), dependencies: @[]))
    let res = registry.resolveDetailed(@[root("bag"), root("kapsis")], provider)
    check versionOf(res, "valido") == "0.1.0"

  test "unknown package raises PackageNotFoundError with pending":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("MysteryPkg", "*")]),
    ])
    try:
      discard registry.resolveDetailed(@[root("R")], provider)
      check false
    except PackageNotFoundError as e:
      check "MysteryPkg" in e.pending

  test "prerelease versions are ordered correctly":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("X", ">= 1.2.0")]),
      simPkg("X", "1.1.0"),
      simPkg("X", "1.2.0-rc.1"),
      simPkg("X", "1.2.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "1.2.0"

  test "constraint parsing and satisfaction":
    check $parseConstraint("~>1.2.3") == "~ 1.2.3"
    check $parseConstraint("==1.2.3") == "= 1.2.3"
    check $parseConstraint("*") == "*"
    check $parseConstraint("1.2.3") == "= 1.2.3"
    check parseVersion("1.2.0-rc.1") < parseVersion("1.2.0")
    check not parseVersion("1.2.0-rc.1").satisfies(parseConstraint(">= 1.2.0"))
    check parseVersion("1.3.0").satisfies(parseConstraint("^1.2.0"))
    check not parseVersion("2.0.0").satisfies(parseConstraint("^1.2.0"))
