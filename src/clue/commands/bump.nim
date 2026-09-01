# Clue - An alternative package manager for Nim development
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/clue

## Bump versions in the current directory's .nimble file.
## - `clue bump` / `clue bump 1.2.3` — the package's own `version` field.
## - `clue bump <dep>` — bump a root dependency's version constraint by level.
## - `clue bump <dep> <version>` — set a root dependency's constraint version.

import std/[os, strutils]
import pkg/semver
import pkg/kapsis/runtime
import pkg/kapsis/interactive/prompts

import ../pkgmanager/nimbleparser
import ../pkgmanager/configs
import ../pkgmanager/resolver

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

type
  DepBumpResult = tuple[found: bool, hasConstraint: bool,
                        oldVer, newVer, newContent: string]

proc opNeedle(line, verStr: string, kind: VersionConstraintKind): string =
  ## Locate the operator+version token on `line`, preserving the original
  ## operator spelling (`~>` stays `~>`, `==` stays `==`).
  var ops: seq[string]
  case kind
  of vcExact: ops = @["==", "="]
  of vcGte:   ops = @[">="]
  of vcGt:    ops = @[">"]
  of vcLte:   ops = @["<="]
  of vcLt:    ops = @["<"]
  of vcTilde: ops = @["~>", "~"]
  of vcCaret: ops = @["^"]
  of vcAny:   ops = @[]
  for op in ops:
    if (op & " " & verStr) in line:
      return op & " " & verStr
    if (op & verStr) in line:
      return op & verStr
  verStr

proc bumpDepConstraint(content, depName, targetVer, level: string): DepBumpResult =
  ## Locate the root-level `requires` entry for `depName` and rewrite its
  ## version constraint in place (operator preserved). Root-level only:
  ## feature/dev blocks are indented and therefore skipped.
  var lines = content.splitLines()
  for i in 0 ..< lines.len:
    let line = lines[i]
    let isRootLevel = line.len == line.strip(leading = true).len
    let trimmed = line.strip()
    if not isRootLevel or not trimmed.startsWith("requires"):
      continue
    var parts: seq[NimbleDependency]
    try:
      parseRequiresLine(parts, trimmed)
    except CatchableError:
      continue
    for d in parts:
      if d.name != depName:
        continue
      # Ref/url/bare deps carry no version constraint to rewrite.
      if d.constraint.kind == vcAny or d.branch.len > 0 or d.tag.len > 0 or d.url.len > 0:
        return (true, false, "", "", "")
      let verStr = $d.constraint.version
      let newV =
        if targetVer.len > 0: targetVer
        else: bumpVersion(verStr, "", level)
      let needle = opNeedle(line, verStr, d.constraint.kind)
      let replacement =
        if needle.len > verStr.len:
          needle[0 ..< needle.len - verStr.len] & newV
        else: newV
      lines[i] = line.replace(needle, replacement)
      return (true, true, verStr, newV, lines.join("\n"))
  (false, false, "", "", "")

proc writeNimbleContent(nimblePath, content: string): bool =
  try:
    writeFile(nimblePath, content)
    true
  except CatchableError as e:
    displayError("Failed to write " & nimblePath & ": " & e.msg, quitProcess = true)
    false

proc bumpCommand*(v: Values) =
  let arg1 =
    if v.has("pkgOrVersion"): v.get("pkgOrVersion").getStr
    else: ""
  let depTarget =
    if v.has("version"): v.get("version").getStr
    else: ""
  let level =
    if v.has("--level"): v.get("--level").getStr
    else: "patch"

  if level notin ["major", "minor", "patch"]:
    displayError("Invalid level '" & level & "'. Use major, minor, or patch.",
      quitProcess = true)

  # Mode resolution: a semver-looking first argument targets the package's own
  # version; anything else is treated as a dependency name.
  var selfExplicit = false
  if arg1.len > 0:
    try:
      discard parseVersion(arg1)
      selfExplicit = true
    except CatchableError:
      discard
  if selfExplicit and depTarget.len > 0:
    displayError("Unexpected second argument '" & depTarget &
      "'. Use `clue bump <dep> <version>` for dependencies.", quitProcess = true)

  let projectFs = newProjectDisk()
  let nimblePath = findNimbleFile(getCurrentDir(), getClueCfg(), projectFs)
  if nimblePath.len == 0:
    displayError("No .nimble file found in " & getCurrentDir(), quitProcess = true)
    return

  var content: string
  try:
    content = readFile(nimblePath)
  except CatchableError as e:
    displayError("Failed to read " & nimblePath & ": " & e.msg, quitProcess = true)
    return

  if not selfExplicit and arg1.len > 0:
    # --- Dependency mode ---
    if depTarget.len > 0:
      try:
        discard parseVersion(depTarget)
      except CatchableError:
        displayError("Invalid version '" & depTarget & "'", quitProcess = true)
    let bumped = bumpDepConstraint(content, arg1, depTarget, level)
    if not bumped.found:
      displayError("'" & arg1 & "' is not a root dependency in " & nimblePath,
        quitProcess = true)
      return
    if not bumped.hasConstraint:
      displayError("'" & arg1 & "' has no version constraint to bump.",
        quitProcess = true)
      return
    if not writeNimbleContent(nimblePath, bumped.newContent):
      return
    displaySuccess(arg1 & ": " & bumped.oldVer & " -> " & bumped.newVer &
      " in " & nimblePath)
    return

  # --- Self-version mode ---
  let versionArg = if selfExplicit: arg1 else: ""

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

  if not writeNimbleContent(nimblePath, lines.join("\n")):
    return

  displaySuccess(found.version & " -> " & newVersion & " in " & nimblePath)
