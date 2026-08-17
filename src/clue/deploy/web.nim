# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## `clue deploy.web` — deploy a web target over rsync/ssh, with optional
## systemd service management (unit install, daemon-reload, enable, restart,
## is-active verification).

import std/[os, osproc, strutils, tables]
import pkg/kapsis/interactive/prompts
import ./configs

proc sshCmd(prof: WebProfile, remote: string): string =
  ## An `ssh` invocation for `prof` running `remote` (single-quoted on the wire).
  var s = "ssh"
  if prof.port > 0 and prof.port != 22:
    s.add(" -p " & $prof.port)
  if prof.sshKey.len > 0:
    s.add(" -i " & expandPath(prof.sshKey))
  s.add(" -o BatchMode=yes -o ConnectTimeout=" & $prof.timeout)
  s.add(" " & prof.user & "@" & prof.host & " '" & remote.replace("'", "'\\''") & "'")
  s

proc rsyncCmd(prof: WebProfile, localDir: string, dryRun: bool): string =
  ## The rsync invocation mirroring the local dir to the remote dir.
  var s = "rsync"
  if prof.compressOn():
    s.add(" -z")
  s.add(" -a --partial")
  if dryRun:
    s.add(" -n")
  if prof.delete:
    s.add(" --delete")
  if prof.checksum:
    s.add(" --checksum")
  for ex in prof.exclude:
    s.add(" --exclude=" & ex)
  var sshArgs = "-o BatchMode=yes"
  if prof.port > 0 and prof.port != 22:
    sshArgs.add(" -p " & $prof.port)
  if prof.sshKey.len > 0:
    sshArgs.add(" -i " & expandPath(prof.sshKey))
  s.add(" -e 'ssh " & sshArgs & "'")
  s.add(" " & quoteShell(localDir) & "/ " & prof.user & "@" & prof.host & ":" & prof.remoteDir & "/")
  s

proc runRemote(prof: WebProfile, cmd: string, verbose: bool): tuple[output: string, exitCode: int] =
  let full = sshCmd(prof, cmd)
  if verbose:
    display("  > ssh ... " & cmd)
  result = execCmdEx(full)

proc deployWeb*(cfg: DeployConfig, profileName, keyOverride: string,
    dryRun, yes, verbose, statusOnly: bool): int =
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
  let localDir = cfg.web.localDir
  if not dirExists(localDir):
    displayError("Local directory not found: " & localDir)
    return 1

  # `--status`: just report the service state, no deploy.
  if statusOnly:
    if prof.systemd.service.len == 0:
      displayError("No systemd service configured for profile '" & profileName & "'")
      return 1
    let (output, code) = runRemote(prof, "systemctl status " & prof.systemd.service, verbose)
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
  let cmd = rsyncCmd(prof, localDir, dryRun)
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
    return 0

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
      let uploadCmd = sshCmd(prof, sudoPrefix & "tee " & remoteUnit) &
        " < " & quoteShell(unitPath)
      if verbose:
        display("  > ssh ... " & sudoPrefix & "tee " & remoteUnit & " < " & unitPath)
      let (o, c) = execCmdEx(uploadCmd)
      write(stdout, o)
      if c != 0:
        displayError("Failed to install systemd unit " & remoteUnit)
        return c
    if sdDaemonReload(sd):
      let (o, c) = runRemote(prof, sudoPrefix & "systemctl daemon-reload", verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl daemon-reload failed")
        return c
    if sd.enable:
      let (o, c) = runRemote(prof, sudoPrefix & "systemctl enable " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl enable failed")
        return c
    if sdRestart(sd):
      let (o, c) = runRemote(prof, sudoPrefix & "systemctl restart " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("systemctl restart failed for " & sd.service)
        return c
    if sdStatus(sd):
      let (o, c) = runRemote(prof, "systemctl --quiet is-active " & sd.service, verbose)
      write(stdout, o)
      if c != 0:
        displayError("Service not active after restart: " & sd.service)
        return c

  # post-deploy hooks (remote)
  for c in prof.postDeploy:
    let (o, code2) = runRemote(prof, c, verbose)
    write(stdout, o)
    if code2 != 0:
      displayError("postDeploy failed: " & c)
      return code2
  0
