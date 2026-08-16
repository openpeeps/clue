# Clue resolver — unit tests for constraint parsing, satisfaction,
# registry bookkeeping and the public resolve API (no graph scenarios).

import std/[sequtils, tables, unittest]
import pkg/semver
import clue/pkgmanager/resolver

suite "resolver units — constraint parsing":
  test "parses all operators":
    check $parseConstraint("*") == "*"
    check $parseConstraint("") == "*"
    check $parseConstraint("1.2.3") == "= 1.2.3"
    check $parseConstraint("==1.2.3") == "= 1.2.3"
    check $parseConstraint("= 1.2.3") == "= 1.2.3"
    check $parseConstraint(">= 1.2.3") == ">= 1.2.3"
    check $parseConstraint("> 1.2.3") == "> 1.2.3"
    check $parseConstraint("<= 1.2.3") == "<= 1.2.3"
    check $parseConstraint("< 1.2.3") == "< 1.2.3"
    check $parseConstraint("~ 1.2.3") == "~ 1.2.3"
    check $parseConstraint("~>1.2.3") == "~ 1.2.3"
    check $parseConstraint("^ 1.2.3") == "^ 1.2.3"

  test "strips surrounding whitespace":
    check $parseConstraint("   >= 1.2.3  ") == ">= 1.2.3"
    check $parseConstraint("  ~> 2.0.0  ") == "~ 2.0.0"

  test "malformed constraints raise ResolverError":
    expect ResolverError:
      discard parseConstraint(">= abc")
    expect ResolverError:
      discard parseConstraint("banana")
    expect ResolverError:
      discard parseConstraint(">= 1.2.3.4.5")

  test "exact 0.0.0 is the any sentinel":
    let c = parseConstraint("0.0.0")
    check c.kind == vcExact
    check parseVersion("9.9.9").satisfies(c)

suite "resolver units — satisfies":
  test "exact":
    check parseVersion("1.2.3").satisfies(parseConstraint("= 1.2.3"))
    check not parseVersion("1.2.4").satisfies(parseConstraint("= 1.2.3"))

  test "comparisons":
    check parseVersion("1.3.0").satisfies(parseConstraint(">= 1.2.3"))
    check not parseVersion("1.2.2").satisfies(parseConstraint(">= 1.2.3"))
    check parseVersion("1.2.4").satisfies(parseConstraint("> 1.2.3"))
    check not parseVersion("1.2.3").satisfies(parseConstraint("> 1.2.3"))
    check parseVersion("1.2.3").satisfies(parseConstraint("<= 1.2.3"))
    check parseVersion("1.2.2").satisfies(parseConstraint("< 1.2.3"))
    check not parseVersion("1.2.3").satisfies(parseConstraint("< 1.2.3"))

  test "tilde: >= base, < next minor":
    check parseVersion("1.2.3").satisfies(parseConstraint("~ 1.2.3"))
    check parseVersion("1.2.9").satisfies(parseConstraint("~ 1.2.3"))
    check not parseVersion("1.3.0").satisfies(parseConstraint("~ 1.2.3"))
    check not parseVersion("1.2.2").satisfies(parseConstraint("~ 1.2.3"))
    check not parseVersion("2.0.0").satisfies(parseConstraint("~ 1.2.3"))

  test "caret on major > 0: >= base, < next major":
    check parseVersion("1.2.3").satisfies(parseConstraint("^ 1.2.0"))
    check parseVersion("1.9.9").satisfies(parseConstraint("^ 1.2.0"))
    check not parseVersion("2.0.0").satisfies(parseConstraint("^ 1.2.0"))
    check not parseVersion("1.1.9").satisfies(parseConstraint("^ 1.2.0"))

  test "caret on 0.minor: >= base, < next minor":
    check parseVersion("0.2.3").satisfies(parseConstraint("^ 0.2.3"))
    check parseVersion("0.2.9").satisfies(parseConstraint("^ 0.2.3"))
    check not parseVersion("0.3.0").satisfies(parseConstraint("^ 0.2.3"))

  test "caret on 0.0.patch: >= base, < next patch":
    check parseVersion("0.0.3").satisfies(parseConstraint("^ 0.0.3"))
    check not parseVersion("0.0.4").satisfies(parseConstraint("^ 0.0.3"))

  test "any always satisfies":
    check parseVersion("0.0.1").satisfies(parseConstraint("*"))
    check parseVersion("99.0.0").satisfies(parseConstraint("*"))

  test "prereleases are ordered below their stable":
    check parseVersion("1.2.0-rc.1") < parseVersion("1.2.0")
    check not parseVersion("1.2.0-rc.1").satisfies(parseConstraint(">= 1.2.0"))

suite "resolver units — satisfiesAll":
  test "intersection of multiple constraints":
    let v = parseVersion("1.5.0")
    check v.satisfiesAll([
      parseConstraint(">= 1.0.0"),
      parseConstraint("< 2.0.0"),
      parseConstraint("^ 1.0.0"),
    ])
    check not v.satisfiesAll([
      parseConstraint(">= 1.0.0"),
      parseConstraint("<= 1.4.0"),
    ])

  test "empty intersection is unsatisfiable":
    check not parseVersion("2.0.0").satisfiesAll([
      parseConstraint("<= 1.9.0"),
      parseConstraint(">= 2.0.0"),
    ])

suite "resolver units — registry bookkeeping":
  test "addPackage keeps versions sorted newest first":
    var registry: PackageRegistry
    registry.addPackage("X", v"1.0.0", @[])
    registry.addPackage("X", v"2.0.0", @[])
    registry.addPackage("X", v"1.5.0", @[])
    check registry["X"].len == 3
    check registry["X"][0].version == v"2.0.0"
    check registry["X"][1].version == v"1.5.0"
    check registry["X"][2].version == v"1.0.0"

  test "addPackage object overload appends and re-sorts":
    var registry: PackageRegistry
    registry.addPackage(UnresolvedPackage(name: "X",
      version: parseVersion("0.9.0"), dependencies: @[]))
    registry.addPackage("X", v"1.0.0", @[])
    check registry["X"][0].version == v"1.0.0"

  test "prerelease-aware ordering in the registry":
    var registry: PackageRegistry
    registry.addPackage("X", v"1.2.0-rc.1", @[])
    registry.addPackage("X", v"1.2.0", @[])
    check registry["X"][0].version == v"1.2.0"

  test "resolve on a dependency-free graph returns just the roots":
    var registry: PackageRegistry
    registry.addPackage("A", v"1.0.0", @[])
    registry.addPackage("B", v"2.0.0", @[])
    proc getDeps(name: string, version: Version, features: seq[string]): seq[Dependency] = @[]
    let res = registry.resolveDetailed(
      @[Dependency(name: "A", constraint: parseConstraint(">= 1.0.0")),
        Dependency(name: "B", constraint: parseConstraint("*"))], getDeps)
    check res.packages.len == 2
    check res.packages.filterIt(it.name == "A")[0].version == v"1.0.0"
    check res.packages.filterIt(it.name == "B")[0].version == v"2.0.0"
