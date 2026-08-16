# Clue deploy web — unit tests for `deployWeb`'s pure validation paths
# (profile lookup, required fields, local dir existence). No rsync/ssh
# subprocesses are ever spawned by these tests.

import std/[os, tables, unittest]
import clue/deploy/configs
import clue/deploy/web

proc minimalConfig(profiles: OrderedTableRef[string, WebProfile]): DeployConfig =
  DeployConfig(web: WebConfig(localDir: getTempDir(), profiles: profiles))

suite "deploy web — deployWeb validation":
  test "unknown profile returns exit code 1":
    var profs = newOrderedTable[string, WebProfile]()
    profs["prod"] = WebProfile(host: "example.com", user: "deploy",
      remoteDir: "/srv/app")
    let cfg = minimalConfig(profs)
    check deployWeb(cfg, "staging", "", dryRun = false, yes = true,
      verbose = false, statusOnly = false) == 1

  test "missing host/user/remoteDir is rejected":
    var profs = newOrderedTable[string, WebProfile]()
    profs["prod"] = WebProfile(host: "", user: "deploy", remoteDir: "")
    let cfg = minimalConfig(profs)
    check deployWeb(cfg, "prod", "", dryRun = false, yes = true,
      verbose = false, statusOnly = false) == 1

  test "missing local directory is rejected":
    var profs = newOrderedTable[string, WebProfile]()
    profs["prod"] = WebProfile(host: "example.com", user: "deploy",
      remoteDir: "/srv/app")
    let cfg = DeployConfig(web: WebConfig(localDir: "/nonexistent-clue-dir",
      profiles: profs))
    check deployWeb(cfg, "prod", "", dryRun = false, yes = true,
      verbose = false, statusOnly = false) == 1

  test "status-only requires a systemd service":
    var profs = newOrderedTable[string, WebProfile]()
    profs["prod"] = WebProfile(host: "example.com", user: "deploy",
      remoteDir: "/srv/app")
    let cfg = minimalConfig(profs)
    check deployWeb(cfg, "prod", "", dryRun = false, yes = true,
      verbose = false, statusOnly = true) == 1
