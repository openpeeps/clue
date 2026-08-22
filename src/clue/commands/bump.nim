# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
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

proc bumpVersion(current, versionArg, level: string): string =
  ## Compute the new version string using semver.
  if versionArg.len > 0:
    return versionArg
  let v = parseVersion(current)
  case level
  of "major": $newVersion(v.major + 1, 0, 0)
  of "minor": $newVersion(v.major, v.minor + 1, 0)
  else: $newVersion(v.major, v.minor, v.patch + 1)

proc bumpCommand*(v: Values) =
  let versionArg =
    if v.has("version"): v.get("version").getStr
    else: ""
  let level =
    if v.has("--level"): v.get("--level").getStr
    else: "patch"

  if level notin ["major", "minor", "patch"]:
    displayError("Invalid level '" & level & "'. Use major, minor, or patch.",
      quitProcess = true)

  let nimblePath = findNimbleFile(getCurrentDir())
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
    return

  var content: string
  try:
    content = readFile(nimblePath)
  except CatchableError as e:
    displayError("Failed to read " & nimblePath & ": " & e.msg, quitProcess = true)
    return

  let found = parseCurrentVersion(content)
  if found.version.len == 0:
    displayError("No version field found in " & nimblePath, quitProcess = true)
    return

  let newVersion = bumpVersion(found.version, versionArg, level)

  # Replace the version in-place on the matched line.
  var lines = content.splitLines()
  let oldLine = lines[found.idx]
  # Replace just the quoted version string, preserving all whitespace.
  lines[found.idx] = oldLine.replace("\"" & found.version & "\"",
                                    "\"" & newVersion & "\"")

  try:
    writeFile(nimblePath, lines.join("\n"))
  except CatchableError as e:
    displayError("Failed to write " & nimblePath & ": " & e.msg, quitProcess = true)
    return

  displaySuccess(found.version & " -> " & newVersion & " in " & nimblePath)
