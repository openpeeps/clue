# Clue resolver — in-depth DFS complex-graph test suite.
#
# Exercises the depth-first dependency resolver against deterministic
# in-memory graphs (no git, no network): deep chains, diamonds, nested
# diamonds, nearest-wins depth priority, multi-level chronological
# backtracking, probe budgets, features at depth, deep cycles, git-ref
# placeholders, multiple roots and the verification pass.
#
# Self-contained: duplicates the small sim helpers so this file can run
# standalone (see tests/resolver_scenarios.nim for the scenario suite).

import std/[sequtils, tables, unittest]
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

proc resolvedNames(res: Resolution): seq[string] =
  for rp in res.packages:
    result.add(rp.name)

proc chain(names: openArray[string]): seq[SimPkg] =
  ## Build a linear dependency chain: names[0] -> names[1] -> ... -> names[^1].
  for i in 0 ..< names.len:
    if i == names.high:
      result.add(simPkg(names[i], "1.0.0"))
    else:
      result.add(simPkg(names[i], "1.0.0", @[simDep(names[i + 1], "1.0.0")]))

suite "DFS complex graphs — deep chains":
  test "16-level linear chain resolves completely":
    var (registry, provider) = makeSim(chain(["A", "B", "C", "D", "E", "F", "G", "H",
      "I", "J", "K", "L", "M", "N", "O", "P"]))
    let res = registry.resolveDetailed(@[root("A")], provider)
    for name in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
                 "K", "L", "M", "N", "O", "P"]:
      check versionOf(res, name) == "1.0.0"
    check res.packages.len == 16

  test "20-level chain resolves within the default probe budget":
    var names: seq[string]
    for i in 1 .. 20:
      names.add("L" & $i)
    var (registry, provider) = makeSim(chain(names))
    let res = registry.resolveDetailed(@[root("L1")], provider)
    check versionOf(res, "L20") == "1.0.0"
    check res.packages.len == 20

  test "leaf conflict in a deep chain is a soft violation (nearest wins)":
    # root requires Z >= 1.0 (depth 1, hard); E at depth 6 requires Z < 0.5.
    var pkgs = chain(["A", "B", "C", "D", "E"])
    pkgs[0].deps.add(simDep("Z", ">= 1.0.0"))
    pkgs[^1].deps.add(simDep("Z", "< 0.5.0"))
    pkgs.add(simPkg("Z", "0.4.0"))
    pkgs.add(simPkg("Z", "1.0.0"))
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("A")], provider)
    check versionOf(res, "Z") == "1.0.0"
    check res.softViolations.len >= 1
    let sv = res.softViolations[0]
    check sv.name == "Z"
    check sv.fromPkg == "E"
    check $sv.constraint == "< 0.5.0"
    check $sv.chosen == "1.0.0"

  test "mid-chain conflict deep (depth 4) is ignored, shallower wins":
    var pkgs = chain(["A", "B", "C", "D"])
    pkgs[0].deps.add(simDep("Y", ">= 2.0.0"))       # A (depth 1) hard
    pkgs[2].deps.add(simDep("Y", "<= 1.0.0"))       # C (depth 3) soft
    pkgs.add(simPkg("Y", "1.0.0"))
    pkgs.add(simPkg("Y", "2.0.0"))
    pkgs.add(simPkg("Y", "3.0.0"))
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("A")], provider)
    check versionOf(res, "Y") == "3.0.0"
    check res.softViolations.len == 1
    check res.softViolations[0].fromPkg == "C"

