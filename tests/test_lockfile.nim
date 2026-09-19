# Clue lockfile — unit tests for `clue.lock` fingerprinting, openparser/json
# roundtrips (incl. renameHook wire names) and validation.

import std/[os, unittest, sequtils, strutils]
import pkg/openparser/json
import clue/pkgmanager/nimbleparser
import clue/pkgmanager/lockfile

proc sampleNimble(): NimbleFile =
  parseNimbleString("""
version = "0.1.0"
srcDir  = "src"
bin     = @["myapp"]

requires "semver >= 1.2.3"
requires "kapsis >= 0.4.8"

feature "ssl":
  requires "openssl >= 1.0.0"
""")

proc sampleEntries(dir: string): seq[LockEntry] =
  let pkgDir = dir / "pkgs" / "semver" / "1.2.3"
  createDir(pkgDir)
  @[LockEntry(name: "semver", version: "1.2.3", constraint: ">= 1.2.3",
    features: @[], path: pkgDir, develop: false, url: "", refStr: "")]

suite "lockfile — hashing":
  test "hash is stable for the same input":
    let n = sampleNimble()
    check computeNimbleHash(n, @["dev"], "2.2.12") ==
      computeNimbleHash(n, @["dev"], "2.2.12")

  test "hash changes when requires change":
    let a = sampleNimble()
    var b = sampleNimble()
    b.requires.add(parseRequiresArg("spry >= 1.0.0"))
    check computeNimbleHash(a, @["dev"], "2.2.12") !=
      computeNimbleHash(b, @["dev"], "2.2.12")

  test "hash changes with active features and nim version":
    let n = sampleNimble()
    check computeNimbleHash(n, @["dev"], "2.2.12") !=
      computeNimbleHash(n, @["dev", "ssl"], "2.2.12")
    check computeNimbleHash(n, @["dev"], "2.2.12") !=
      computeNimbleHash(n, @["dev"], "2.0.0")

suite "lockfile — openparser/json roundtrip":
  test "toJson uses version/ref wire names via renameHook":
    let lock = newLockFile("myapp", "abc", "2.2.12", @["dev"],
      @[LockEntry(name: "a", version: "1.0.0", constraint: "*",
        features: @[], path: "/tmp/x", develop: false, url: "",
        refStr: "master")])
    let s = toJson(lock)
    let node = parseJson(s)
    check node.hasKey("version")
    check not node.hasKey("fileVersion")
    check node["packages"][0].hasKey("ref")
    check not node["packages"][0].hasKey("refStr")
    check node["version"].getInt == LockVersion
    check node["packages"][0]["ref"].getStr == "master"

  test "fromJson reads back what toJson wrote":
    let lock = newLockFile("myapp", "abc", "2.2.12", @["dev"],
      @[LockEntry(name: "a", version: "1.0.0", constraint: ">= 1.0.0",
        features: @["ssl"], path: "/tmp/x", develop: false, url: "",
        refStr: "")])
    let back = fromJson(toJson(lock), LockFile)
    check back.fileVersion == LockVersion
    check back.root == "myapp"
    check back.nimbleHash == "abc"
    check back.features == @["dev"]
    check back.packages.len == 1
    check back.packages[0].name == "a"
    check back.packages[0].features == @["ssl"]

  test "writeLock/readLock roundtrip through a temp dir":
    let dir = getTempDir() / "clue_lock_test" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let lock = newLockFile("myapp", "abc", "2.2.12", @["dev"],
      sampleEntries(dir))
    writeLock(dir, lock)
    check fileExists(lockPathFor(dir))
    let (ok, back) = readLock(dir)
    check ok
    check back.packages.len == 1
    check back.packages[0].path == lock.packages[0].path

  test "readLock rejects corrupt files":
    let dir = getTempDir() / "clue_lock_corrupt" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    writeFile(lockPathFor(dir), "{not json")
    let (ok, _) = readLock(dir)
    check not ok

suite "lockfile — validation":
  test "valid lock passes, missing path fails":
    let dir = getTempDir() / "clue_lock_valid" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let nimble = sampleNimble()
    let entries = sampleEntries(dir)
    let h = computeNimbleHash(nimble, @["dev"], "2.2.12")
    let lock = newLockFile("myapp", h, "2.2.12", @["dev"], entries)
    check validateLock(lock, nimble, @["dev"], "2.2.12", dir / "develop")
    removeDir(entries[0].path)
    check not validateLock(lock, nimble, @["dev"], "2.2.12",
      dir / "develop")

  test "stale fingerprint fails":
    let dir = getTempDir() / "clue_lock_stale" / $getCurrentProcessId()
    createDir(dir)
    defer: removeDir(dir)
    let nimble = sampleNimble()
    let lock = newLockFile("myapp", "oldhash", "2.2.12", @["dev"],
      sampleEntries(dir))
    check not validateLock(lock, nimble, @["dev"], "2.2.12",
      dir / "develop")
    var changed = sampleNimble()
    changed.requires.add(parseRequiresArg("spry"))
    let goodHash = computeNimbleHash(sampleNimble(), @["dev"], "2.2.12")
    let lock2 = newLockFile("myapp", goodHash, "2.2.12", @["dev"],
      sampleEntries(dir))
    check not validateLock(lock2, changed, @["dev"], "2.2.12",
      dir / "develop")

  test "develop entry needs its live link":
    let dir = getTempDir() / "clue_lock_dev" / $getCurrentProcessId()
    let src = dir / "src" / "mylib"
    createDir(src)
    defer: removeDir(dir)
    let nimble = sampleNimble()
    let h = computeNimbleHash(nimble, @["dev"], "2.2.12")
    let devDir = dir / "develop"
    let lock = newLockFile("myapp", h, "2.2.12", @["dev"],
      @[LockEntry(name: "mylib", version: "", constraint: "*",
        features: @[], path: src, develop: true, url: "", refStr: "")])
    # no develop link yet — invalid
    check not validateLock(lock, nimble, @["dev"], "2.2.12", devDir)
    createDir(devDir)
    createSymlink(dir / "src", devDir / "mylib")
    check validateLock(lock, nimble, @["dev"], "2.2.12", devDir)

suite "lockfile — flags":
  test "lockToFlags emits paths and feature defines":
    let lock = newLockFile("myapp", "h", "2.2.12", @["dev"],
      @[LockEntry(name: "semver", version: "1.2.3",
        constraint: ">= 1.2.3", features: @[], path: "/p/semver",
        develop: false, url: "", refStr: ""),
        LockEntry(name: "kapsis", version: "0.4.8",
        constraint: ">= 0.4.8", features: @["ssl"], path: "/p/kapsis",
        develop: false, url: "", refStr: "")])
    let (flags, defines) = lockToFlags(lock, "myapp", @["dev"])
    check "--path:/p/semver" in flags
    check "--path:/p/kapsis" in flags
    check "features.myapp.dev" in defines
    check "features.kapsis.ssl" in defines
