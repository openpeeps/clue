# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Shared ssh/rsync builders, remote authentication and script steps
## for the deploy targets (`deploy web`, `deploy dir`).
##
## Passwords are never stored in config files and never passed as flags:
## when a remote target has no ssh key configured, clue prompts once on
## the terminal via `promptSecret` and keeps the secret only in process
## memory for the duration of the run. It is fed to ssh via `sshpass -e`
## (the `SSHPASS` env var, never a cmdline argument) when `sshpass` is
## available; otherwise `BatchMode` is dropped so ssh itself prompts
## interactively on the terminal.

import std/[os, osproc, strutils, terminal]
import pkg/kapsis/interactive/prompts
import ./configs

type
  RemoteAuth* = object
    key*: string
    password*: string
    useSshpass*: bool

proc isRemoteHost*(host: string): bool =
  ## A target is remote when a host is configured, local otherwise.
  host.len > 0

proc ensureRemoteAuth*(user, host, key: string): tuple[auth: RemoteAuth, ok: bool] =
  ## Resolve how to authenticate to `user@host`. Key auth when a key is
  ## configured, otherwise prompt once for a password (empty answer means
  ## key auth only). Fails cleanly when stdin is not a terminal.
  if key.len > 0:
    return (RemoteAuth(key: key), true)
  if not isatty(stdin):
    displayError("No ssh key configured for " & user & "@" & host &
      " and stdin is not a terminal. Configure sshKey or use key auth.")
    return (RemoteAuth(), false)
  let pw = promptSecret("Password for " & user & "@" & host & " (empty for key auth):",
    required = false)
  if pw.len == 0:
    return (RemoteAuth(), true)
  (RemoteAuth(password: pw, useSshpass: findExe("sshpass").len > 0), true)

proc applySshpassEnv*(auth: RemoteAuth) =
  ## Export the prompted password for `sshpass -e` child processes.
  ## Call once after `ensureRemoteAuth`, before spawning ssh/rsync.
  if auth.useSshpass:
    putEnv("SSHPASS", auth.password)

proc sshTransportArgs*(port: int, auth: RemoteAuth,
    timeout: int): string =
  ## The ssh flags (no host): for rsync `-e`, which appends the host from
  ## the destination itself. A transport string that already contains
  ## `user@host` would make rsync hand ssh two hosts, and the second one
  ## would be executed as a remote command.
  result = ""
  if auth.useSshpass:
    result.add("sshpass -e ")
  result.add("ssh")
  if port > 0 and port != 22:
    result.add(" -p " & $port)
  if auth.key.len > 0:
    result.add(" -i " & expandPath(auth.key))
  if auth.key.len > 0 and auth.password.len == 0:
    result.add(" -o BatchMode=yes")
  result.add(" -o ConnectTimeout=" & $timeout)

proc sshTransport*(user, host: string, port: int, auth: RemoteAuth,
    timeout: int): string =
  ## The ssh invocation (without remote command) for direct ssh use
  ## (`sshCmd`). Never embeds the password: with `sshpass` it comes from
  ## the `SSHPASS` env var (see `applySshpassEnv`), otherwise `BatchMode`
  ## is dropped so ssh prompts on the terminal itself.
  ## Note `BatchMode` is only set for key auth: password logins need ssh
  ## to actually prompt, otherwise `sshpass` has nothing to answer and
  ## every password login fails. rsync does NOT use this proc: it takes
  ## `sshTransportArgs` and appends the host from the destination.
  sshTransportArgs(port, auth, timeout) & " " & user & "@" & host

proc sshCmd*(user, host: string, port: int, auth: RemoteAuth,
    timeout: int, remote: string): string =
  ## An `ssh` invocation running `remote` (single-quoted on the wire).
  sshTransport(user, host, port, auth, timeout) &
    " '" & remote.replace("'", "'\\''") & "'"

proc validateSteps*(steps: seq[RunStep], profileName: string): bool =
  ## Every step needs a `run` command. Call before any auth or transfer
  ## so config mistakes fail without touching the network.
  for s in steps:
    if s.run.strip().len == 0:
      displayError("Profile '" & profileName & "' has a step without `run`")
      return false
  true

proc stepLabel*(s: RunStep): string =
  ## What to show for a step: its name, or the command itself.
  if s.name.len > 0: s.name else: s.run

proc runStepsRemote*(user, host: string, port, timeout: int,
    auth: RemoteAuth, steps: seq[RunStep], dryRun, verbose: bool): int =
  ## Run `steps` on `user@host` over ssh, in order, stopping at the
  ## first failure. `dryRun` only prints what would run. Returns a
  ## process exit code (0 on success).
  for s in steps:
    display("  $ " & stepLabel(s))
    let full = sshCmd(user, host, port, auth, timeout, s.run)
    if verbose:
      display("  > ssh ... " & s.run)
    if dryRun:
      continue
    let (output, code) = execCmdEx(full)
    write(stdout, output)
    if code != 0:
      displayError("step failed: " & stepLabel(s))
      return code
  0

proc runStepsLocal*(steps: seq[RunStep], dryRun, verbose: bool): int =
  ## Run `steps` in a local shell, in order, stopping at the first
  ## failure. `dryRun` only prints what would run. Returns a process
  ## exit code (0 on success).
  for s in steps:
    display("  $ " & stepLabel(s))
    if verbose:
      display("  > " & s.run)
    if dryRun:
      continue
    let (output, code) = execCmdEx(s.run)
    write(stdout, output)
    if code != 0:
      displayError("step failed: " & stepLabel(s))
      return code
  0

proc toMsysPath*(path: string): string =
  ## Rewrite a native Windows path to msys-posix form (`C:\a\b` ->
  ## `/c/a/b`) so an msys rsync (e.g. from Git for Windows) does not
  ## parse the drive colon as a remote `host:path` separator. UNC paths
  ## (`\\srv\sh` -> `//srv/sh`) and relative paths pass through with
  ## only backslashes normalized. Callers gate this on `defined(windows)`;
  ## it is a pure conversion so it stays unit-testable on every OS.
  result = path.replace('\\', '/')
  if result.len >= 2 and result[1] == ':' and
      result[0] in {'a'..'z', 'A'..'Z'}:
    result = "/" & result[0].toLowerAscii() & result[2 .. ^1]

proc rsyncCmd*(localSrc, dest, user, host: string, port: int,
    auth: RemoteAuth, timeout: int, dryRun, delete, checksum,
    compress: bool, exclude: seq[string]): string =
  ## The rsync invocation mirroring `localSrc` to `dest`. `dest` is a local
  ## path when `host` is empty, otherwise `user@host:path`. On Windows the
  ## local side is converted with `toMsysPath`; the remote side is already
  ## `user@host:path` and is never converted.
  let remote = isRemoteHost(host)
  result = "rsync -a --partial"
  if dryRun:
    result.add(" -n")
  if delete:
    result.add(" --delete")
  if checksum:
    result.add(" --checksum")
  if remote and compress:
    result.add(" -z")
  for ex in exclude:
    result.add(" --exclude=" & ex)
  let src =
    when defined(windows): quoteShell(toMsysPath(localSrc))
    else: quoteShell(localSrc)
  if remote:
    result.add(" -e '" & sshTransportArgs(port, auth, timeout) & "'")
    result.add(" " & src & "/ " & dest & "/")
  else:
    let dst =
      when defined(windows): quoteShell(toMsysPath(dest))
      else: quoteShell(dest)
    result.add(" " & src & "/ " & dst & "/")