suite "DFS complex graphs — diamonds and shared subgraphs":
  test "simple diamond resolves the shared dep once":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("C", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "1.0.0"
    check res.packages.len == 4
    check res.packages.filterIt(it.name == "C").len == 1

  test "diamond with intersecting constraints at the same depth":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", ">= 1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "< 2.0.0")]),
      simPkg("C", "1.0.0"), simPkg("C", "1.5.0"), simPkg("C", "2.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "1.5.0"

  test "depth-skewed diamond: nearest wins over deeper constraint":
    # R -> A -> C (depth 2, C >= 2.0) hard; R -> B -> X -> C (depth 3, C < 2.0) soft.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", ">= 2.0.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "1.0.0")]),
      simPkg("X", "1.0.0", @[simDep("C", "< 2.0.0")]),
      simPkg("C", "1.0.0"), simPkg("C", "2.0.0"), simPkg("C", "3.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "3.0.0"
    check res.softViolations.len == 1
    check res.softViolations[0].name == "C"

  test "nested diamond (diamond inside a diamond) stays consistent":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0"), simDep("D", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "1.0.0"), simDep("E", "1.0.0")]),
      simPkg("C", "1.0.0", @[simDep("D", "1.0.0"), simDep("F", "1.0.0")]),
      simPkg("D", "1.0.0"),
      simPkg("E", "1.0.0", @[simDep("F", "1.0.0")]),
      simPkg("F", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    for name in ["A", "B", "C", "D", "E", "F"]:
      check versionOf(res, name) == "1.0.0"
    check res.packages.len == 7

  test "triple diamond sharing two leaves resolves both once":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0"), simDep("C", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "1.0.0"), simDep("Y", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "1.0.0"), simDep("Y", "1.0.0")]),
      simPkg("C", "1.0.0", @[simDep("X", "1.0.0"), simDep("Y", "1.0.0")]),
      simPkg("X", "1.0.0"), simPkg("Y", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check res.packages.filterIt(it.name == "X").len == 1
    check res.packages.filterIt(it.name == "Y").len == 1

  test "wide graph: root with 12 direct deps each with a subtree":
    var pkgs: seq[SimPkg]
    var rootDeps: seq[SimDep]
    for i in 1 .. 12:
      let n = "P" & $i
      rootDeps.add(simDep(n, "1.0.0"))
      pkgs.add(simPkg(n, "1.0.0", @[simDep(n & "sub", "1.0.0")]))
      pkgs.add(simPkg(n & "sub", "1.0.0"))
    pkgs.insert(simPkg("R", "1.0.0", rootDeps), 0)
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("R")], provider)
    check res.packages.len == 1 + 12 + 12
    for i in 1 .. 12:
      check versionOf(res, "P" & $i) == "1.0.0"
      check versionOf(res, "P" & $i & "sub") == "1.0.0"

suite "DFS complex graphs — backtracking":
  test "newest root version drags in an unsatisfiable subtree -> older root":
    # A3.0 needs X >= 3.0 (X only has 1.0) -> backtrack A2.0 -> A1.0 works.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "3.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("A", "2.0.0", @[simDep("X", ">= 2.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("X", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "A") == "1.0.0"
    check versionOf(res, "X") == "1.0.0"

  test "backtracking chain: 4 failing candidates before success":
    # Newest A versions each drag an unsatisfiable P constraint; only A 0.0.1
    # works. The solver backtracks through 4 candidates before finding it.
    var pkgs: seq[SimPkg]
    for v in 1 .. 5:
      pkgs.add(simPkg("A", "0.0." & $v,
        @[simDep("P", ">= " & $v & ".0.0")]))
    pkgs.add(simPkg("R", "1.0.0", @[simDep("A", "*")]))
    pkgs.add(simPkg("P", "1.0.0"))
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("R")], provider)
    # only A 0.0.1's P >= 1.0 is satisfiable; all newer A versions fail
    check versionOf(res, "A") == "0.0.1"
    check versionOf(res, "P") == "1.0.0"

  test "sibling candidate retry: newest transitive version fails, older works":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", ">= 1.0.0")]),
      simPkg("C", "2.0.0", @[simDep("P", ">= 9.0.0")]),
      simPkg("C", "1.0.0"),
      simPkg("P", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "C") == "1.0.0"

  test "deep conflict forces re-choice at depth 1":
    # A2.0 needs Z < 0.5 (hard via B's same-depth > 0.5): unsatisfiable together.
    # Backtrack to A1.0, then B's Z > 0.5 resolves to 0.6.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*"), simDep("B", "1.0.0")]),
      simPkg("A", "2.0.0", @[simDep("Z", "< 0.5.0")]),
      simPkg("A", "1.0.0"),
      simPkg("B", "1.0.0", @[simDep("Z", "> 0.5.0")]),
      simPkg("Z", "0.4.0"), simPkg("Z", "0.6.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "A") == "1.0.0"
    check versionOf(res, "Z") == "0.6.0"

  test "nested backtracking unwinds multiple choice points":
    # A2.0 -> C (both C versions fail via D -> P>=9); A1.0 (no deps) succeeds.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*"), simDep("B", "1.0.0")]),
      simPkg("A", "2.0.0", @[simDep("C", "*")]),
      simPkg("A", "1.0.0"),
      simPkg("C", "2.0.0", @[simDep("D", "1.0.0")]),
      simPkg("C", "1.0.0", @[simDep("D", "1.0.0")]),
      simPkg("D", "1.0.0", @[simDep("P", ">= 9.0.0")]),
      simPkg("B", "1.0.0"),
      simPkg("P", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "A") == "1.0.0"

  test "re-pick when an assigned version falls out of a tightened intersection":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("X", "< 2.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "3.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "1.0.0"

  test "exhausting every candidate raises VersionConflictError":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "2.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 3.0.0")]),
      simPkg("X", "1.0.0"),
    ])
    expect VersionConflictError:
      discard registry.resolveDetailed(@[root("R")], provider)

  test "probe budget exceeded raises BacktrackLimitError":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "5.0.0", @[simDep("P", ">= 5.0.0")]),
      simPkg("A", "4.0.0", @[simDep("P", ">= 4.0.0")]),
      simPkg("A", "3.0.0", @[simDep("P", ">= 3.0.0")]),
      simPkg("P", "1.0.0"),
    ])
    expect BacktrackLimitError:
      discard registry.resolveDetailed(@[root("R")], provider, maxProbes = 2)

