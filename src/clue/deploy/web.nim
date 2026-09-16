# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue deploy.web` — deploy a web target over rsync/ssh, with optional
## systemd service management (unit install, daemon-reload, enable, restart,
## is-active verification) and optional script `steps` run on the host
## after the sync (GH-runner style `- run:` entries).

import std/[os, osproc, strutils, tables]
import pkg/kapsis/interactive/prompts
import ./configs
import ./remotes

proc runRemote(prof: WebProfile, auth: RemoteAuth, cmd: string,
    verbose: bool): tuple[output: string, exitCode: int] =
  let full = sshCmd(prof.user, prof.host, prof.port, auth, prof.timeout, cmd)
  if verbose:
    display("  > ssh ... " & cmd)
  result = execCmdEx(full)

proc deployWeb*(cfg: DeployConfig, profileName, keyOverride: string,
    dryRun = false, yes = false, verbose = false,
    statusOnly = false): int =
  ## Deploy the `web` target. Returns a process exit code (0 on success).
  if cfg.web.profiles == nil or not cfg.web.profiles.hasKey(profileName):
    displayError("Web profile not found: " & profileName)
    return 1
  var prof = cfg.web.profiles[profileName]
  if keyOverride.len > 0:
    prof.sshKey = keyOverride
  if prof.host.len == 0 or prof.user.len == 0 or prof.remoteDir.len == 0:
    displayError("Web profile '" & profileName & "' requires host, user and remoteDir")
    return 1
  if not validateSteps(prof.steps, profileName):
    return 1
  let localDir = cfg.web.localDir
  if not dirExists(localDir):
    displayError("Local directory not found: " & localDir)
    return 1

  # Remote auth: key when configured, otherwise a one-time password prompt
  # (never stored in the config file).
  let authRes = ensureRemoteAuth(prof.user, prof.host, prof.sshKey)
  if not authRes.ok:
    return 1
  let auth = authRes.auth
  applySshpassEnv(auth)

  # `--status`: just report the service state, no deploy.
  if statusOnly:
    if prof.systemd.service.len == 0:
      displayError("No systemd service configured for profile '" & profileName & "'")
      return 1
    let (output, code) = runRemote(prof, auth, "systemctl status " & prof.systemd.service, verbose)
    write(stdout, output)
    return code

  # pre-build hooks (local)
  for c in prof.preBuild:
    if verbose:
      display("  > " & c)
    let (_, code) = execCmdEx(c)
    if code != 0:
      displayError("preBuild failed: " & c)
      return code

  # rsync (confirm unless --yes; --dry-run is a no-op transfer)
  let remoteDest = prof.user & "@" & prof.host & ":" & prof.remoteDir
  let cmd = rsyncCmd(localDir, remoteDest, prof.user, prof.host, prof.port,
    auth, prof.timeout, dryRun, prof.delete, prof.checksum,
    prof.compressOn(), prof.exclude)
  display("  " & cyan(cmd))
  if not yes and not dryRun:
    if not promptConfirm("Deploy to " & profileName & " on " & prof.host & "?"):
      displayInfo("Deployment cancelled.")
      return 1
  let (output, code) = execCmdEx(cmd)
  write(stdout, output)
  if code != 0:
    displayError("rsync failed for profile " & profileName)
    return code
  if dryRun:
    if prof.steps.len > 0:
      discard runStepsRemote(prof.user, prof.host, prof.port, prof.timeout,
        auth, prof.steps, dryRun = true, verbose)
    return 0

  # script steps (remote, after sync, before service management)
  if prof.steps.len > 0:
    let stepCode = runStepsRemote(prof.user, prof.host, prof.port,
      prof.timeout, auth, prof.steps, dryRun = false, verbose)
    if stepCode != 0:
      return stepCode

  # systemd management
  let sd = prof.systemd
  if sd.service.len > 0:
    let sudoPrefix = if sdSudo(sd): "sudo " else: ""
    if sd.unitFile.len > 0:
      let unitPath = expandPath(sd.unitFile)
      if not fileExists(unitPath):
        displayError("systemd unit file not found: " & unitPath)
        return 1
      let remoteUnit =
        if sd.unitRemotePath.len > 0: sd.unitRemotePath
        else: "/etc/systemd/system/" & sd.service & ".service"
      let uploadCmd = sshCmd(prof.user, prof.host, prof.port, auth, prof.timeout, sudoPrefix & "tee " & remoteUnit) &
        " < " & quoteShell(unitPath)
      if verbose:
        display("  > ssh ... " & sudoPrefix & "tee " & remoteUnit & " < " & unitPath)
      let (o, c) = execCmdEx(uploadCmd)
      write(stdout, o)
      if c != 0:
        displayError("Failed to install systemd unit " & remoteUnit)
        return c
    if sdDaemonReload(sd):
      let (o, c) = runRemote(prof, auth, sudoPrefix & "systemctl daemon-reload", verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl daemon-reload failed")
        return c
    if sd.enable:
      let (o, c) = runRemote(prof, auth, sudoPrefix & "systemctl enable " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl enable failed")
        return c
    if sdRestart(sd):
      let (o, c) = runRemote(prof, auth, sudoPrefix & "systemctl restart " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl restart failed for " & sd.service)
        return c
    if sdStatus(sd):
      let (o, c) = runRemote(prof, auth, "systemctl --quiet is-active " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("Service not active after restart: " & sd.service)
        return c

  # post-deploy hooks (remote)
  for c in prof.postDeploy:
    let (o, code2) = runRemote(prof, auth, c, verbose)
    write(stdout, o)
    if code2 != 0:
      displayError("postDeploy failed: " & c)
      return code2
  0
