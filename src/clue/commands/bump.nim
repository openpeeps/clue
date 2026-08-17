# Clue - A cool toolkit for Nim developers
#
# (c) 2026 George Lemon | LGPLv3 License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Bump the version in the current directory's .nimble file.

import std/[os, strutils]
import pkg/semver
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../pkgmanager/nimbleparser

proc parseCurrentVersion(content: string): tuple[version, line: string, idx: int] =
  ## Find the `version` line and return its value plus the line index for
  ## in-place replacement.
  var i = 0
  for line in content.splitLines:
    let trimmed = line.strip()
    if trimmed.startsWith("version"):
      let eqPos = trimmed.find('=')
      if eqPos >= 0:
        let rhs = trimmed[eqPos + 1 .. ^1].strip()
        if rhs.len >= 2 and rhs[0] == '"':
          let endQuote = rhs.rfind('"')
          if endQuote > 0:
            return (rhs[1 .. endQuote - 1], line, i)
    inc i

proc bumpVersion(current, versionArg: string, major: bool): string =
  ## Compute the new version string using semver.
  if versionArg.len > 0:
    return versionArg
  let v = parseVersion(current)
  if major:
    $newVersion(v.major + 1, 0, 0)
  else:
    $newVersion(v.major, v.minor, v.patch + 1)

proc bumpCommand*(v: Values) =
  let versionArg =
    if v.has("version"): v.get("version").getStr
    else: ""
  let major = v.has("--major")

  let nimblePath = findNimbleFile(getCurrentDir())
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & getCurrentDir())
    return

  var content: string
  try:
    content = readFile(nimblePath)
  except CatchableError as e:
    displayError("Failed to read " & nimblePath & ": " & e.msg)
    return

  let found = parseCurrentVersion(content)
  if found.version.len == 0:
    displayError("No version field found in " & nimblePath)
    return

  let newVersion = bumpVersion(found.version, versionArg, major)

  # Replace the version in-place on the matched line.
  var lines = content.splitLines()
  let oldLine = lines[found.idx]
  # Replace just the quoted version string, preserving all whitespace.
  lines[found.idx] = oldLine.replace("\"" & found.version & "\"",
                                    "\"" & newVersion & "\"")

  try:
    writeFile(nimblePath, lines.join("\n"))
  except CatchableError as e:
    displayError("Failed to write " & nimblePath & ": " & e.msg)
    return

  displaySuccess(found.version & " -> " & newVersion & " in " & nimblePath)