suite "DFS complex graphs — soft-constraint tie-breaking":
  test "candidate satisfying more soft constraints wins":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0"), simDep("C", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "*")]),
      simPkg("B", "1.0.0", @[simDep("X", ">= 2.0.0")]),
      simPkg("C", "1.0.0", @[simDep("X", "<= 2.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "2.0.0"), simPkg("X", "3.0.0"),
    ])
    # X=2.0 satisfies both soft constraints; 1.0 and 3.0 satisfy only one.
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "2.0.0"

  test "newest wins among equally-satisfying soft candidates":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "*")]),
      simPkg("B", "1.0.0", @[simDep("X", ">= 1.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "2.0.0"), simPkg("X", "3.0.0"),
    ])
    # all three satisfy >= 1.0 -> tie -> newest 3.0
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "3.0.0"

suite "DFS complex graphs — features at depth":
  test "feature at depth 2 pulls feature-only deps":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("App", "1.0.0")]),
      simPkg("App", "1.0.0", @[simDep("Lib", "1.0.0", @["full"])]),
      simPkg("Lib", "1.0.0", @[simDep("Core", "1.0.0")],
        {"full": @[simDep("Fancy", "1.0.0")]}.toTable),
      simPkg("Core", "1.0.0"),
      simPkg("Fancy", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "Fancy") == "1.0.0"
    check versionOf(res, "Core") == "1.0.0"

  test "feature arriving late re-expands an already-assigned version":
    # App -> Lib (no feature); then Ext -> Lib[full] activates the feature.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("App", "1.0.0")]),
      simPkg("App", "1.0.0", @[simDep("Lib", "1.0.0"), simDep("Ext", "1.0.0")]),
      simPkg("Ext", "1.0.0", @[simDep("Lib", "1.0.0", @["full"])]),
      simPkg("Lib", "1.0.0", @[simDep("Core", "1.0.0")],
        {"full": @[simDep("Fancy", "1.0.0")]}.toTable),
      simPkg("Core", "1.0.0"),
      simPkg("Fancy", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "Lib") == "1.0.0"
    check versionOf(res, "Fancy") == "1.0.0"

  test "feature dep with a conflicting deeper constraint is a soft violation":
    # App directly requires Q >= 2.0.0 (depth 2, hard); Lib's `full` feature
    # drags Q < 1.0.0 at depth 3 (soft) — nearest wins, recorded as a violation.
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("App", "1.0.0")]),
      simPkg("App", "1.0.0", @[simDep("Lib", "1.0.0", @["full"]),
        simDep("Q", ">= 2.0.0")]),
      simPkg("Lib", "1.0.0", @[],
        {"full": @[simDep("Q", "< 1.0.0")]}.toTable),
      simPkg("Q", "0.5.0"), simPkg("Q", "2.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "Q") == "2.0.0"
    check res.softViolations.len >= 1

suite "DFS complex graphs — cycles":
  test "self-dependency raises CircularDependencyError":
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("A")], provider)

  test "direct mutual cycle raises CircularDependencyError":
    var (registry, provider) = makeSim([
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("A")], provider)

  test "deep non-root cycle raises CircularDependencyError":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("C", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("R")], provider)

  test "cycle reachable only through one version is rejected":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "*")]),
      simPkg("A", "2.0.0", @[simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0"),
      simPkg("B", "1.0.0", @[simDep("A", "1.0.0")]),
    ])
    expect CircularDependencyError:
      discard registry.resolveDetailed(@[root("R")], provider)

  test "acyclic shared DAG passes verification":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0"), simDep("D", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("D", "1.0.0")]),
      simPkg("C", "1.0.0"), simPkg("D", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check res.packages.len == 5

suite "DFS complex graphs — git refs, placeholders and unknown packages":
  test "head placeholder deep in the graph defers to discovery":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("bag", "1.0.0")]),
      simPkg("bag", "1.0.0", @[simDep("valido", "0.0.0")]),
      simPkg("kapsis", "1.0.0", @[simDep("valido", ">= 0.1.0")]),
      simPkg("valido", "0.0.0"),
    ])
    expect PackageNotFoundError:
      discard registry.resolveDetailed(@[root("R"), root("kapsis")], provider)
    registry.addPackage(UnresolvedPackage(name: "valido",
      version: parseVersion("0.1.0"), dependencies: @[]))
    let res = registry.resolveDetailed(@[root("R"), root("kapsis")], provider)
    check versionOf(res, "valido") == "0.1.0"

  test "unknown package deep in the graph reports pending names":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("B", "1.0.0")]),
      simPkg("B", "1.0.0", @[simDep("MysteryPkg", "*")]),
    ])
    try:
      discard registry.resolveDetailed(@[root("R")], provider)
      check false
    except PackageNotFoundError as e:
      check "MysteryPkg" in e.pending

