# Clue deploy dir — unit tests for `deployDir`: validation paths, local
# directory sync end-to-end (via rsync), and `dir:` config parsing.
# No remote connections are ever made by these tests.

import std/[os, strutils, tables, unittest]
import clue/deploy/configs
import clue/deploy/dir

proc tmpBase(name: string): string =
  getTempDir() / "clue_deploy_dir" / $getCurrentProcessId() / name

proc localConfig(src, dest: string, delete = false): DeployConfig =
  var profs = newOrderedTable[string, DirProfile]()
  profs["site"] = DirProfile(`from`: src, to: dest, delete: delete)
  DeployConfig(dir: DirConfig(profiles: profs))

suite "deploy dir — validation":
  test "unknown profile returns exit code 1":
    var profs = newOrderedTable[string, DirProfile]()
    profs["site"] = DirProfile(`from`: getTempDir(), to: getTempDir())
    let cfg = DeployConfig(dir: DirConfig(profiles: profs))
    check deployDir(cfg, "staging", "", dryRun = false, yes = true,
      verbose = false) == 1

  test "missing from/to is rejected":
    var profs = newOrderedTable[string, DirProfile]()
    profs["site"] = DirProfile(`from`: "", to: "")
    let cfg = DeployConfig(dir: DirConfig(profiles: profs))
    check deployDir(cfg, "site", "", dryRun = false, yes = true,
      verbose = false) == 1

  test "missing source directory is rejected":
    let cfg = localConfig("/nonexistent-clue-src", getTempDir())
    check deployDir(cfg, "site", "", dryRun = false, yes = true,
      verbose = false) == 1

  test "remote profile without user is rejected before any prompt":
    var profs = newOrderedTable[string, DirProfile]()
    profs["site"] = DirProfile(`from`: getTempDir(), to: "/srv/www",
      host: "example.com", user: "")
    let cfg = DeployConfig(dir: DirConfig(profiles: profs))
    check deployDir(cfg, "site", "", dryRun = false, yes = true,
      verbose = false) == 1

suite "deploy dir — local sync":
  test "copies files from source to destination":
    let base = tmpBase("copy")
    let src = base / "src"
    let dest = base / "dest"
    createDir(src / "css")
    writeFile(src / "index.html", "<h1>hi</h1>")
    writeFile(src / "css" / "app.css", "body{}")
    defer: removeDir(base)
    let cfg = localConfig(src, dest)
    check deployDir(cfg, "site", "", dryRun = false, yes = true,
      verbose = false) == 0
    check readFile(dest / "index.html") == "<h1>hi</h1>"
    check readFile(dest / "css" / "app.css") == "body{}"

  test "dry-run transfers nothing":
    let base = tmpBase("dryrun")
    let src = base / "src"
    let dest = base / "dest"
    createDir(src)
    writeFile(src / "index.html", "<h1>hi</h1>")
    defer: removeDir(base)
    let cfg = localConfig(src, dest)
    check deployDir(cfg, "site", "", dryRun = true, yes = true,
      verbose = false) == 0
    check not fileExists(dest / "index.html")

  test "delete removes stale destination files":
    let base = tmpBase("delete")
    let src = base / "src"
    let dest = base / "dest"
    createDir(src)
    createDir(dest)
    writeFile(src / "index.html", "<h1>hi</h1>")
    writeFile(dest / "stale.txt", "old")
    defer: removeDir(base)
    let cfg = localConfig(src, dest, delete = true)
    check deployDir(cfg, "site", "", dryRun = false, yes = true,
      verbose = false) == 0
    check fileExists(dest / "index.html")
    check not fileExists(dest / "stale.txt")

suite "deploy dir — config parsing":
  test "yaml dir section parses with defaults":
    let base = tmpBase("yaml")
    createDir(base)
    defer: removeDir(base)
    writeFile(base / "clue.deploy.yaml",
      "project: demo\ntype: web\nversion: \"1.0.0\"\n" &
      "dir:\n  profiles:\n    production:\n" &
      "      from: dist/site\n      to: /srv/www\n" &
      "      exclude: [\"*.tmp\"]\n      delete: true\n")
    let cfg = parseDeployConfig(base / "clue.deploy.yaml")
    let prof = cfg.dir.profiles["production"]
    check prof.`from` == "dist/site"
    check prof.to == "/srv/www"
    check prof.delete
    check prof.exclude == @["*.tmp"]
    check prof.port == 22
    check prof.timeout == 60

  test "json dir section parses":
    let base = tmpBase("json")
    createDir(base)
    defer: removeDir(base)
    writeFile(base / "clue.deploy.json",
      """{"project": "demo", "dir": {"profiles": {"production": """ &
      """{"from": "dist/site", "to": "/srv/www"}}}}""")
    let cfg = parseDeployConfig(base / "clue.deploy.json")
    check cfg.dir.profiles["production"].`from` == "dist/site"
    check cfg.dir.profiles["production"].to == "/srv/www"

  test "a stray password key is ignored (never stored anywhere)":
    let base = tmpBase("nopw")
    createDir(base)
    defer: removeDir(base)
    writeFile(base / "clue.deploy.yaml",
      "project: demo\n" &
      "dir:\n  profiles:\n    production:\n" &
      "      from: dist/site\n      to: /srv/www\n" &
      "      password: supersecret\n")
    let cfg = parseDeployConfig(base / "clue.deploy.yaml")
    check cfg.dir.profiles["production"].to == "/srv/www"
