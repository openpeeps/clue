import std/[os, unittest, json, strutils, options]
import clue/pkgmanager/configs
import registry_server

suite "sources — isValidSourceName":
  test "valid names":
    check isValidSourceName("nim-lang")
    check isValidSourceName("myreg")
    check isValidSourceName("a1_b-2")
  test "invalid names":
    check not isValidSourceName("")
    check not isValidSourceName("MyReg")
    check not isValidSourceName("a b")
    check not isValidSourceName("a/b")

suite "sources — load/save roundtrip":
  test "serialization roundtrip":
    # direct json test without touching HOME-dependent globals (cluePath is a let)
    let srcs = @[Source(name: "nim-lang", url: "https://example.com/a.json"),
                 Source(name: "myreg", url: "https://example.com/b.json")]
    var arr = newJArray()
    for s in srcs: arr.add(%*{"name": s.name, "url": s.url})
    let j = %*{"sources": arr}
    let tmpFile = getTempDir() / "clue_src_json_test" & $getCurrentProcessId() & ".json"
    writeFile(tmpFile, pretty(j))
    defer: removeFile(tmpFile)
    let parsed = parseFile(tmpFile)
    check parsed["sources"].len == 2
    check parsed["sources"][0]["name"].getStr == "nim-lang"
    check parsed["sources"][1]["url"].getStr == "https://example.com/b.json"
    # current sources.json should still be valid
    let existing = loadSources()
    check existing.len >= 1

suite "sources — registry json":
  test "registryJson contains both nimdrop and hetzner-api":
    let j = registryJson()
    check j.contains("nimdrop")
    check j.contains("hetzner-api")
    check j.contains("nimbase")