suite "DFS complex graphs — multiple roots":
  test "two roots sharing a subgraph resolve consistently":
    var (registry, provider) = makeSim([
      simPkg("R1", "1.0.0", @[simDep("Common", "1.0.0")]),
      simPkg("R2", "1.0.0", @[simDep("Common", "1.0.0")]),
      simPkg("Common", "1.0.0", @[simDep("Leaf", "1.0.0")]),
      simPkg("Leaf", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R1"), root("R2")], provider)
    check versionOf(res, "R1") == "1.0.0"
    check versionOf(res, "R2") == "1.0.0"
    check versionOf(res, "Common") == "1.0.0"
    check versionOf(res, "Leaf") == "1.0.0"

  test "three roots with partial overlap":
    var (registry, provider) = makeSim([
      simPkg("R1", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("R2", "1.0.0", @[simDep("B", "1.0.0"), simDep("C", "1.0.0")]),
      simPkg("R3", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("A", "1.0.0"), simPkg("B", "1.0.0"), simPkg("C", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R1"), root("R2"), root("R3")], provider)
    check res.packages.len == 6

  test "conflicting roots raise VersionConflictError":
    var (registry, provider) = makeSim([
      simPkg("R1", "1.0.0", @[simDep("X", ">= 2.0.0")]),
      simPkg("R2", "1.0.0", @[simDep("X", "< 1.0.0")]),
      simPkg("X", "0.5.0"), simPkg("X", "2.0.0"),
    ])
    expect VersionConflictError:
      discard registry.resolveDetailed(@[root("R1"), root("R2")], provider)

suite "DFS complex graphs — constraint intersections at depth":
  test "tilde and caret constraints intersect":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "~ 1.2.3")]),
      simPkg("B", "1.0.0", @[simDep("X", "^ 1.2.0")]),
      simPkg("X", "1.2.0"), simPkg("X", "1.2.5"), simPkg("X", "1.3.0"),
    ])
    # ~1.2.3 := [1.2.3, 1.3.0); ^1.2.0 := [1.2.0, 2.0.0) -> 1.2.5
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "1.2.5"

  test "exact plus gte intersects to the exact version":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "= 1.2.3")]),
      simPkg("B", "1.0.0", @[simDep("X", ">= 1.2.0")]),
      simPkg("X", "1.2.0"), simPkg("X", "1.2.3"), simPkg("X", "1.3.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "1.2.3"

  test "prerelease ordering at depth prefers the stable release":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", ">= 1.2.0")]),
      simPkg("X", "1.1.0"), simPkg("X", "1.2.0-rc.1"), simPkg("X", "1.2.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "1.2.0"

  test "0.0.0 sentinel is treated as any constraint":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("X", "0.0.0")]),
      simPkg("X", "1.0.0"), simPkg("X", "2.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check versionOf(res, "X") == "2.0.0"

suite "DFS complex graphs — verification pass":
  test "every declared dependency is resolved (completeness)":
    var pkgs = chain(["A", "B", "C", "D"])
    pkgs.add(simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("Z", "1.0.0")]))
    pkgs.add(simPkg("Z", "1.0.0"))
    var (registry, provider) = makeSim(pkgs)
    let res = registry.resolveDetailed(@[root("R")], provider)
    let names = resolvedNames(res)
    for name, deps in res.depsOf:
      check name in names
      for d in deps:
        check d.name in names

  test "depsOf matches the expanded graph":
    var (registry, provider) = makeSim([
      simPkg("R", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("B", "1.0.0"),
      simPkg("C", "1.0.0", @[simDep("D", "1.0.0")]),
      simPkg("D", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R")], provider)
    check res.depsOf["R"].len == 2
    check res.depsOf["A"].len == 1
    check res.depsOf["A"][0].name == "C"
    check res.depsOf["C"].len == 1
    check res.depsOf["C"][0].name == "D"
    check res.depsOf["B"].len == 0

  test "resolved set is acyclic and every root is present":
    var (registry, provider) = makeSim([
      simPkg("R1", "1.0.0", @[simDep("A", "1.0.0")]),
      simPkg("R2", "1.0.0", @[simDep("A", "1.0.0"), simDep("B", "1.0.0")]),
      simPkg("A", "1.0.0", @[simDep("C", "1.0.0")]),
      simPkg("B", "1.0.0"),
      simPkg("C", "1.0.0"),
    ])
    let res = registry.resolveDetailed(@[root("R1"), root("R2")], provider)
    let names = resolvedNames(res)
    check "R1" in names
    check "R2" in names
    check names.len == names.deduplicate.len
