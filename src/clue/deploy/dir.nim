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

import std/[options, os, osproc, strutils, tables]
import pkg/kapsis/interactive/prompts
import ./configs
import ./remotes

proc deployDir*(cfg: DeployConfig, profileName, keyOverride: string,
    dryRun, yes, verbose: bool): int =
  ## Sync the `dir` profile `profileName`. Returns a process exit code
  ## (0 on success).
  if cfg.dir.profiles == nil or not cfg.dir.profiles.hasKey(profileName):
    displayError("Dir profile not found: " & profileName)
    return 1
  var prof = cfg.dir.profiles[profileName]
  if keyOverride.len > 0:
    prof.sshKey = keyOverride
  if prof.`from`.len == 0 or prof.to.len == 0:
    displayError("Dir profile '" & profileName & "' requires from and to")
    return 1
  let srcDir = expandPath(prof.`from`)
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
  0
