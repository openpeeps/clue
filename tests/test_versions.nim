# Clue versions — unit tests for URL translation, cruft detection, tag
# discovery/parsing and the clean-install copy layout. Pure logic and
# filesystem fixtures only (no git subprocesses, no network, no DB).

import std/[os, strutils, unittest]
import clue/pkgmanager/configs
import clue/pkgmanager/versions

suite "versions — toGitSshUrl":
  test "https URL becomes scp-like ssh url with .git suffix":
    check toGitSshUrl("https://github.com/openpeeps/clue") ==
      "git@github.com:openpeeps/clue.git"
    check toGitSshUrl("https://github.com/openpeeps/clue.git") ==
      "git@github.com:openpeeps/clue.git"

  test "git+https strips the git+ prefix":
    check toGitSshUrl("git+https://github.com/openpeeps/clue") ==
      "git@github.com:openpeeps/clue.git"

  test "http scheme is translated too":
    check toGitSshUrl("http://example.com/org/repo") ==
      "git@example.com:org/repo.git"

  test "non-http URLs pass through unchanged":
    check toGitSshUrl("git@github.com:openpeeps/clue.git") ==
      "git@github.com:openpeeps/clue.git"
    check toGitSshUrl("ssh://git@github.com/org/repo") ==
      "ssh://git@github.com/org/repo"

  test "url with no path returns unchanged":
    check toGitSshUrl("https://example.com") == "https://example.com"

suite "versions — tagForVersion from git ref store":
  test "finds an exact semver tag among packed and loose refs":
    let dir = getTempDir() / "clue_versions_tags" / $getCurrentProcessId()
    createDir(dir / ".git" / "refs" / "tags")
    defer: removeDir(dir)
    writeFile(dir / ".git" / "packed-refs",
      "# pack-refs with: peeled fully-peeled sorted\n" &
      "0000000000000000000000000000000000000001 refs/tags/v1.2.3\n" &
      "0000000000000000000000000000000000000001 refs/tags/v1.2.3^{}\n" &
      "0000000000000000000000000000000000000002 refs/tags/v2.0.0\n")
    writeFile(dir / ".git" / "refs" / "tags" / "1.5.0",
      "0000000000000000000000000000000000000003\n")

    check tagForVersion(dir, "1.2.3") == "v1.2.3"
    check tagForVersion(dir, "2.0.0") == "v2.0.0"
    check tagForVersion(dir, "1.5.0") == "1.5.0"
    check tagForVersion(dir, "9.9.9") == ""

  test "peeled annotated-tag refs are ignored":
    let dir = getTempDir() / "clue_versions_peeled" / $getCurrentProcessId()
    createDir(dir / ".git")
    defer: removeDir(dir)
    writeFile(dir / ".git" / "packed-refs",
      "0000000000000000000000000000000000000001 refs/tags/v3.1.4^{}\n")
    check tagForVersion(dir, "3.1.4") == ""

suite "versions — installCleanCopy layout":
  test "flattens srcDir into the install dir, skipping cruft":
    let cache = getTempDir() / "clue_versions_cache" / $getCurrentProcessId()
    let outDir = getTempDir() / "clue_versions_out" / $getCurrentProcessId()
    createDir(cache / "src" / "sub")
    createDir(cache / "tests")
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "src" / "clue.nim", "module\n")
    writeFile(cache / "src" / "sub" / "helper.nim", "helper\n")
    writeFile(cache / "tests" / "t.nim", "test\n")
    writeFile(cache / "pkg.nimble", "version = \"1.0.0\"\n")

    let nimble = NimbleFile(srcDir: "src", path: "pkg.nimble")
    installCleanCopy(cache, outDir, nimble)

    check fileExists(outDir / "clue.nim")
    check fileExists(outDir / "sub" / "helper.nim")
    check fileExists(outDir / "pkg.nimble")
    check not dirExists(outDir / "tests")
    check not dirExists(outDir / "src")

  test "uses repo root when no srcDir is declared":
    let cache = getTempDir() / "clue_versions_root" / $getCurrentProcessId()
    let outDir = getTempDir() / "clue_versions_rootout" / $getCurrentProcessId()
    createDir(cache)
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "main.nim", "main\n")
    writeFile(cache / ".gitignore", "x\n")
    let nimble = NimbleFile(srcDir: "")
    installCleanCopy(cache, outDir, nimble)
    check fileExists(outDir / "main.nim")
    check not fileExists(outDir / ".gitignore")

  test "copies installDirs, installFiles and installExt":
    let cache = getTempDir() / "clue_versions_ext" / $getCurrentProcessId()
    let outDir = getTempDir() / "clue_versions_extout" / $getCurrentProcessId()
    createDir(cache / "src")
    createDir(cache / "assets")
    createDir(cache / "src" / "deep")
    defer: removeDir(cache); removeDir(outDir)
    writeFile(cache / "assets" / "logo.png", "png")
    writeFile(cache / "LICENSE", "mit")
    writeFile(cache / "src" / "deep" / "extra.toml", "cfg")
    writeFile(cache / "src" / "deep" / "code.nim", "code")

    let nimble = NimbleFile(srcDir: "src",
      installDirs: @["assets"], installFiles: @["LICENSE"],
      installExt: @[".toml"])
    installCleanCopy(cache, outDir, nimble)

    check fileExists(outDir / "assets" / "logo.png")
    check fileExists(outDir / "LICENSE")
    check fileExists(outDir / "deep" / "extra.toml")
    check fileExists(outDir / "deep" / "code.nim")

suite "versions — no shell-only redirects in git commands":
  test "git subprocess commands are portable (no POSIX-only 2>/dev/null)":
    # Regression: on Windows gitExec runs through cmd.exe, so a `2>/dev/null`
    # suffix made `git show <tag>:<nimble>` fail silently, `getDeps` returned
    # no deps and transitive packages (e.g. nimsimd via openparser) were never
    # installed. Every git command must be a plain `git ...` invocation.
    const source = staticRead(currentSourcePath().parentDir / ".." / "src" / "clue" / "pkgmanager" / "versions.nim")
    for line in source.splitLines():
      if "git" in line.toLowerAscii and ("2>/dev/null" in line or "/dev/null" in line):
        check false
    check true
