# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Self-upgrade: download the latest clue release from GitHub and replace the
## binary in `~/.clue/bin` (which always exists for a clue install).

import std/[os, osproc, strutils]
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../pkgmanager/configs

const
  repoOwner = "openpeeps"
  repoName  = "clue"
  releaseUrl = "https://github.com/" & repoOwner & "/" & repoName &
               "/releases/latest/download/"
  apiLatestUrl = "https://api.github.com/repos/" & repoOwner & "/" & repoName &
                 "/releases/latest"

const currentVersion = block:
  ## The version declared in clue.nimble, read at compile time.
  let content = staticRead(currentSourcePath().parentDir.parentDir.parentDir.parentDir /
    "clue.nimble")
  var found = ""
  for line in content.splitLines():
    let t = line.strip()
    if t.startsWith("version"):
      let eq = t.find('=')
      if eq >= 0:
        found = t[eq + 1 .. ^1].strip().strip(chars = {'"'})
        break
  found

proc assetName(): tuple[name, ext: string] =
  ## Map the current platform/arch to the release asset name.
  when defined(linux):
    ("clue_linux-x86_64", "tar.gz")
  elif defined(macosx):
    when defined(arm64):
      ("clue_macos-arm64", "tar.gz")
    else:
      ("clue_macos-x86_64", "tar.gz")
  elif defined(windows):
    ("clue_windows-x86_64", "zip")
  else:
    {.error: "unsupported platform for clue upgrade".}

proc targetBinary(): string =
  ## The clue binary path inside ~/.clue/bin.
  when defined(windows):
    clueBinPath / "clue.exe"
  else:
    clueBinPath / "clue"

proc latestVersion(): string =
  ## Best-effort fetch of the latest release tag from the GitHub API.
  let (output, code) = execCmdEx("curl -fsSL --connect-timeout 10 " &
    quoteShell(apiLatestUrl))
  if code != 0:
    return ""
  for line in output.splitLines():
    let t = line.strip()
    if t.startsWith("\"tag_name\""):
      let colon = t.find(':')
      if colon >= 0:
        var v = t[colon + 1 .. ^1].strip()
        v = v.strip(chars = {',', '"'})
        return v
  ""

proc extractArchive(workDir, archive, name, ext: string): bool =
  ## Extract the downloaded release archive into `workDir`, returning true on
  ## success. Uses bsdtar where possible (POSIX, and Windows 10+ bundles tar);
  ## falls back to PowerShell Expand-Archive for zips.
  case ext
  of "tar.gz":
    let (_, code) = execCmdEx("tar xzf " & quoteShell(archive) & " -C " &
      quoteShell(workDir))
    code == 0
  of "zip":
    let (_, code) = execCmdEx("tar xf " & quoteShell(archive) & " -C " &
      quoteShell(workDir))
    if code == 0:
      return true
    let winZip = archive
    let winDest = workDir
    let (_, code2) = execCmdEx("powershell -NoProfile -Command " &
      quoteShell("Expand-Archive -Force -LiteralPath '" & winZip &
        "' -DestinationPath '" & winDest & "'"))
    code2 == 0
  else:
    false

proc findBinary(workDir, name: string): string =
  ## Locate the clue binary inside the extracted archive directory.
  for f in walkDirRec(workDir):
    when defined(windows):
      if f.extractFilename.toLowerAscii == "clue.exe":
        return f
    else:
      if f.extractFilename == "clue":
        return f
  ""

proc replaceOnWindows(extracted, target: string): bool =
  ## Replace a running clue.exe on Windows: the running image is locked, so a
  ## detached helper swaps the file in shortly after this process exits.
  let newBin = target & ".new"
  try:
    copyFile(extracted, newBin)
  except OSError:
    return false
  let helper = getTempDir() / "clue_upgrade_helper.cmd"
  let script = "@echo off\r\n" &
    "ping -n 2 127.0.0.1 >nul\r\n" &
    "copy /y \"" & newBin & "\" \"" & target & "\" >nul\r\n" &
    "del \"" & newBin & "\" >nul 2>nul\r\n" &
    "del \"%~f0\" >nul 2>nul\r\n"
  writeFile(helper, script)
  discard execCmdEx("start /b \"\" " & quoteShell(helper))
  true

proc upgradeCommand*(v: Values) =
  discard existsOrCreateDir(clueBinPath)
  let target = targetBinary()
  let (asset, ext) = assetName()

  let latest = latestVersion()
  if latest.len > 0 and latest == currentVersion:
    displaySuccess("Already up to date (" & currentVersion & ")")
    return

  if latest.len > 0:
    if currentVersion.len > 0:
      displayInfo("Upgrading clue " & currentVersion & " -> " & latest)
    else:
      displayInfo("Upgrading clue to " & latest)
  else:
    displayInfo("Upgrading clue to the latest release")

  let workDir = getTempDir() / ("clue_upgrade_" & $getCurrentProcessId())
  discard existsOrCreateDir(workDir)
  defer: removeDir(workDir)

  let archive = workDir / (asset & "." & ext)
  let url = releaseUrl & asset & "." & ext
  displayInfo("Downloading " & url)
  let (_, dlCode) = execCmdEx("curl -fsSL --connect-timeout 15 " &
    quoteShell(url) & " -o " & quoteShell(archive))
  if dlCode != 0:
    displayError("Failed to download the release: " & url, quitProcess = true)
    return

  if not extractArchive(workDir, archive, asset, ext):
    displayError("Failed to extract the release archive", quitProcess = true)
    return

  let extracted = findBinary(workDir, asset)
  if extracted.len == 0:
    displayError("No clue binary found in the release archive", quitProcess = true)
    return

  # Back up the current binary, then install the new one. On Windows the
  # running clue.exe is locked (can't rename/overwrite), so the backup is
  # best-effort and a detached helper swaps the new binary in after exit.
  if fileExists(target):
    try:
      let backup = target & ".prev." & currentVersion
      if fileExists(backup):
        removeFile(backup)
      moveFile(target, backup)
    except OSError:
      discard # running binary on Windows — cannot rename, helper will handle it

  var installed = false
  when defined(windows):
    try:
      copyFile(extracted, target)
      installed = true
    except OSError:
      installed = replaceOnWindows(extracted, target)
  else:
    try:
      copyFile(extracted, target)
      installed = true
    except OSError as e:
      displayError("Failed to install " & target & ": " & e.msg, quitProcess = true)
      return

  if not installed:
    displayError("Failed to install " & target, quitProcess = true)
    return

  when defined(posix):
    discard execCmdEx("chmod +x " & quoteShell(target))

  let versionLabel = if latest.len > 0: latest else: "latest"
  displaySuccess("Upgraded clue to " & versionLabel & " at " & target)
