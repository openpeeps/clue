# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## GitHub release sourcing for binary deploys (`deploy dir` profiles with
## a `release:` block) plus the shared archive extractor also used by
## self-upgrade.
##
## Only public repos are supported: assets resolve through the
## `/releases/latest/download/` redirect, so no API token is needed and
## no secrets ever touch the config file. Archive assets (`tar.gz`,
## `tgz`, `zip`) are extracted, raw binary assets are used directly.

import std/[os, osproc, strutils]
import pkg/kapsis/interactive/prompts
import ./configs
import ./remotes

proc latestDownloadUrl*(repo, asset: string): string =
  ## Direct download URL for `asset` in the latest release of `repo`
  ## (`owner/name`), following GitHub's `/releases/latest/download/`
  ## redirect. Exact asset names only.
  "https://github.com/" & repo & "/releases/latest/download/" & asset

proc isArchiveAsset*(name: string): bool =
  ## True when the asset needs extraction before deploy.
  name.endsWith(".tar.gz") or name.endsWith(".tgz") or
    name.endsWith(".zip")

proc extractArchive*(workDir, archive: string): bool =
  ## Extract `archive` into `workDir`, returning true on success. Uses
  ## `tar` where possible (POSIX, and Windows 10+ bundles tar); falls
  ## back to PowerShell Expand-Archive for zips.
  if archive.endsWith(".zip"):
    let (_, code) = execCmdEx("tar xf " & quoteShell(archive) & " -C " &
      quoteShell(workDir))
    if code == 0:
      return true
    let (_, code2) = execCmdEx("powershell -NoProfile -Command " &
      quoteShell("Expand-Archive -Force -LiteralPath '" & archive &
        "' -DestinationPath '" & workDir & "'"))
    return code2 == 0
  let (_, code) = execCmdEx("tar xzf " & quoteShell(archive) & " -C " &
    quoteShell(workDir))
  code == 0

proc downloadFile*(url, dest: string): bool =
  ## Fetch `url` to `dest` with curl. Returns true on success.
  let (_, code) = execCmdEx("curl -fsSL --connect-timeout 15 " &
    quoteShell(url) & " -o " & quoteShell(dest))
  code == 0

proc findReleaseBinary*(dir, binary: string): string =
  ## Locate `binary` inside `dir` (walked recursively after extraction).
  for f in walkDirRec(dir):
    if f.extractFilename == binary:
      return f
  ""

proc stageReleaseAsset*(repo, asset, binary, workDir: string,
    verbose: bool): tuple[stageDir: string, ok: bool] =
  ## Download the latest-release `asset` of `repo` and materialize a
  ## staging dir holding exactly one file: the binary. Archives are
  ## extracted and `binary` (required for archives) is located inside;
  ## raw assets are used directly (`binary`, when given, renames the
  ## staged file). Returns the staging dir path on success.
  let url = latestDownloadUrl(repo, asset)
  if verbose:
    display("  > curl -fsSL " & url)
  else:
    displayInfo("Downloading " & url)
  let dlPath = workDir / asset.extractFilename
  if not downloadFile(url, dlPath):
    displayError("Failed to download release asset: " & url)
    return ("", false)
  let stage = workDir / "stage"
  discard existsOrCreateDir(stage)
  let binName =
    if binary.len > 0: binary
    else: asset.extractFilename
  if isArchiveAsset(asset):
    if binary.len == 0:
      displayError("release.binary is required for archive assets (to locate the binary inside " & asset & ")")
      return ("", false)
    let extractedDir = workDir / "extracted"
    discard existsOrCreateDir(extractedDir)
    if not extractArchive(extractedDir, dlPath):
      displayError("Failed to extract release archive: " & dlPath)
      return ("", false)
    let found = findReleaseBinary(extractedDir, binary)
    if found.len == 0:
      displayError("Binary '" & binary & "' not found inside " & asset)
      return ("", false)
    try:
      copyFile(found, stage / binName)
    except OSError as e:
      displayError("Failed to stage release binary: " & e.msg)
      return ("", false)
  else:
    try:
      copyFile(dlPath, stage / binName)
    except OSError as e:
      displayError("Failed to stage release binary: " & e.msg)
      return ("", false)
  when defined(posix):
    discard execCmdEx("chmod +x " & quoteShell(stage / binName))
  (stage, true)

proc shq*(s: string): string =
  ## Single-quote `s` for `sh` (remote commands run through `sshCmd`,
  ## which adds its own outer quoting layer).
  "'" & s.replace("'", "'\\''") & "'"

proc deployRemoteRelease*(prof: DirProfile, auth: RemoteAuth, dryRun, yes,
    verbose: bool): int =
  ## Fetch the release asset directly on the target host: curl the
  ## latest-release download URL into a remote temp dir, extract when it
  ## is an archive, and place the binary into the profile destination.
  ## Returns a process exit code (0 on success).
  let url = latestDownloadUrl(prof.release.repo, prof.release.asset)
  let binName =
    if prof.release.binary.len > 0: prof.release.binary
    else: prof.release.asset.extractFilename
  if isArchiveAsset(prof.release.asset) and prof.release.binary.len == 0:
    displayError("release.binary is required for archive assets (to locate the binary inside " & prof.release.asset & ")")
    return 1
  let dest = prof.to
  let destBin = dest & "/" & binName
  var script = "set -e; tmp=$(mktemp -d); " &
    "trap 'rm -rf \"$tmp\"' EXIT; " &
    "curl -fsSL " & shq(url) & " -o \"$tmp\"/" & shq(prof.release.asset.extractFilename) & "; " &
    "mkdir -p " & shq(dest) & "; "
  if prof.release.asset.endsWith(".zip"):
    script.add("(tar xf \"$tmp\"/" & shq(prof.release.asset.extractFilename) &
      " -C \"$tmp\" || unzip -o -q \"$tmp\"/" &
      shq(prof.release.asset.extractFilename) & " -d \"$tmp\"); ")
    script.add("bin=$(find \"$tmp\" -name " & shq(binName) &
      " -type f | head -n 1); test -n \"$bin\"; ")
    script.add("cp \"$bin\" " & shq(destBin) & "; ")
  elif isArchiveAsset(prof.release.asset):
    script.add("tar xzf \"$tmp\"/" & shq(prof.release.asset.extractFilename) &
      " -C \"$tmp\"; ")
    script.add("bin=$(find \"$tmp\" -name " & shq(binName) &
      " -type f | head -n 1); test -n \"$bin\"; ")
    script.add("cp \"$bin\" " & shq(destBin) & "; ")
  else:
    script.add("cp \"$tmp\"/" & shq(prof.release.asset.extractFilename) &
      " " & shq(destBin) & "; ")
  script.add("chmod +x " & shq(destBin))
  let full = sshCmd(prof.user, prof.host, prof.port, auth, prof.timeout, script)
  displayInfo("Fetching " & prof.release.asset & " from " & prof.release.repo &
    " on " & prof.host)
  if verbose:
    display("  > ssh ... " & script)
  if dryRun:
    return 0
  if not yes:
    if not promptConfirm("Fetch " & prof.release.asset & " from " &
        prof.release.repo & " on " & prof.host & "?"):
      displayInfo("Deployment cancelled.")
      return 1
  let (output, code) = execCmdEx(full)
  write(stdout, output)
  if code != 0:
    displayError("Remote release fetch failed on " & prof.host)
    return code
  0
