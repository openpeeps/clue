# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue deploy.dir` — sync a directory profile (`from` to `to`).
## The destination is a local path, unless `host` is set — then it is a
## remote path on `user@host` reached over ssh (same transport as
## `deploy web`, including the one-time password prompt when no ssh key
## is configured). Think static sites: build output placed where it is
## served from, locally or on a server.
##
## Profiles with a `release:` block source the payload from a public
## GitHub release instead: `local` mode downloads and extracts into a
## staging dir first (then the usual rsync), `remote` mode curls and
## extracts directly on the target host.
##
## Profiles with a `steps:` block run script steps after the sync
## (GH-runner style `- run:` entries): on the host over ssh when `host`
## is set, in a local shell otherwise.

import std/[options, os, osproc, strutils, tables]
import pkg/kapsis/interactive/prompts
import ./configs
import ./remotes
import ./releases

proc deployDir*(cfg: DeployConfig, profileName, keyOverride: string,
    dryRun = false, yes = false, verbose = false): int =
  ## Sync the `dir` profile `profileName`. Returns a process exit code
  ## (0 on success).
  if cfg.dir.profiles == nil or not cfg.dir.profiles.hasKey(profileName):
    displayError("Dir profile not found: " & profileName)
    return 1
  var prof = cfg.dir.profiles[profileName]
  if keyOverride.len > 0:
    prof.sshKey = keyOverride
  let hasRelease = prof.release.repo.len > 0
  if prof.to.len == 0 or (prof.`from`.len == 0 and not hasRelease):
    displayError("Dir profile '" & profileName & "' requires from and to")
    return 1
  if not validateSteps(prof.steps, profileName):
    return 1
  if hasRelease:
    if prof.release.asset.len == 0:
      displayError("Dir profile '" & profileName & "' release requires asset")
      return 1
    let mode =
      if prof.release.mode.len > 0: prof.release.mode
      else: "local"
    if mode != "local" and mode != "remote":
      displayError("Dir profile '" & profileName &
        "' release mode must be local or remote")
      return 1
    if mode == "remote":
      if not isRemoteHost(prof.host):
        displayError("Dir profile '" & profileName &
          "' release mode remote requires host")
        return 1
      if prof.user.len == 0:
        displayError("Dir profile '" & profileName &
          "' requires user for a remote host")
        return 1
      let authRes = ensureRemoteAuth(prof.user, prof.host, prof.sshKey)
      if not authRes.ok:
        return 1
      applySshpassEnv(authRes.auth)
      return deployRemoteRelease(prof, authRes.auth, dryRun, yes, verbose)
  var cleanup = ""
  defer:
    if cleanup.len > 0:
      removeDir(cleanup)
  var srcDir = expandPath(prof.`from`)
  if hasRelease:
    # Local mode: download + extract the release asset into a staging
    # dir first (also on dry-run: this validates the release while the
    # rsync itself stays a no-op transfer).
    let workDir = getTempDir() / ("clue_release_" & $getCurrentProcessId())
    discard existsOrCreateDir(workDir)
    cleanup = workDir
    let (stage, ok) = stageReleaseAsset(prof.release.repo,
      prof.release.asset, prof.release.binary, workDir, verbose)
    if not ok:
      return 1
    srcDir = stage
  if not dirExists(srcDir):
    displayError("Source directory not found: " & srcDir)
    return 1
  let remote = isRemoteHost(prof.host)
  var auth = RemoteAuth()
  var dest = expandPath(prof.to)
  if remote:
    if prof.user.len == 0:
      displayError("Dir profile '" & profileName & "' requires user for a remote host")
      return 1
    let authRes = ensureRemoteAuth(prof.user, prof.host, prof.sshKey)
    if not authRes.ok:
      return 1
    auth = authRes.auth
    applySshpassEnv(auth)
    dest = prof.user & "@" & prof.host & ":" & prof.to
  let cmd = rsyncCmd(srcDir, dest, prof.user, prof.host, prof.port, auth,
    prof.timeout, dryRun, prof.delete, prof.checksum,
    prof.compress.get(true), prof.exclude)
  display("  " & cyan(cmd))
  if not yes and not dryRun:
    if not promptConfirm("Sync " & srcDir & " to " & dest & "?"):
      displayInfo("Deployment cancelled.")
      return 1
  let (output, code) = execCmdEx(cmd)
  write(stdout, output)
  if code != 0:
    displayError("Sync failed for profile " & profileName)
    return code

  # script steps: on the host when remote, in a local shell otherwise
  if prof.steps.len > 0:
    if remote:
      return runStepsRemote(prof.user, prof.host, prof.port, prof.timeout,
        auth, prof.steps, dryRun, verbose)
    return runStepsLocal(prof.steps, dryRun, verbose)
  0
