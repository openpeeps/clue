# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Shared ssh/rsync builders and remote authentication for the deploy
## targets (`deploy web`, `deploy dir`).
##
## Passwords are never stored in config files: when a remote target has no
## ssh key configured, clue prompts once via `promptSecret` and keeps the
## secret only in process memory for the duration of the run. It is fed to
## ssh via `sshpass -e` (the `SSHPASS` env var, never a cmdline argument)
## when `sshpass` is available; otherwise `BatchMode` is dropped so ssh
## itself prompts interactively on the terminal.

import std/[os, strutils, terminal]
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

proc sshTransport*(user, host: string, port: int, auth: RemoteAuth,
    timeout: int): string =
  ## The ssh invocation (without remote command) used directly and as the
  ## rsync `-e` transport. Never embeds the password: with `sshpass` it
  ## comes from the `SSHPASS` env var (see `applySshpassEnv`), otherwise
  ## `BatchMode` is dropped so ssh prompts on the terminal itself.
  result = ""
  if auth.useSshpass:
    result.add("sshpass -e ")
  result.add("ssh")
  if port > 0 and port != 22:
    result.add(" -p " & $port)
  if auth.key.len > 0:
    result.add(" -i " & expandPath(auth.key))
  if auth.key.len > 0 or auth.useSshpass:
    result.add(" -o BatchMode=yes")
  result.add(" -o ConnectTimeout=" & $timeout)
  result.add(" " & user & "@" & host)

proc sshCmd*(user, host: string, port: int, auth: RemoteAuth,
    timeout: int, remote: string): string =
  ## An `ssh` invocation running `remote` (single-quoted on the wire).
  sshTransport(user, host, port, auth, timeout) &
    " '" & remote.replace("'", "'\\''") & "'"

proc rsyncCmd*(localSrc, dest, user, host: string, port: int,
    auth: RemoteAuth, timeout: int, dryRun, delete, checksum,
    compress: bool, exclude: seq[string]): string =
  ## The rsync invocation mirroring `localSrc` to `dest`. `dest` is a local
  ## path when `host` is empty, otherwise `user@host:path`.
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
  if remote:
    result.add(" -e '" & sshTransport(user, host, port, auth, timeout) & "'")
    result.add(" " & quoteShell(localSrc) & "/ " & dest & "/")
  else:
    result.add(" " & quoteShell(localSrc) & "/ " & quoteShell(dest) & "/")
